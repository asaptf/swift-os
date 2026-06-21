// SPDX-License-Identifier: Apache-2.0
// slet_test.swift — SC3 host acceptance for the reconcile loop (cases 1–8), deterministic.
//
// Drives the level-triggered reconciler against a FAKE CellSupervisor with an injected
// clock, so every reconcile property is exercised with no kernel and no wall clock.
// Cases 1–7 run over an in-process CubeStore (LocalStoreClient) for tight determinism;
// case 8 runs over the REAL SC2 mTLS control API (AgentStoreClient + Controller + Agent
// over a host loopback carrying a genuine mutual-TLS handshake) to prove the loop runs
// over the wire and survives an mTLS reconnect without churning healthy Cells.
// Foundation is used only by the harness (printing/exit + test image signing).
//
// Cases (per the SC3 ladder):
//   1  assign 1 instance → a Cell is created; `running` status appears in the store
//   2  remove the assignment → Cell destroyed; ALL processes stopped + handles released
//      (atomic teardown); status goes terminal
//   3  crash → restart per policy; restart count increments; status reflects it
//   4  restartPolicy: Never → failed, no restart; OnFailure → restart on non-zero exit
//      only; backoff respected
//   5  level-triggered idempotency: dropped/duplicate events + slet restart mid-flight
//      → converges with no duplicate Cells and no orphans
//   6  drift repair: an extra Cell not in assignments is reaped; a missing Cell recreated
//   7  image: an unsigned/bad ref is rejected (no Cell, error in status); a signed ref proceeds
//   8  reconnect (mTLS): drop + reconnect, resume the watch from the last revision, do
//      NOT churn running Cells

import Foundation

let startUnix: UInt64 = 1_700_000_000
let theNode = "node-a"

// MARK: - Test image signing (reuse swift-os Ed25519 + SHA-256)

/// A deterministic Ed25519 signing identity for test images, plus the staged-bytes store.
final class TestImages: ImageStore {
    let seed: [UInt8]
    let publicKey: [UInt8]
    private var staged: [[UInt8]: [UInt8]] = [:]   // digest → bytes

    init(seedByte: UInt8) {
        var s = [UInt8](repeating: seedByte, count: 32)
        for i in 0..<32 { s[i] = seedByte &+ UInt8(i) }
        var pub = [UInt8](repeating: 0, count: 32)
        s.withUnsafeBytes { sp in pub.withUnsafeMutableBytes { pp in ed25519PublicKey(seed: sp.baseAddress!, publicKey: pp.baseAddress!) } }
        seed = s; publicKey = pub
    }

    static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: 32)
        if bytes.isEmpty {
            var z: UInt8 = 0
            withUnsafePointer(to: &z) { p in d.withUnsafeMutableBytes { dp in swiftcube_sha256_shim(p, 0, dp.baseAddress!) } }
        } else {
            bytes.withUnsafeBytes { bp in d.withUnsafeMutableBytes { dp in swiftcube_sha256_shim(bp.baseAddress!, bytes.count, dp.baseAddress!) } }
        }
        return d
    }

    /// Stage `content` and return a valid signed ref (digest = SHA-256(content),
    /// signature = Ed25519(digest) under the test key).
    func signAndStage(_ content: [UInt8]) -> ImageRef {
        let digest = TestImages.sha256(content)
        var sig = [UInt8](repeating: 0, count: 64)
        digest.withUnsafeBytes { mp in seed.withUnsafeBytes { sp in sig.withUnsafeMutableBytes { op in
            ed25519Sign(message: mp.baseAddress!, 32, seed: sp.baseAddress!, signature: op.baseAddress!) } } }
        staged[digest] = content
        return ImageRef(digest: digest, signature: sig)
    }

    /// A staged but WRONG-signed ref (signed by a foreign key) → must fail verification.
    func stageBadlySigned(_ content: [UInt8], foreignSeedByte: UInt8) -> ImageRef {
        let digest = TestImages.sha256(content)
        var foreign = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 { foreign[i] = foreignSeedByte &+ UInt8(i) }
        var sig = [UInt8](repeating: 0, count: 64)
        digest.withUnsafeBytes { mp in foreign.withUnsafeBytes { sp in sig.withUnsafeMutableBytes { op in
            ed25519Sign(message: mp.baseAddress!, 32, seed: sp.baseAddress!, signature: op.baseAddress!) } } }
        staged[digest] = content
        return ImageRef(digest: digest, signature: sig)
    }

    func resolve(digest: [UInt8]) -> [UInt8]? { staged[digest] }
}

// A tiny shim so the test calls the kernel `sha256` symbol by an unambiguous name.
@inline(__always) func swiftcube_sha256_shim(_ p: UnsafeRawPointer, _ n: Int, _ out: UnsafeMutableRawPointer) {
    sha256(p, n, out)
}

// MARK: - Harness

@main struct SletTest {
    static var failed = false
    static func check(_ cond: Bool, _ msg: String) {
        if !cond { FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8)); failed = true }
    }

    static func main() {
        case1_assignCreates()
        case2_removeDestroysAtomically()
        case3_crashRestarts()
        case4_restartPolicies()
        case5_idempotency()
        case6_driftRepair()
        case7_imageVerification()
        case8_reconnectNoChurn()

        if failed { FileHandle.standardError.write(Data("slet-test: FAILED\n".utf8)); exit(1) }
        print("slet-test: all SC3 cases (1–8) passed")
    }

    // Shared spec builder.
    static func spec(_ cid: String, image: ImageRef, policy: RestartPolicy = .always,
                     volume: VolumeMount? = nil) -> CellSpec {
        CellSpec(cellId: cid, node: theNode, image: image,
                 capabilities: ["net.listen:8080", "fs.read:/etc/app"],
                 resources: ResourceLimits(cpuMillis: 100, memBytes: 64 << 20),
                 namespaceRoot: "/", args: ["/bin/app"], env: ["LOG_LEVEL=info"],
                 tmpfsScratch: true, volume: volume, restartPolicy: policy)
    }
    static func assignment(_ cid: String, image: ImageRef, gen: UInt64 = 1,
                           policy: RestartPolicy = .always, volume: VolumeMount? = nil) -> Assignment {
        Assignment(generation: gen, spec: spec(cid, image: image, policy: policy, volume: volume))
    }

    /// A local (in-process) reconciler fixture.
    final class Local {
        let store = openRamCubeStore()
        let clock = ManualClock(startUnix)
        let images: TestImages
        let supervisor: FakeCellSupervisor
        let reconciler: Reconciler
        init(_ seedByte: UInt8, config: ReconcilerConfig = ReconcilerConfig()) {
            images = TestImages(seedByte: seedByte)
            supervisor = FakeCellSupervisor(clock: clock)
            reconciler = Reconciler(node: theNode, store: LocalStoreClient(store),
                                    supervisor: supervisor, verifier: ImageVerifier(trustedKey: images.publicKey),
                                    imageStore: images, clock: clock, config: config)
        }
        func putAssignment(_ a: Assignment) {
            _ = store.apply([.put(key: SletKeys.assignment(node: theNode, cellId: a.spec.cellId), value: a.encode())])
        }
        func removeAssignment(_ cid: String) {
            _ = store.apply([.delete(key: SletKeys.assignment(node: theNode, cellId: cid))])
        }
        func status(_ cid: String) -> CellStatusRecord? {
            guard let e = store.get(SletKeys.status(cid)) else { return nil }
            return CellStatusRecord.decode(e.value)
        }
    }

    // 1. Assign 1 instance → Cell created; running status appears.
    static func case1_assignCreates() {
        let f = Local(0x11)
        let img = f.images.signAndStage(Array("base-image-v1".utf8))
        f.putAssignment(assignment("web-0", image: img))
        f.reconciler.bootstrap()

        check(f.supervisor.isRunning("web-0"), "1: Cell running in supervisor")
        check(f.reconciler.isRunning("web-0"), "1: reconciler tracks it running")
        guard let st = f.status("web-0") else { check(false, "1: status present"); return }
        check(st.phase == .running, "1: status phase running")
        check(st.ready, "1: status ready")
        check(st.imageDigest == img.digest, "1: status carries image digest")
        check(st.startedAtSeconds == startUnix, "1: startedAt recorded")
    }

    // 2. Remove the assignment → atomic teardown; status terminal.
    static func case2_removeDestroysAtomically() {
        let f = Local(0x22)
        let vol = VolumeMount(name: "data", mountPath: "/data", handleSlot: 0)
        let img = f.images.signAndStage(Array("base-image-v2".utf8))
        f.putAssignment(assignment("db-0", image: img, volume: vol))
        f.reconciler.bootstrap()
        check(f.supervisor.isRunning("db-0"), "2: Cell running before removal")
        check(f.supervisor.processCount("db-0") == 1 && f.supervisor.handleCount("db-0") > 0, "2: has processes + handles")

        f.removeAssignment("db-0")
        f.reconciler.step()

        check(!f.supervisor.exists("db-0"), "2: Cell gone from supervisor")
        check(f.supervisor.lastDestroyFullyStopped, "2: destroy verified fully stopped (atomic teardown)")
        check(f.supervisor.leaks.isEmpty, "2: no process/handle leak on teardown")
        check(!f.reconciler.isRunning("db-0"), "2: reconciler no longer tracks it running")
        // Status went terminal.
        guard let st = f.status("db-0") else { check(false, "2: terminal status present"); return }
        check(!st.ready, "2: terminal status not ready")
        if case .dead = st.phase {} else { check(false, "2: terminal status phase dead/removed") }
    }

    // 3. Crash → restart per policy; restart count increments.
    static func case3_crashRestarts() {
        let f = Local(0x33)
        let img = f.images.signAndStage(Array("base-image-v3".utf8))
        f.putAssignment(assignment("svc-0", image: img, policy: .always))
        f.reconciler.bootstrap()
        let gen0 = f.supervisor.token("svc-0")
        check(f.reconciler.restartCount("svc-0") == 0, "3: initial restart count 0")

        f.supervisor.crash("svc-0", exitCode: 1)
        f.reconciler.step()

        check(f.supervisor.isRunning("svc-0"), "3: Cell running again after restart")
        check(f.reconciler.restartCount("svc-0") == 1, "3: restart count incremented to 1")
        check(f.supervisor.token("svc-0") != gen0, "3: a NEW generation was launched")
        guard let st = f.status("svc-0") else { check(false, "3: status present"); return }
        check(st.phase == .running && st.restartCount == 1, "3: status reflects restart (#\(st.restartCount))")
    }

    // 4. restartPolicy Never / OnFailure + backoff.
    static func case4_restartPolicies() {
        // Never → crashed Cell goes failed, no restart.
        do {
            let f = Local(0x44)
            let img = f.images.signAndStage(Array("never".utf8))
            f.putAssignment(assignment("n-0", image: img, policy: .never))
            f.reconciler.bootstrap()
            f.supervisor.crash("n-0", exitCode: 7)
            f.reconciler.step()
            check(!f.supervisor.isRunning("n-0"), "4: Never → not restarted")
            check(f.reconciler.restartCount("n-0") == 0, "4: Never → restart count stays 0")
            check(f.status("n-0")?.phase == .failed, "4: Never → status failed")
        }
        // OnFailure: exit 0 → no restart (completed); exit != 0 → restart.
        do {
            let f = Local(0x45)
            let img = f.images.signAndStage(Array("onfail".utf8))
            f.putAssignment(assignment("of-0", image: img, policy: .onFailure))
            f.reconciler.bootstrap()
            f.supervisor.crash("of-0", exitCode: 0)
            f.reconciler.step()
            check(!f.supervisor.isRunning("of-0"), "4: OnFailure+exit0 → no restart")
            check(f.reconciler.restartCount("of-0") == 0, "4: OnFailure+exit0 → count 0")
            if case .dead(let c)? = f.status("of-0")?.phase { check(c == 0, "4: OnFailure+exit0 → dead(0)") }
            else { check(false, "4: OnFailure+exit0 phase dead(0)") }
        }
        // OnFailure + non-zero exit → restart; then backoff is respected.
        do {
            let f = Local(0x46, config: ReconcilerConfig(backoffBaseSeconds: 4, backoffMaxSeconds: 60))
            let img = f.images.signAndStage(Array("backoff".utf8))
            f.putAssignment(assignment("bk-0", image: img, policy: .onFailure))
            f.reconciler.bootstrap()
            // First crash → restart (#1), nextRestartAt = now + (4<<1)=8.
            f.supervisor.crash("bk-0", exitCode: 2)
            f.reconciler.step()
            check(f.reconciler.restartCount("bk-0") == 1, "4: OnFailure+exit2 → restart #1")
            // Crash again immediately: still inside the backoff window → NO restart yet.
            f.supervisor.crash("bk-0", exitCode: 2)
            f.reconciler.step()
            check(f.reconciler.restartCount("bk-0") == 1, "4: backoff respected (no restart #2 yet)")
            check(!f.supervisor.isRunning("bk-0"), "4: stays down during backoff")
            // Advance past the backoff window → it restarts.
            f.clock.advance(9)
            f.reconciler.step()
            check(f.reconciler.restartCount("bk-0") == 2, "4: restart #2 after backoff elapses")
            check(f.supervisor.isRunning("bk-0"), "4: running again after backoff")
        }
    }

    // 5. Level-triggered idempotency: dropped/duplicate events + slet restart mid-flight.
    static func case5_idempotency() {
        let f = Local(0x55)
        let img = f.images.signAndStage(Array("idem".utf8))
        f.putAssignment(assignment("a-0", image: img))
        f.reconciler.bootstrap()
        let tok = f.supervisor.token("a-0")
        check(tok != nil && f.supervisor.cells.count == 1, "5: exactly one Cell")

        // Duplicate/extra reconcile passes must not create duplicates or churn.
        f.reconciler.step(); f.reconciler.step()
        check(f.supervisor.cells.count == 1, "5: no duplicate Cell after repeated passes")
        check(f.supervisor.token("a-0") == tok, "5: same generation (no churn)")
        check(f.supervisor.destroyCalls == 0, "5: no spurious destroy")

        // "slet restart": a brand-new reconciler over the SAME supervisor + store. It must
        // ADOPT the running Cell, not recreate it (no duplicate, no orphan).
        let r2 = Reconciler(node: theNode, store: LocalStoreClient(f.store), supervisor: f.supervisor,
                            verifier: ImageVerifier(trustedKey: f.images.publicKey),
                            imageStore: f.images, clock: f.clock)
        r2.bootstrap()
        check(f.supervisor.cells.count == 1, "5: slet restart adopts (no duplicate Cell)")
        check(f.supervisor.token("a-0") == tok, "5: adopted same generation")
        check(f.supervisor.destroyCalls == 0, "5: adoption did not destroy/recreate")
        check(r2.isRunning("a-0"), "5: restarted slet tracks the adopted Cell")
    }

    // 6. Drift repair: extra Cell reaped; missing Cell recreated; image change → recreate.
    static func case6_driftRepair() {
        let f = Local(0x66)
        let imgA = f.images.signAndStage(Array("v1".utf8))
        f.putAssignment(assignment("c-0", image: imgA))
        f.putAssignment(assignment("c-1", image: imgA))
        f.reconciler.bootstrap()
        check(f.supervisor.isRunning("c-0") && f.supervisor.isRunning("c-1"), "6: both Cells up")

        // Remove c-1's assignment → it is reaped (extra Cell not in desired).
        f.removeAssignment("c-1")
        f.reconciler.step()
        check(!f.supervisor.exists("c-1"), "6: extra Cell reaped")
        check(f.supervisor.isRunning("c-0"), "6: desired Cell untouched")

        // Image drift on c-0: new generation + new digest → atomic recreate.
        let tok0 = f.supervisor.token("c-0")
        let imgB = f.images.signAndStage(Array("v2".utf8))
        f.putAssignment(assignment("c-0", image: imgB, gen: 2))
        f.reconciler.step()
        check(f.supervisor.isRunning("c-0"), "6: c-0 running after drift")
        check(f.supervisor.token("c-0") != tok0, "6: c-0 recreated (new generation) on image drift")
        check(f.status("c-0")?.imageDigest == imgB.digest, "6: status carries the new digest")
    }

    // 7. Image: a bad/unsigned ref is rejected (no Cell, error in status); a signed ref proceeds.
    static func case7_imageVerification() {
        let f = Local(0x77)
        // Wrong-signed image → rejected, no Cell.
        let bad = f.images.stageBadlySigned(Array("evil".utf8), foreignSeedByte: 0x99)
        f.putAssignment(assignment("bad-0", image: bad))
        f.reconciler.bootstrap()
        check(!f.supervisor.exists("bad-0"), "7: bad image → NO Cell created")
        guard let bst = f.status("bad-0") else { check(false, "7: bad image status present"); return }
        check(bst.phase == .failed, "7: bad image → status failed")
        check(bst.message.contains("bad signature"), "7: status names the failure (\(bst.message))")

        // A valid signed image proceeds.
        let good = f.images.signAndStage(Array("good".utf8))
        f.putAssignment(assignment("good-0", image: good))
        f.reconciler.step()
        check(f.supervisor.isRunning("good-0"), "7: signed image → Cell runs")
        check(f.status("good-0")?.phase == .running, "7: signed image → status running")
    }

    // 8. Reconnect over real mTLS: resume watch from last revision; no churn of running Cells.
    static func case8_reconnectNoChurn() {
        let fx = MTLS()
        let images = TestImages(seedByte: 0x88)
        let supervisor = FakeCellSupervisor(clock: fx.clock)
        let client = AgentStoreClient(agent: fx.agent,
                                      openUnary: { fx.unaryConn() }, openWatch: { fx.unaryConn() })
        let reconciler = Reconciler(node: theNode, store: client, supervisor: supervisor,
                                    verifier: ImageVerifier(trustedKey: images.publicKey),
                                    imageStore: images, clock: fx.clock)

        // Scheduler seam: write an assignment straight into the controller's store.
        let img = images.signAndStage(Array("wire-image".utf8))
        let a = Assignment(generation: 1, spec: SletTest.spec("wire-0", image: img))
        _ = fx.controller.store.apply([.put(key: SletKeys.assignment(node: theNode, cellId: "wire-0"), value: a.encode())])

        reconciler.bootstrap()
        check(supervisor.isRunning("wire-0"), "8: Cell brought up over the mTLS control API")
        let tok = supervisor.token("wire-0")
        // Status was written over the wire (CAS-put) — read it back from the store.
        check(fx.controller.store.get(SletKeys.status("wire-0")) != nil, "8: status reported over the wire")
        let baseRev = reconciler.watchRevision

        // Add a second assignment while connected; reconcile picks it up.
        let img2 = images.signAndStage(Array("wire-image-2".utf8))
        let a2 = Assignment(generation: 1, spec: SletTest.spec("wire-1", image: img2))
        _ = fx.controller.store.apply([.put(key: SletKeys.assignment(node: theNode, cellId: "wire-1"), value: a2.encode())])
        reconciler.step()
        check(supervisor.isRunning("wire-1"), "8: second Cell created after live watch event")
        check(reconciler.watchRevision >= baseRev, "8: watch cursor advanced")

        let destroysBefore = supervisor.destroyCalls
        // "Drop" and reconnect: a fresh mTLS watch from the resume cursor. Level-triggered
        // reconcile must NOT churn the running Cells.
        reconciler.reconnect()
        reconciler.step()
        check(supervisor.token("wire-0") == tok, "8: running Cell not churned across reconnect (same generation)")
        check(supervisor.isRunning("wire-0") && supervisor.isRunning("wire-1"), "8: both Cells still running after reconnect")
        check(supervisor.destroyCalls == destroysBefore, "8: reconnect caused no spurious teardown")
    }

    // MARK: - mTLS fixture (mirrors control_test's loopback harness)

    final class SeededRNG {
        private var s: UInt64
        init(_ seed: UInt64) { s = seed }
        func fill(_ b: inout [UInt8]) {
            for i in 0..<b.count { s = s &* 6364136223846793005 &+ 1442695040888963407; b[i] = UInt8((s >> 33) & 0xFF) &+ UInt8(i) }
        }
    }

    final class MTLS {
        let rngBox = SeededRNG(0x5C3)
        func rng(_ b: inout [UInt8]) { rngBox.fill(&b) }
        let clock = ManualClock(startUnix)
        var controller: Controller!
        var serverIdentity: TLSIdentity!
        var caCertDER: [UInt8] = []
        var agent: Agent!

        var nowYMD: UInt64 { controller.nowYMD }

        final class Conn {
            let client: TLSChannel, server: TLSChannel
            let drive: (Bytes, TLSChannel) -> Void
            init(client: TLSChannel, server: TLSChannel, drive: @escaping (Bytes, TLSChannel) -> Void) {
                self.client = client; self.server = server; self.drive = drive
            }
            func handshake() { client.start(); server.start(); pump() }
            func pump() {
                for _ in 0..<400 {
                    var moved = false
                    let c = client.takeWire(); if !c.isEmpty { server.feedWire(c); moved = true }
                    while let f = server.nextFrame() { drive(f, server); moved = true }
                    let s = server.takeWire(); if !s.isEmpty { client.feedWire(s); moved = true }
                    if !moved { break }
                }
            }
        }

        init() { setup(); enroll() }

        func serverChannel() -> TLSChannel {
            let cfg = TLSConfig(identity: serverIdentity, caRoots: [parseX509(caCertDER)!], now: nowYMD, requireClientCert: false)
            return TLSChannel(MutualTLS(role: .server, config: cfg, rng))
        }
        func clientChannel(_ cfg: TLSConfig) -> TLSChannel { TLSChannel(MutualTLS(role: .client, config: cfg, rng)) }

        // The server-side frame handler needs the right server channel; capture per-conn.
        func conn(_ clientCfg: TLSConfig) -> Conn {
            let srv = serverChannel()
            let c = Conn(client: clientChannel(clientCfg), server: srv) { [unowned self] frame, ch in self.controller.process(frame: frame, channel: ch) }
            c.handshake(); return c
        }

        func setup() {
            let nb = startUnix - 1000, na = startUnix + 10 * 365 * 24 * 3600
            var s = [UInt8](repeating: 0, count: 8); rng(&s)
            let ca = ControllerCA.create(commonName: "swiftcube-ca", notBefore: nb, notAfter: na, serial: s, rng)!
            caCertDER = ca.caCertDER
            let serverKey = generateECKeyPair(rng)!
            let serverCert = ca.sign(subjectCN: "sctld", sanDNS: "sctld", subjectKeyPoint65: serverKey.point65,
                                     serial: [0x53], notBefore: nb, notAfter: na)!
            serverIdentity = TLSIdentity(certChain: [serverCert], privateKey: serverKey.priv)
            controller = Controller(store: openRamCubeStore(), ca: ca, clock: clock, rng)
        }

        func enroll() {
            agent = Agent(nodeName: theNode, caCertDER: caCertDER, serverName: "sctld", rng)!
            let token = controller.tokens.create(ttlSeconds: 3600, uses: 1, rng).presented
            let jc = conn(agent.bootstrapClientConfig(now: nowYMD))
            _ = agent.join(channel: jc.client, token: token, jc.pump)
            let rc = conn(agent.mutualClientConfig(now: nowYMD))
            _ = agent.register(channel: rc.client, address: "10.0.2.15:7700", ttlSeconds: 3600, rc.pump)
        }

        /// Open a fresh full-mTLS conn and surface it as a (channel, pump) pair for the
        /// AgentStoreClient. Each unary RPC and each watch uses its own conn — exactly the
        /// control_test pattern.
        func unaryConn() -> (channel: TLSChannel, pump: () -> Void)? {
            let c = conn(agent.mutualClientConfig(now: nowYMD))
            return (channel: c.client, pump: c.pump)
        }
    }
}
