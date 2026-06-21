// SPDX-License-Identifier: Apache-2.0
// volume_test.swift — SC8 host acceptance for node-local sticky PVs + fencing (cases 1–8).
//
// Drives the REAL SC8 logic deterministically with no kernel and no wall clock:
//   • a HostDirVolumeStore (a host directory standing in for datafs, honest POSIX fsync) is
//     the persistent medium — so "data survives a restart" is a real on-disk property;
//   • the VolumeManager provisions/binds/mounts/fences PVs and bumps the fencing token;
//   • the leader-gated scheduler (the pure schedule() + SchedulerLoop) PINS each stateful
//     ordinal to its bound node and leaves it Pending when that node is down;
//   • the SC3 reconcile loop + FakeCellSupervisor exercise the single-mount gate end to end.
// Foundation is used only by the harness (printing/exit, temp dirs, image signing).
//
// Cases (per the SC8 ladder):
//   1  provision + bind: a stateful replica is placed → a PV is provisioned on the chosen
//      node and bound; /volumes/<id> records volume → node
//   2  data survives restart: write to the PV via a Cell, restart the Cell (and slet) → the
//      data is still there
//   3  pinning: after the first placement the replica is scheduled ONLY to its bound node,
//      never spread elsewhere; the Assignment carries that node
//   4  node down: the bound node's lease expires → the replica goes Pending (not re-placed);
//      when the node returns it is re-placed on the same node with the same PV
//   5  fencing — single mount: a new writer is refused until the prior teardown is confirmed;
//      two writers never hold the volume (direct + through the reconcile loop)
//   6  fencing — stale token: a mount with a stale fencing token is refused
//   7  retain: a routine teardown keeps the PV (Retain); Delete removes it explicitly
//   8  stable identity: a stateful replica keeps its (app, ordinal) and its PV across Cell
//      generations and revisions

import Foundation

let startUnix: UInt64 = 1_700_000_000

// MARK: - Image signing (reuse swift-os Ed25519 + SHA-256), for the reconcile-loop case

/// A deterministic Ed25519 signing identity + staged-bytes store, so the reconcile loop's
/// image gate passes and a real (fake-supervised) stateful Cell can run.
final class SignedImages: ImageStore {
    let seed: [UInt8]; let publicKey: [UInt8]
    private var staged: [[UInt8]: [UInt8]] = [:]

    init(seedByte: UInt8) {
        var s = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 { s[i] = seedByte &+ UInt8(i) }
        var pub = [UInt8](repeating: 0, count: 32)
        s.withUnsafeBytes { sp in pub.withUnsafeMutableBytes { pp in ed25519PublicKey(seed: sp.baseAddress!, publicKey: pp.baseAddress!) } }
        seed = s; publicKey = pub
    }

    static func sha256Of(_ bytes: [UInt8]) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: 32)
        bytes.withUnsafeBytes { bp in d.withUnsafeMutableBytes { dp in sha256(bp.baseAddress!, bytes.count, dp.baseAddress!) } }
        return d
    }

    func signAndStage(_ content: [UInt8]) -> ImageRef {
        let digest = SignedImages.sha256Of(content)
        var sig = [UInt8](repeating: 0, count: 64)
        digest.withUnsafeBytes { mp in seed.withUnsafeBytes { sp in sig.withUnsafeMutableBytes { op in
            ed25519Sign(message: mp.baseAddress!, 32, seed: sp.baseAddress!, signature: op.baseAddress!) } } }
        staged[digest] = content
        return ImageRef(digest: digest, signature: sig)
    }

    func resolve(digest: [UInt8]) -> [UInt8]? { staged[digest] }
}

@main struct VolumeTest {
    static var failed = false
    static var tmpCounter = 0
    static func check(_ cond: Bool, _ msg: String) {
        if !cond { FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8)); failed = true }
    }

    static func main() {
        case1_provisionAndBind()
        case2_dataSurvivesRestart()
        case3_pinning()
        case4_nodeDown()
        case5_singleMountNoOverlap()
        case6_staleToken()
        case7_retain()
        case8_stableIdentity()

        if failed { FileHandle.standardError.write(Data("volume-test: FAILED\n".utf8)); exit(1) }
        print("volume-test: all SC8 cases (1–8) passed")
    }

    // MARK: - Builders

    static let dataVol = VolumeMount(name: "data", mountPath: "/data", handleSlot: 0, sizeBytes: 1 << 30)

    static func req(_ cpu: UInt32, _ mem: UInt64) -> ResourceLimits { ResourceLimits(cpuMillis: cpu, memBytes: mem) }

    /// A STATEFUL deployment template — it declares the persistent volume, which is the
    /// signal the scheduler keys the sticky path on.
    static func statefulTemplate(_ request: ResourceLimits) -> CellTemplate {
        CellTemplate(image: ImageRef(digest: [UInt8](repeating: 7, count: 32),
                                     signature: [UInt8](repeating: 9, count: 64)),
                     capabilities: ["net.listen:8080"], resources: request, namespaceRoot: "/",
                     args: ["/bin/db"], env: [], tmpfsScratch: true, volume: dataVol,
                     restartPolicy: .always)
    }

    static func statefulDep(_ app: String, replicas: UInt32, request: ResourceLimits,
                            selector: [String] = [], rev: UInt64 = 1) -> DeploymentSpec {
        DeploymentSpec(app: app, replicas: replicas, revision: rev, request: request,
                       nodeSelector: selector, pinHint: "", template: statefulTemplate(request))
    }

    static func tmpRoot(_ tag: String) -> String {
        tmpCounter += 1
        let pid = ProcessInfo.processInfo.processIdentifier
        return NSTemporaryDirectory() + "swiftcube-vol-\(tag)-\(pid)-\(tmpCounter)"
    }

    // MARK: - Fixture (scheduler + datafs + volume manager over one cubestore)

    final class Fixture {
        let store = openRamCubeStore()
        let clock = ManualClock(startUnix)
        let leases: LeaseManager<RamLog, RamSnapshot>
        let datafs: HostDirVolumeStore
        init(root: String) {
            leases = LeaseManager(store: store, clock: clock)
            datafs = HostDirVolumeStore(root: root)
        }

        func addNode(_ id: String, cpu: UInt32 = 1000, mem: UInt64 = 1 << 30, labels: [String] = [], ttl: UInt64 = 3600) {
            leases.grant(id: id, ttlSeconds: ttl, attachedKeys: [CubeKeys.node(id)])
            let n = NodeRecord(id: id, status: .ready, leaseId: id, address: "10.0.0.1:9",
                               registeredRev: store.revision,
                               capacityCpuMillis: cpu, capacityMemBytes: mem, labels: labels)
            _ = store.apply([.put(key: CubeKeys.node(id), value: n.encode())])
        }
        func killNode(_ id: String) {
            _ = store.apply([.delete(key: CubeKeys.lease(id)), .delete(key: CubeKeys.node(id))])
        }
        func putDeployment(_ d: DeploymentSpec) {
            _ = store.apply([.put(key: SchedulerKeys.appSpec(d.app), value: d.encode())])
        }
        func removeAssignment(node: String, cellId: String) {
            _ = store.apply([.delete(key: SletKeys.assignment(node: node, cellId: cellId))])
        }
        func loop(isLeader: Bool = true) -> SchedulerLoop<RamLog, RamSnapshot> {
            SchedulerLoop(store: store, clock: clock, isLeader: isLeader)
        }
        func manager(node: String) -> VolumeManager {
            VolumeManager(node: node, store: LocalStoreClient(store), datafs: datafs)
        }

        // Inspection
        func assignments() -> [(node: String, cellId: String, asg: Assignment)] {
            var out: [(String, String, Assignment)] = []
            for e in store.prefix(SletKeys.assignmentsPrefix) {
                guard let p = SchedulerKeys.parseAssignmentKey(e.key), let a = Assignment.decode(e.value) else { continue }
                out.append((p.node, p.cellId, a))
            }
            return out
        }
        func assignmentNode(_ cellId: String) -> String? {
            for a in assignments() where a.cellId == cellId { return a.node }
            return nil
        }
        func pendings() -> [PendingRecord] {
            store.prefix(SchedulerKeys.pendingPrefix).compactMap { PendingRecord.decode($0.value) }
        }
        func volumeRecord(_ id: String) -> VolumeRecord? {
            guard let e = store.get(VolumeKeys.volume(id)) else { return nil }
            return VolumeRecord.decode(e.value)
        }
    }

    // MARK: - Case 1: provision + bind

    static func case1_provisionAndBind() {
        let f = Fixture(root: tmpRoot("c1"))
        f.addNode("n1"); f.addNode("n2"); f.addNode("n3")
        f.putDeployment(statefulDep("db", replicas: 1, request: req(100, 64 << 20)))
        f.loop().step()

        let a = f.assignments()
        check(a.count == 1, "1: one stateful replica placed (got \(a.count))")
        guard let placed = a.first else { return }
        check(placed.cellId == "db--r1-s0-g1", "1: stable-ordinal cellId (got \(placed.cellId))")

        // slet on the chosen node provisions + binds + mounts the PV.
        let mgr = f.manager(node: placed.node)
        check(mgr.acquire(cellId: placed.cellId, volume: dataVol), "1: slet acquires the PV")

        let vid = VolumeId.make(app: "db", ordinal: 0)
        check(f.datafs.exists(volumeId: vid), "1: PV subtree provisioned on datafs")
        guard let rec = f.volumeRecord(vid) else { check(false, "1: /volumes/<id> present"); return }
        check(rec.node == placed.node, "1: /volumes records volume → node (\(rec.node))")
        check(rec.app == "db" && rec.ordinal == 0, "1: record keyed by (app, ordinal)")
        check(rec.state == .mounted, "1: volume mounted by the live Cell")
        check(rec.sizeBytes == 1 << 30, "1: requested size recorded (best-effort)")
    }

    // MARK: - Case 2: data survives a Cell restart and a slet restart

    static func case2_dataSurvivesRestart() {
        let f = Fixture(root: tmpRoot("c2"))
        let vid = VolumeId.make(app: "db", ordinal: 0)
        let mgr1 = f.manager(node: "n1")
        check(mgr1.acquire(cellId: "db--r1-s0-g1", volume: dataVol), "2: Cell mounts its PV")
        // The Cell writes durable state into /data.
        check(f.datafs.writeFile(volumeId: vid, name: "db.sqlite", bytes: Array("rows".utf8)) == .ok,
              "2: durable write to the PV")

        // Restart the Cell: fence (teardown) then re-acquire the same PV for a new generation.
        mgr1.fence(cellId: "db--r1-s0-g1", volume: dataVol)
        check(mgr1.acquire(cellId: "db--r1-s0-g2", volume: dataVol), "2: Cell restarts, re-mounts the PV")
        check(f.datafs.readFile(volumeId: vid, name: "db.sqlite") == Array("rows".utf8),
              "2: data survives the Cell restart")

        // Restart slet: a brand-new manager (empty mount table) over the SAME datafs + store.
        let mgr2 = f.manager(node: "n1")
        check(f.datafs.exists(volumeId: vid), "2: PV subtree survives the slet restart")
        check(mgr2.acquire(cellId: "db--r1-s0-g2", volume: dataVol), "2: new slet re-adopts the PV")
        check(f.datafs.readFile(volumeId: vid, name: "db.sqlite") == Array("rows".utf8),
              "2: data intact after the slet restart")
    }

    // MARK: - Case 3: pinning (never spread off the bound node)

    static func case3_pinning() {
        let f = Fixture(root: tmpRoot("c3"))
        // First placement onto the ONLY node, n3, so the binding is on n3 — a node that
        // plain spread (lowest-id-first) would NOT prefer once n1/n2 exist.
        f.addNode("n3")
        f.putDeployment(statefulDep("db", replicas: 1, request: req(100, 64 << 20)))
        let lp = f.loop()
        lp.step()
        check(f.assignmentNode("db--r1-s0-g1") == "n3", "3: first placement on the only node n3")

        let mgr = f.manager(node: "n3")
        check(mgr.acquire(cellId: "db--r1-s0-g1", volume: dataVol), "3: bound to n3")

        // Add lower-id nodes that spread would prefer; the replica must stay pinned to n3.
        f.addNode("n1"); f.addNode("n2")
        for _ in 0..<3 {
            lp.step()
            check(f.assignmentNode("db--r1-s0-g1") == "n3", "3: pinned to n3, never spread to n1/n2")
        }

        // Even after the Cell is torn down, it returns to the bound node — never elsewhere.
        f.removeAssignment(node: "n3", cellId: "db--r1-s0-g1")
        lp.step()
        let a = f.assignments()
        check(a.count == 1 && a.first?.node == "n3", "3: re-placed back on bound node n3 after teardown")
    }

    // MARK: - Case 4: bound node down → Pending → returns → same node, same PV

    static func case4_nodeDown() {
        let f = Fixture(root: tmpRoot("c4"))
        f.addNode("n1"); f.addNode("n2")
        f.putDeployment(statefulDep("db", replicas: 1, request: req(100, 64 << 20)))
        let lp = f.loop()
        lp.step()
        guard let node = f.assignments().first?.node else { check(false, "4: placed"); return }
        let mgr = f.manager(node: node)
        check(mgr.acquire(cellId: "db--r1-s0-g1", volume: dataVol), "4: bound to \(node)")
        let vid = VolumeId.make(app: "db", ordinal: 0)

        // The bound node goes down (lease expires).
        f.killNode(node)
        lp.step()
        check(f.assignments().isEmpty, "4: bound node down → Assignment removed, NOT re-placed elsewhere")
        let pend = f.pendings()
        check(pend.count == 1 && pend[0].app == "db" && pend[0].slot == 0, "4: ordinal 0 is Pending while node down")
        check(pend.first?.reason.contains("down") == true, "4: pending reason cites the down node")
        check(f.volumeRecord(vid)?.node == node, "4: the binding still names the down node")

        // The node returns — re-placed on the SAME node with the SAME PV.
        f.addNode(node)
        lp.step()
        let a = f.assignments()
        check(a.count == 1 && a.first?.node == node, "4: re-placed on the same node when it returns")
        check(f.pendings().isEmpty, "4: pending cleared once placed")
        check(f.datafs.exists(volumeId: vid), "4: the same PV data is intact")
        check(f.volumeRecord(vid)?.node == node, "4: still bound to the same node")
    }

    // MARK: - Case 5: single mount — two writers never overlap

    static func case5_singleMountNoOverlap() {
        // (a) Direct: a second writer is refused while the first holds the volume.
        let f = Fixture(root: tmpRoot("c5a"))
        let vid = VolumeId.make(app: "db", ordinal: 0)
        let mgr = f.manager(node: "n1")
        check(mgr.acquire(cellId: "db--r1-s0-g1", volume: dataVol), "5: first writer mounts")
        check(mgr.isMounted(vid) && mgr.holder(vid) == "db--r1-s0-g1", "5: held by gen1")
        let tok = f.volumeRecord(vid)?.fencingToken ?? 0
        check(mgr.mount(volumeId: vid, cellId: "db--r1-s0-g2", token: tok) == .alreadyMounted(holder: "db--r1-s0-g1"),
              "5: a second writer is refused while the first holds it (no overlap)")
        check(mgr.peakConcurrency(vid) == 1, "5: never two simultaneous writers")
        // Only after the first is fenced (teardown confirmed) does the second mount.
        mgr.fence(cellId: "db--r1-s0-g1", volume: dataVol)
        check(!mgr.isMounted(vid), "5: released after the prior teardown is confirmed")
        check(mgr.mount(volumeId: vid, cellId: "db--r1-s0-g2", token: tok) == .granted(token: tok),
              "5: the second writer mounts only after teardown")
        check(mgr.peakConcurrency(vid) == 1, "5: still never two writers")

        // (b) Through the reconcile loop: a generation bump recreates the Cell — destroy must
        // fence the PV before the new generation re-acquires it (no overlap in the real loop).
        let store = openRamCubeStore()
        let images = SignedImages(seedByte: 0x55)
        let img = images.signAndStage(Array("dbimg".utf8))
        let clock = ManualClock(startUnix)
        let datafs = HostDirVolumeStore(root: tmpRoot("c5b"))
        let client = LocalStoreClient(store)
        let mgrR = VolumeManager(node: "node-a", store: client, datafs: datafs)
        let sup = FakeCellSupervisor(clock: clock)
        let rec = Reconciler(node: "node-a", store: client, supervisor: sup,
                             verifier: ImageVerifier(trustedKey: images.publicKey), imageStore: images,
                             clock: clock, fence: mgrR, mounter: mgrR)
        let spec = CellSpec(cellId: "db--r1-s0-g1", node: "node-a", image: img, capabilities: [],
                            resources: req(100, 64 << 20), namespaceRoot: "/", args: ["/bin/db"],
                            env: [], tmpfsScratch: true, volume: dataVol, restartPolicy: .always)
        _ = store.apply([.put(key: SletKeys.assignment(node: "node-a", cellId: "db--r1-s0-g1"),
                              value: Assignment(generation: 1, spec: spec).encode())])
        rec.bootstrap()
        let vid2 = VolumeId.make(app: "db", ordinal: 0)
        check(sup.isRunning("db--r1-s0-g1"), "5: stateful Cell running through the reconcile loop")
        check(mgrR.isMounted(vid2), "5: PV mounted by the running Cell")

        // Bump the generation → drift → atomic recreate (destroy fences, then re-acquire).
        _ = store.apply([.put(key: SletKeys.assignment(node: "node-a", cellId: "db--r1-s0-g1"),
                              value: Assignment(generation: 2, spec: spec).encode())])
        rec.step()
        check(sup.fencedVolumes.contains("data"), "5: teardown fenced the volume before recreate")
        check(mgrR.peakConcurrency(vid2) == 1, "5: the recreate never overlapped two writers on the PV")
        check(sup.isRunning("db--r1-s0-g1") && mgrR.isMounted(vid2), "5: the new generation holds the single writer")
    }

    // MARK: - Case 6: a stale fencing token is refused

    static func case6_staleToken() {
        let f = Fixture(root: tmpRoot("c6"))
        let vid = VolumeId.make(app: "db", ordinal: 0)
        // Node A binds + mounts the volume (token 1), then releases it.
        let mgrA = VolumeManager(node: "nA", store: LocalStoreClient(f.store), datafs: f.datafs)
        guard let recA = mgrA.provisionAndBind(app: "db", ordinal: 0, name: "data", mountPath: "/data") else {
            check(false, "6: nA provisions"); return
        }
        check(recA.fencingToken == 1, "6: first bind token is 1")
        check(mgrA.mount(volumeId: vid, cellId: "db--r1-s0-g1", token: 1) == .granted(token: 1), "6: nA mounts with token 1")
        mgrA.unmount(volumeId: vid, cellId: "db--r1-s0-g1")

        // A partitioned controller rebinds the volume to node B → the token bumps to 2.
        let mgrB = VolumeManager(node: "nB", store: LocalStoreClient(f.store), datafs: f.datafs)
        guard let recB = mgrB.provisionAndBind(app: "db", ordinal: 0, name: "data", mountPath: "/data") else {
            check(false, "6: nB rebinds"); return
        }
        check(recB.node == "nB" && recB.fencingToken == 2, "6: rebind moves the binding and bumps the token to 2")

        // nA, still on the old generation, tries to mount with the now-stale token 1 → REFUSED.
        check(mgrA.mount(volumeId: vid, cellId: "db--r1-s0-g2", token: 1) == .staleToken(current: 2),
              "6: a mount with a stale token is refused")
        // nB, with the current token, is granted — exactly one writer wins the partition.
        check(mgrB.mount(volumeId: vid, cellId: "db--r1-s0-g1", token: 2) == .granted(token: 2),
              "6: the current-token holder mounts")
    }

    // MARK: - Case 7: retain by default; delete is explicit

    static func case7_retain() {
        let f = Fixture(root: tmpRoot("c7"))
        let mgr = f.manager(node: "n1")
        let vid0 = VolumeId.make(app: "db", ordinal: 0)
        check(mgr.acquire(cellId: "db--r1-s0-g1", volume: dataVol), "7: provision + mount ordinal 0")
        check(f.datafs.writeFile(volumeId: vid0, name: "state", bytes: Array("keep".utf8)) == .ok, "7: write state")

        // Routine teardown RETAINS the data.
        mgr.fence(cellId: "db--r1-s0-g1", volume: dataVol)
        check(f.datafs.exists(volumeId: vid0), "7: routine teardown RETAINS the PV")
        check(f.volumeRecord(vid0)?.state == .released, "7: volume released (not deleted) on teardown")
        check(f.datafs.readFile(volumeId: vid0, name: "state") == Array("keep".utf8), "7: data kept after teardown")

        // Explicit Delete removes it.
        check(mgr.delete(volumeId: vid0), "7: explicit Delete succeeds")
        check(!f.datafs.exists(volumeId: vid0), "7: PV subtree removed by Delete")
        check(f.volumeRecord(vid0)?.state == .deleted, "7: record tombstoned")

        // Delete is refused while a live writer holds the volume.
        let vid1 = VolumeId.make(app: "db", ordinal: 1)
        check(mgr.acquire(cellId: "db--r1-s1-g1", volume: dataVol), "7: mount ordinal 1")
        check(!mgr.delete(volumeId: vid1), "7: Delete refused while the volume is mounted")
        check(f.datafs.exists(volumeId: vid1), "7: a mounted volume is never deleted out from under its writer")
    }

    // MARK: - Case 8: stable (app, ordinal) identity + PV across generations & revisions

    static func case8_stableIdentity() {
        let f = Fixture(root: tmpRoot("c8"))
        let vid = VolumeId.make(app: "db", ordinal: 0)
        let mgr = f.manager(node: "n1")

        // Generation 1 mounts and writes.
        check(mgr.acquire(cellId: "db--r1-s0-g1", volume: dataVol), "8: gen1 acquires the PV")
        let path1 = f.datafs.path(volumeId: vid)
        check(f.datafs.writeFile(volumeId: vid, name: "state", bytes: Array("v1".utf8)) == .ok, "8: gen1 writes")

        // A NEW generation (g2) of the same ordinal re-attaches the SAME PV.
        mgr.fence(cellId: "db--r1-s0-g1", volume: dataVol)
        check(mgr.acquire(cellId: "db--r1-s0-g2", volume: dataVol), "8: gen2 re-acquires the same PV")
        check(f.datafs.path(volumeId: vid) == path1, "8: same datafs path across generations")
        check(f.datafs.readFile(volumeId: vid, name: "state") == Array("v1".utf8), "8: data preserved across generations")

        // A NEW revision (r2) still maps to the same (app, ordinal) PV.
        mgr.fence(cellId: "db--r1-s0-g2", volume: dataVol)
        check(VolumeId.forCellId("db--r2-s0-g1") == vid, "8: volumeId stable across revisions")
        check(mgr.acquire(cellId: "db--r2-s0-g1", volume: dataVol), "8: new revision re-acquires the same PV")
        check(f.datafs.readFile(volumeId: vid, name: "state") == Array("v1".utf8), "8: data preserved across revisions")

        // The binding never changed node/identity.
        guard let rec = f.volumeRecord(vid) else { check(false, "8: record present"); return }
        check(rec.app == "db" && rec.ordinal == 0 && rec.node == "n1", "8: stable (app, ordinal) binding on n1")
    }
}
