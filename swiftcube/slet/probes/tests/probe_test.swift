// SPDX-License-Identifier: Apache-2.0
// probe_test.swift — SC5 host acceptance for the probe runner (cases 1–6, 9), deterministic.
//
// Drives the level-triggered reconciler — now with a ProbeRunner over a FAKE http/tcp
// prober and an injected clock — against a FakeCellSupervisor, so every probe property is
// exercised with no kernel and no wall clock. These cases prove the slet half of SC5:
// readiness gates the `ready` bit (and never restarts), liveness failure routes through
// SC3's restart machinery, thresholds debounce flapping, the startup window suppresses
// failures, a hung probe counts as a failure, and both http and tcp kinds work. The
// controller half (ready status → /endpoints/<service>, grouping, leader-only, removal)
// is the sibling endpoints_test. Foundation is used only by the harness.
//
// Cases (per the SC5 ladder):
//   1  readiness gates: a fresh Cell is NOT ready until its readiness probe passes
//      (past successThreshold), then becomes ready — the input the endpoints loop registers
//   2  readiness failing → ready=false; the Cell is NOT restarted
//   3  liveness failing past failureThreshold → SC3 restart triggered; the Cell is out of
//      endpoints (ready=false) while it restarts
//   4  thresholds debounce: one failed/passed probe below threshold does not flip; N does
//   5  initialDelay/startup: no probe runs, and the Cell cannot fail, before the window
//   6  timeout: a hung probe counts as a failure
//   9  both http and tcp probe kinds work

import Foundation

let startUnix: UInt64 = 1_700_000_000
let theNode = "node-a"
let nodeAddr = "10.0.2.15"

// MARK: - Test image signing (reuse swift-os Ed25519 + SHA-256)

final class TestImages: ImageStore {
    let seed: [UInt8]
    let publicKey: [UInt8]
    private var staged: [[UInt8]: [UInt8]] = [:]

    init(seedByte: UInt8) {
        var s = [UInt8](repeating: seedByte, count: 32)
        for i in 0..<32 { s[i] = seedByte &+ UInt8(i) }
        var pub = [UInt8](repeating: 0, count: 32)
        s.withUnsafeBytes { sp in pub.withUnsafeMutableBytes { pp in ed25519PublicKey(seed: sp.baseAddress!, publicKey: pp.baseAddress!) } }
        seed = s; publicKey = pub
    }

    static func digest(_ bytes: [UInt8]) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: 32)
        bytes.withUnsafeBytes { bp in d.withUnsafeMutableBytes { dp in sha256(bp.baseAddress!, bytes.count, dp.baseAddress!) } }
        return d
    }

    func signAndStage(_ content: [UInt8]) -> ImageRef {
        let digest = TestImages.digest(content)
        var sig = [UInt8](repeating: 0, count: 64)
        digest.withUnsafeBytes { mp in seed.withUnsafeBytes { sp in sig.withUnsafeMutableBytes { op in
            ed25519Sign(message: mp.baseAddress!, 32, seed: sp.baseAddress!, signature: op.baseAddress!) } } }
        staged[digest] = content
        return ImageRef(digest: digest, signature: sig)
    }

    func resolve(digest: [UInt8]) -> [UInt8]? { staged[digest] }
}

@main struct ProbeTest {
    static var failed = false
    static func check(_ cond: Bool, _ msg: String) {
        if !cond { FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8)); failed = true }
    }

    static func main() {
        case1_readinessGates()
        case2_readinessFailNoRestart()
        case3_livenessRestart()
        case4_debounce()
        case5_initialDelay()
        case6_timeout()
        case9_httpAndTcp()

        if failed { FileHandle.standardError.write(Data("probe-test: FAILED\n".utf8)); exit(1) }
        print("probe-test: all SC5 probe cases (1–6, 9) passed")
    }

    // MARK: - Builders

    static func probe(_ kind: ProbeKind, port: UInt16, path: String = "", period: UInt32 = 1,
                      timeout: UInt32 = 1, initialDelay: UInt32 = 0,
                      success: UInt32 = 1, failure: UInt32 = 3) -> ProbeSpec {
        ProbeSpec(kind: kind, port: port, httpPath: path, periodSeconds: period,
                  timeoutSeconds: timeout, initialDelaySeconds: initialDelay,
                  successThreshold: success, failureThreshold: failure)
    }

    static func spec(_ cid: String, image: ImageRef, service: String = "web", port: UInt16 = 8080,
                     readiness: ProbeSpec = ProbeSpec(), liveness: ProbeSpec = ProbeSpec(),
                     policy: RestartPolicy = .always) -> CellSpec {
        CellSpec(cellId: cid, node: theNode, image: image, capabilities: ["net.listen:8080"],
                 resources: ResourceLimits(cpuMillis: 100, memBytes: 64 << 20), namespaceRoot: "/",
                 args: ["/bin/app"], env: [], tmpfsScratch: true, volume: nil, restartPolicy: policy,
                 service: service, port: port, readiness: readiness, liveness: liveness)
    }

    // MARK: - Fixture

    final class Fixture {
        let store = openRamCubeStore()
        let clock = ManualClock(startUnix)
        let images: TestImages
        let supervisor: FakeCellSupervisor
        let prober = FakeProber()
        let runner: ProbeRunner
        let reconciler: Reconciler
        init(_ seed: UInt8, config: ReconcilerConfig = ReconcilerConfig()) {
            images = TestImages(seedByte: seed)
            supervisor = FakeCellSupervisor(clock: clock)
            runner = ProbeRunner(prober: prober, clock: clock)
            reconciler = Reconciler(node: theNode, store: LocalStoreClient(store), supervisor: supervisor,
                                    verifier: ImageVerifier(trustedKey: images.publicKey), imageStore: images,
                                    clock: clock, config: config, probeRunner: runner, nodeAddress: nodeAddr)
        }
        func put(_ s: CellSpec, gen: UInt64 = 1) {
            let a = Assignment(generation: gen, spec: s)
            _ = store.apply([.put(key: SletKeys.assignment(node: theNode, cellId: s.cellId), value: a.encode())])
        }
        func status(_ cid: String) -> CellStatusRecord? {
            guard let e = store.get(SletKeys.status(cid)) else { return nil }
            return CellStatusRecord.decode(e.value)
        }
        /// One reconcile pass after advancing the clock (drives a fresh probe period).
        func tick(_ secs: UInt64 = 1) { clock.advance(secs); reconciler.step() }
    }

    // MARK: - Case 1: readiness gates registration

    static func case1_readinessGates() {
        let f = Fixture(0x11)
        let img = f.images.signAndStage(Array("v1".utf8))
        let rp = probe(.http, port: 8080, path: "/healthz", success: 1)
        f.prober.setHTTP(port: 8080, path: "/healthz", .failure)   // not healthy yet
        f.put(spec("web-0", image: img, readiness: rp))
        f.reconciler.bootstrap()

        check(f.supervisor.isRunning("web-0"), "1: Cell running")
        check(f.status("web-0")?.ready == false, "1: readiness-gated Cell is NOT ready until the probe passes")
        check(f.status("web-0")?.service == "web", "1: status carries the service")
        check(f.status("web-0")?.address == nodeAddr && f.status("web-0")?.port == 8080, "1: status carries reachable address:port")

        f.prober.setHTTP(port: 8080, path: "/healthz", .success)
        f.tick()                                                   // next period → success threshold met
        check(f.status("web-0")?.ready == true, "1: becomes ready once readiness passes")
        check(f.reconciler.restartCount("web-0") == 0, "1: readiness never restarts the Cell")
    }

    // MARK: - Case 2: readiness fail → not ready, no restart

    static func case2_readinessFailNoRestart() {
        let f = Fixture(0x22)
        let img = f.images.signAndStage(Array("v2".utf8))
        let rp = probe(.http, port: 8080, path: "/healthz", success: 1, failure: 3)
        f.prober.setHTTP(port: 8080, path: "/healthz", .success)
        f.put(spec("web-0", image: img, readiness: rp))
        f.reconciler.bootstrap()
        check(f.status("web-0")?.ready == true, "2: ready after first success")
        let tok = f.supervisor.token("web-0")

        // Start failing: 3 consecutive failures flip ready=false; the Cell is NOT restarted.
        f.prober.setHTTP(port: 8080, path: "/healthz", .failure)
        f.tick(); f.tick(); f.tick()
        check(f.status("web-0")?.ready == false, "2: readiness failing → not ready")
        check(f.supervisor.token("web-0") == tok, "2: NOT restarted (same generation)")
        check(f.reconciler.restartCount("web-0") == 0, "2: restart count stays 0")
        check(f.supervisor.isRunning("web-0"), "2: Cell still running (readiness ≠ liveness)")
    }

    // MARK: - Case 3: liveness fail → restart; out of endpoints while restarting

    static func case3_livenessRestart() {
        let f = Fixture(0x33)
        let img = f.images.signAndStage(Array("v3".utf8))
        let rp = probe(.http, port: 8080, path: "/healthz", success: 1)
        let lp = probe(.http, port: 8080, path: "/livez", failure: 2)
        f.prober.setHTTP(port: 8080, path: "/healthz", .success)
        f.prober.setHTTP(port: 8080, path: "/livez", .success)
        f.put(spec("web-0", image: img, readiness: rp, liveness: lp, policy: .always))
        f.reconciler.bootstrap()
        check(f.status("web-0")?.ready == true, "3: ready and live initially")
        let tok = f.supervisor.token("web-0")

        // Liveness starts failing: 2 consecutive failures past threshold → restart.
        f.prober.setHTTP(port: 8080, path: "/livez", .failure)
        f.tick()  // failure #1 (below threshold) — no restart yet
        check(f.reconciler.restartCount("web-0") == 0, "3: one liveness failure does not restart")
        f.tick()  // failure #2 → threshold → restart
        check(f.reconciler.restartCount("web-0") == 1, "3: liveness failure past threshold → restart triggered")
        check(f.supervisor.token("web-0") != tok, "3: a NEW generation launched")
        check(f.status("web-0")?.ready == false, "3: out of endpoints (not ready) while it restarts")
    }

    // MARK: - Case 4: thresholds debounce

    static func case4_debounce() {
        // Failure debounce: failureThreshold=3 — one/two failures do NOT flip ready.
        do {
            let f = Fixture(0x44)
            let img = f.images.signAndStage(Array("v4a".utf8))
            let rp = probe(.http, port: 8080, path: "/healthz", success: 1, failure: 3)
            f.prober.setHTTP(port: 8080, path: "/healthz", .success)
            f.put(spec("web-0", image: img, readiness: rp))
            f.reconciler.bootstrap()
            check(f.status("web-0")?.ready == true, "4: ready")
            f.prober.setHTTP(port: 8080, path: "/healthz", .failure)
            f.tick(); check(f.status("web-0")?.ready == true, "4: 1 failure < threshold → still ready")
            f.tick(); check(f.status("web-0")?.ready == true, "4: 2 failures < threshold → still ready")
            f.tick(); check(f.status("web-0")?.ready == false, "4: 3 consecutive failures → not ready")
        }
        // Success debounce: successThreshold=2 — one success does NOT flip ready true.
        do {
            let f = Fixture(0x45)
            let img = f.images.signAndStage(Array("v4b".utf8))
            let rp = probe(.http, port: 8080, path: "/healthz", success: 2, failure: 3)
            f.prober.setHTTP(port: 8080, path: "/healthz", .success)
            f.put(spec("web-0", image: img, readiness: rp))
            f.reconciler.bootstrap()                                  // success #1
            check(f.status("web-0")?.ready == false, "4: 1 success < successThreshold → not ready yet")
            f.tick()                                                  // success #2 → ready
            check(f.status("web-0")?.ready == true, "4: 2 consecutive successes → ready")
        }
    }

    // MARK: - Case 5: initialDelay / startup window suppresses failures

    static func case5_initialDelay() {
        let f = Fixture(0x55)
        let img = f.images.signAndStage(Array("v5".utf8))
        // Liveness that WOULD fail immediately, but initialDelay=5 holds it off.
        let lp = probe(.http, port: 8080, path: "/livez", period: 1, initialDelay: 5, failure: 1)
        f.prober.setHTTP(port: 8080, path: "/livez", .failure)
        f.put(spec("web-0", image: img, liveness: lp, policy: .always))
        f.reconciler.bootstrap()
        check(f.prober.callCount == 0, "5: no probe runs inside the startup window")
        // Tick within the window: still no failure, no restart.
        f.tick(); f.tick(); f.tick()   // now = T+3 < T+5
        check(f.prober.callCount == 0, "5: still no probe inside the window")
        check(f.reconciler.restartCount("web-0") == 0, "5: Cell not failed before the window elapses")
        // Cross the window: the probe runs and (failureThreshold=1) triggers a restart.
        f.tick(); f.tick()             // now = T+5 → probe fires and fails
        check(f.prober.callCount >= 1, "5: probe runs once the window elapses")
        check(f.reconciler.restartCount("web-0") == 1, "5: liveness restart after the window")
    }

    // MARK: - Case 6: timeout counts as a failure

    static func case6_timeout() {
        let f = Fixture(0x66)
        let img = f.images.signAndStage(Array("v6".utf8))
        let rp = probe(.http, port: 8080, path: "/healthz", success: 1, failure: 2)
        f.prober.setHTTP(port: 8080, path: "/healthz", .success)
        f.put(spec("web-0", image: img, readiness: rp))
        f.reconciler.bootstrap()
        check(f.status("web-0")?.ready == true, "6: ready")
        // A hung probe (timeout) counts as a failure; 2 of them flip ready=false.
        f.prober.setHTTP(port: 8080, path: "/healthz", .timeout)
        f.tick(); check(f.status("web-0")?.ready == true, "6: 1 timeout < threshold → still ready")
        f.tick(); check(f.status("web-0")?.ready == false, "6: timeouts count as failures → not ready")
    }

    // MARK: - Case 9: http and tcp probe kinds both work

    static func case9_httpAndTcp() {
        let f = Fixture(0x99)
        let img = f.images.signAndStage(Array("v9".utf8))
        let httpR = probe(.http, port: 8080, path: "/healthz", success: 1)
        let tcpR  = probe(.tcp,  port: 9090, success: 1)
        f.prober.setHTTP(port: 8080, path: "/healthz", .success)
        f.prober.setTCP(port: 9090, .success)
        f.put(spec("http-0", image: img, service: "h", port: 8080, readiness: httpR))
        f.put(spec("tcp-0",  image: img, service: "t", port: 9090, readiness: tcpR))
        f.reconciler.bootstrap()
        check(f.status("http-0")?.ready == true, "9: http probe → ready")
        check(f.status("tcp-0")?.ready == true, "9: tcp probe → ready")

        // A failing tcp connect flips only that Cell.
        f.prober.setTCP(port: 9090, .failure)
        f.tick(); f.tick(); f.tick()
        check(f.status("tcp-0")?.ready == false, "9: tcp connect failing → not ready")
        check(f.status("http-0")?.ready == true, "9: http Cell unaffected")
    }
}
