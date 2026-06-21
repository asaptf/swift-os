// SPDX-License-Identifier: Apache-2.0
// Reconciler.swift — slet's level-triggered node reconcile loop (SC3).
//
// The reconciler is the cluster control loop on top of the C6 Cell supervisor. It pulls
// reality toward desired state — NOT off events, but off a full comparison of desired
// (the assignments in cubestore for this node) against actual (the Cells the supervisor
// is running). Watch events are only wakeups; every pass re-derives the world. This is
// what makes it survive missed/duplicate events, reconnects, and slet restarts with no
// duplicate Cells and no orphans (SWIFTCUBE_DESIGN §4, §5).
//
// Each pass (`reconcile`):
//   1. Adopt — register any Cell the supervisor already runs that we don't yet track
//      (this is how a freshly restarted slet re-attaches instead of recreating).
//   2. Converge — for each desired assignment: create a missing Cell (after verifying
//      its signed image), or repair drift (a changed image/generation ⇒ atomic recreate).
//   3. Reap — atomically destroy any tracked Cell no longer desired (teardown verified).
//   4. Supervise — poll running Cells; on a crash apply `restartPolicy` + backoff.
//   5. Report — CAS each Cell's status into /status/cells/<cellId> (don't clobber).
//
// Atomic teardown and PV fencing are slet's responsibility (there is no kernel
// destroy-Cell op — CAPABILITIES §5.3); the fencing hook is the SC8 seam. The Cell book-
// keeping is a plain array keyed by cellId (no Dictionary — matching the cubestore index
// idiom; per-node Cell counts are small). Foundation-free.

/// Tunables for crash-restart backoff.
struct ReconcilerConfig {
    var backoffBaseSeconds: UInt64 = 1     // first restart waits this long
    var backoffMaxSeconds: UInt64  = 30    // cap on exponential growth
}

/// Per-Cell bookkeeping the reconciler owns (the supervisor owns the mechanism).
private struct CellRecord {
    var cellId: String
    var handle: CellHandle?        // nil ⇒ no live generation (failed image / terminal)
    var spec: CellSpec
    var generation: UInt64
    var restartCount: UInt32
    var startedAt: UInt64
    var nextRestartAt: UInt64      // backoff gate: earliest time a restart may run
    var phase: CellPhase
    var ready: Bool
    var message: String
    var terminal: Bool             // failed / never-restart ⇒ no further action
    var lastStatusRev: Revision?   // CAS cursor for /status/cells/<cellId>
    var lastReportedBytes: Bytes   // encoded status last written (skip redundant CAS)
}

final class Reconciler {
    let node: String
    let store: StoreClient
    let supervisor: CellSupervisor
    let verifier: ImageVerifier
    let imageStore: ImageStore
    let clock: CubeClock
    let cfg: ReconcilerConfig
    let fence: VolumeFence?     // SC8 seam (nil in SC3)

    // SC5: the probe runner (nil ⇒ SC3 behavior, ready-when-running, no liveness restarts)
    // and the node's reachable address slet reports for ready Cells. The probe runner hits
    // `nodeAddress` on each probe's port; the endpoints loop reads `nodeAddress` from status.
    // SC7 refines this to a per-Cell node-IP + mapped port.
    let probeRunner: ProbeRunner?
    let nodeAddress: String

    private var cells: [CellRecord] = []
    private(set) var watchRevision: Revision = 0

    /// Exit code the reconciler attributes to a liveness-probe failure when it routes the
    /// Cell through the restart machinery (distinct from a real crash exit, for the message).
    private let livenessFailureExit: Int32 = 137  // SIGKILL-ish: the supervisor would kill a wedged Cell

    init(node: String, store: StoreClient, supervisor: CellSupervisor,
         verifier: ImageVerifier, imageStore: ImageStore, clock: CubeClock,
         config: ReconcilerConfig = ReconcilerConfig(), fence: VolumeFence? = nil,
         probeRunner: ProbeRunner? = nil, nodeAddress: String = "") {
        self.node = node; self.store = store; self.supervisor = supervisor
        self.verifier = verifier; self.imageStore = imageStore; self.clock = clock
        self.cfg = config; self.fence = fence
        self.probeRunner = probeRunner; self.nodeAddress = nodeAddress
    }

    private var assignmentsPrefix: Bytes { SletKeys.nodeAssignmentsPrefix(node) }

    // MARK: - Record store helpers (array keyed by cellId; no Dictionary)

    private func idx(_ cellId: String) -> Int? {
        for i in 0..<cells.count where cells[i].cellId == cellId { return i }
        return nil
    }
    private func upsert(_ rec: CellRecord) {
        if let i = idx(rec.cellId) { cells[i] = rec } else { cells.append(rec) }
    }
    private func removeRecord(_ cellId: String) {
        if let i = idx(cellId) { cells.remove(at: i) }
    }
    private func cellIds() -> [String] { cells.map { $0.cellId } }

    // MARK: - Entry points

    /// Begin watching this node's assignments and run one reconcile pass. Call once at
    /// startup (or after adopting a process from a previous life).
    func bootstrap() {
        store.startWatch(prefix: assignmentsPrefix, from: watchRevision)
        reconcile()
    }

    /// One level-triggered pass: absorb any watch wakeups (advancing the resume cursor)
    /// and converge to desired state.
    func step() {
        for ev in store.poll() where ev.modRevision > watchRevision { watchRevision = ev.modRevision }
        reconcile()
    }

    /// Re-establish the watch from the resume cursor after a transport drop, then
    /// reconcile. Because reconcile is level-triggered, a reconnect does NOT churn
    /// healthy Cells — only genuine desired/actual differences cause action.
    func reconnect() {
        store.startWatch(prefix: assignmentsPrefix, from: watchRevision)
        step()
    }

    // MARK: - The pass

    func reconcile() {
        // Desired: this node's assignments (cellId + Assignment), in store order.
        var desiredIds: [String] = []
        var desiredAsg: [Assignment] = []
        for e in store.list(prefix: assignmentsPrefix) {
            guard let cid = SletKeys.cellId(ofAssignmentKey: e.key, node: node),
                  let asg = Assignment.decode(e.value) else { continue }
            desiredIds.append(cid); desiredAsg.append(asg)
        }
        func desired(_ cid: String) -> Assignment? {
            for i in 0..<desiredIds.count where desiredIds[i] == cid { return desiredAsg[i] }
            return nil
        }

        // 1. Adopt live Cells we don't track yet (slet restarted under running Cells).
        for h in supervisor.liveCells() where idx(h.cellId) == nil {
            adopt(handle: h, desired: desired(h.cellId))
        }

        // 2. Converge: create missing, repair drift.
        for i in 0..<desiredIds.count {
            let cid = desiredIds[i]; let asg = desiredAsg[i]
            if let j = idx(cid) {
                let rec = cells[j]
                if !rec.terminal && rec.handle != nil &&
                    (rec.generation != asg.generation || rec.spec.image.digest != asg.spec.image.digest) {
                    recreate(cid: cid, asg: asg)          // drift ⇒ atomic recreate
                } else if rec.terminal && rec.generation != asg.generation {
                    removeRecord(cid); create(cid: cid, asg: asg)  // a new generation clears a terminal failure
                }
            } else {
                create(cid: cid, asg: asg)
            }
        }

        // 3. Reap: anything tracked but no longer desired → atomic teardown.
        for cid in cellIds() where desired(cid) == nil { reap(cid: cid) }

        // 4. Supervise running Cells (crash detection → restart per policy + backoff).
        for cid in cellIds() { supervise(cid: cid) }

        // 5. Probe pass (SC5): readiness gates `ready`; liveness failure restarts the Cell.
        runProbes()

        // 6. Report status for everything we still track.
        for cid in cellIds() { report(cid: cid) }
    }

    // MARK: - Probe pass (SC5)

    /// One probe pass: keep the runner's tracked set in sync with the running Cells, fire any
    /// due probes, then fold the verdicts back — readiness into `ready` (no restart), liveness
    /// into the restart machinery. A no-op when no `ProbeRunner` is configured (SC3 behavior).
    private func runProbes() {
        guard let pr = probeRunner else { return }

        // Sync tracking: a running, non-terminal Cell with an active probe is tracked with its
        // current address/specs/startedAt; everything else is untracked (so a reaped/failed/
        // restarted-away Cell stops being probed and its readiness can no longer hold).
        for cid in cellIds() {
            guard let i = idx(cid) else { continue }
            let rec = cells[i]
            if rec.handle != nil && !rec.terminal && rec.phase == .running && hasActiveProbe(rec) {
                if !pr.isTracked(cid) {
                    pr.track(cellId: cid, address: nodeAddress, readiness: rec.spec.readiness,
                             liveness: rec.spec.liveness, startedAt: rec.startedAt)
                }
            } else if pr.isTracked(cid) {
                pr.untrack(cid)
            }
        }

        pr.run()

        // Apply verdicts. Readiness only moves the `ready` bit; liveness routes through the
        // restart machinery (the fresh generation re-enters its readiness window, so it is out
        // of endpoints while it restarts).
        for cid in cellIds() {
            guard let v = pr.verdict(cid), let i = idx(cid) else { continue }
            if v.hasReadinessProbe && cells[i].ready != v.ready {
                var rec = cells[i]
                rec.ready = v.ready
                rec.message = v.ready ? "ready" : "not ready (readiness probe failing)"
                upsert(rec)
            }
            if v.livenessFailed {
                pr.untrack(cid)                                   // reset state for the new generation
                applyRestartPolicy(cid: cid, exitCode: livenessFailureExit)
                if let j = idx(cid), cells[j].handle != nil, cells[j].phase == .running {
                    var rec = cells[j]
                    rec.message = "restarted (liveness probe failed)"
                    if rec.spec.readiness.isActive { rec.ready = false }  // re-prove readiness
                    upsert(rec)
                    if hasActiveProbe(rec) {
                        pr.track(cellId: cid, address: nodeAddress, readiness: rec.spec.readiness,
                                 liveness: rec.spec.liveness, startedAt: rec.startedAt)
                    }
                }
            }
        }
    }

    private func hasActiveProbe(_ rec: CellRecord) -> Bool {
        rec.spec.readiness.isActive || rec.spec.liveness.isActive
    }

    // MARK: - Create / adopt / recreate / reap

    private func create(cid: String, asg: Assignment) {
        let spec = asg.spec
        // Image gate: resolve + verify before any Cell is created.
        let v = verifier.verify(spec.image, store: imageStore)
        guard v.ok else {
            upsert(CellRecord(cellId: cid, handle: nil, spec: spec, generation: asg.generation,
                              restartCount: 0, startedAt: 0, nextRestartAt: 0, phase: .failed,
                              ready: false, message: "image rejected: \(reason(v))", terminal: true,
                              lastStatusRev: nil, lastReportedBytes: []))
            return
        }
        switch supervisor.create(spec) {
        case .created(let h):
            upsert(CellRecord(cellId: cid, handle: h, spec: spec, generation: asg.generation,
                              restartCount: 0, startedAt: clock.nowSeconds(), nextRestartAt: 0,
                              phase: .running, ready: true, message: "running", terminal: false,
                              lastStatusRev: nil, lastReportedBytes: []))
        case .rejected(let why):
            upsert(CellRecord(cellId: cid, handle: nil, spec: spec, generation: asg.generation,
                              restartCount: 0, startedAt: 0, nextRestartAt: 0, phase: .failed,
                              ready: false, message: "rejected: \(why)", terminal: true,
                              lastStatusRev: nil, lastReportedBytes: []))
        case .unavailable(let why):
            // C6 not present: record the gap honestly. Not terminal — a later pass on a
            // node where C6 exists would create the Cell.
            upsert(CellRecord(cellId: cid, handle: nil, spec: spec, generation: asg.generation,
                              restartCount: 0, startedAt: 0, nextRestartAt: 0, phase: .failed,
                              ready: false, message: "unavailable: \(why)", terminal: false,
                              lastStatusRev: nil, lastReportedBytes: []))
        }
    }

    /// Re-attach to a Cell the supervisor already runs (post-restart). Restore the
    /// reported restart count / status cursor from /status/cells/<cellId> if present, so
    /// counters survive a slet restart.
    private func adopt(handle: CellHandle, desired: Assignment?) {
        let cid = handle.cellId
        let spec = desired?.spec ?? placeholderSpec(cid: cid)
        let gen = desired?.generation ?? 0
        var restartCount: UInt32 = 0
        var lastRev: Revision? = nil
        if let cur = store.get(SletKeys.status(cid)), let st = CellStatusRecord.decode(cur.value) {
            restartCount = st.restartCount
            lastRev = cur.modRevision
        }
        let rt = supervisor.status(handle)
        upsert(CellRecord(cellId: cid, handle: handle, spec: spec, generation: gen,
                          restartCount: restartCount, startedAt: rt.startedAtSeconds, nextRestartAt: 0,
                          phase: rt.phase, ready: rt.phase == .running, message: "adopted",
                          terminal: false, lastStatusRev: lastRev, lastReportedBytes: []))
    }

    /// Drift repair: atomically tear down the old generation and create the new one,
    /// preserving the restart count.
    private func recreate(cid: String, asg: Assignment) {
        guard let i = idx(cid) else { create(cid: cid, asg: asg); return }
        var rec = cells[i]
        if let h = rec.handle { _ = supervisor.destroy(h, fence: fence) }
        let keepRestart = rec.restartCount
        let v = verifier.verify(asg.spec.image, store: imageStore)
        guard v.ok else {
            rec.handle = nil; rec.spec = asg.spec; rec.generation = asg.generation
            rec.phase = .failed; rec.ready = false; rec.terminal = true
            rec.message = "image rejected: \(reason(v))"
            upsert(rec); return
        }
        switch supervisor.create(asg.spec) {
        case .created(let h):
            rec.handle = h; rec.spec = asg.spec; rec.generation = asg.generation
            rec.restartCount = keepRestart; rec.startedAt = clock.nowSeconds()
            rec.phase = .running; rec.ready = true; rec.terminal = false; rec.message = "running"
        case .rejected(let why):
            rec.handle = nil; rec.spec = asg.spec; rec.generation = asg.generation
            rec.phase = .failed; rec.ready = false; rec.terminal = true; rec.message = "rejected: \(why)"
        case .unavailable(let why):
            rec.handle = nil; rec.spec = asg.spec; rec.generation = asg.generation
            rec.phase = .failed; rec.ready = false; rec.terminal = false; rec.message = "unavailable: \(why)"
        }
        upsert(rec)
    }

    /// Atomic teardown of a no-longer-desired Cell: stop every process, release every
    /// handle (fence volumes first), write a terminal status, and forget it.
    private func reap(cid: String) {
        guard let i = idx(cid) else { return }
        var rec = cells[i]
        if let h = rec.handle {
            let torn = supervisor.destroy(h, fence: fence)
            // A supervisor that cannot verify teardown keeps the record for a retry next
            // pass rather than orphaning the Cell.
            if !torn { return }
        }
        // Terminal status so observers see the instance go away (status GC is a later seam).
        rec.handle = nil; rec.phase = .dead(exitCode: 0); rec.ready = false
        rec.terminal = true; rec.message = "removed (assignment deleted)"
        upsert(rec)
        report(cid: cid)
        removeRecord(cid)
    }

    // MARK: - Supervision (crash → restart per policy)

    private func supervise(cid: String) {
        guard let i = idx(cid), let h = cells[i].handle, !cells[i].terminal else { return }
        let st = supervisor.status(h)
        switch st.phase {
        case .running:
            if cells[i].phase != .running || !cells[i].ready {
                var rec = cells[i]; rec.phase = .running; rec.ready = true; rec.message = "running"; upsert(rec)
            }
        case .created, .stopping:
            var rec = cells[i]; rec.phase = st.phase; rec.ready = false; upsert(rec)
        case .dead(let code):
            applyRestartPolicy(cid: cid, exitCode: code)
        case .failed:
            applyRestartPolicy(cid: cid, exitCode: 1)
        }
    }

    private func applyRestartPolicy(cid: String, exitCode: Int32) {
        guard let i = idx(cid), let dead = cells[i].handle else { return }
        var rec = cells[i]
        let shouldRestart: Bool
        switch rec.spec.restartPolicy {
        case .always:    shouldRestart = true
        case .onFailure: shouldRestart = exitCode != 0
        case .never:     shouldRestart = false
        }

        if !shouldRestart {
            // Tear down the dead generation and stop. A clean exit under OnFailure is a
            // completed run (dead, not failed); everything else is a terminal failure.
            _ = supervisor.destroy(dead, fence: fence)
            rec.handle = nil; rec.ready = false; rec.terminal = true
            if rec.spec.restartPolicy == .onFailure && exitCode == 0 {
                rec.phase = .dead(exitCode: 0); rec.message = "completed"
            } else {
                rec.phase = .failed
                rec.message = "crashed (exit \(exitCode)), restartPolicy=\(policyName(rec.spec.restartPolicy))"
            }
            upsert(rec)
            return
        }

        // Backoff gate: do not restart before the backoff window elapses.
        let now = clock.nowSeconds()
        if now < rec.nextRestartAt {
            rec.phase = .dead(exitCode: exitCode); rec.ready = false
            rec.message = "crashed (exit \(exitCode)); backing off"
            upsert(rec)
            return
        }

        // Atomically tear down the dead generation, then launch a fresh one.
        _ = supervisor.destroy(dead, fence: fence)
        rec.restartCount &+= 1
        let shift = min(UInt64(rec.restartCount), 16)
        let backoff = min(cfg.backoffBaseSeconds << shift, cfg.backoffMaxSeconds)
        rec.nextRestartAt = now &+ backoff

        switch supervisor.create(rec.spec) {
        case .created(let h):
            rec.handle = h; rec.startedAt = now; rec.phase = .running; rec.ready = true
            rec.message = "restarted (#\(rec.restartCount))"; rec.terminal = false
        case .rejected(let why):
            rec.handle = nil; rec.phase = .failed; rec.ready = false; rec.terminal = true
            rec.message = "restart rejected: \(why)"
        case .unavailable(let why):
            rec.handle = nil; rec.phase = .failed; rec.ready = false; rec.terminal = false
            rec.message = "restart unavailable: \(why)"
        }
        upsert(rec)
    }

    // MARK: - Status reporting (CAS, don't clobber)

    private func report(cid: String) {
        guard let i = idx(cid) else { return }
        let rec = cells[i]
        // SC5: report the reachable endpoint only for a Cell that actually holds a live
        // generation; a terminal/torn-down Cell reports an empty address so the endpoints
        // loop cannot keep it (readiness already gates this, but be explicit).
        let addr = (rec.handle != nil && !rec.terminal) ? nodeAddress : ""
        let st = CellStatusRecord(cellId: cid, node: node, phase: rec.phase, ready: rec.ready,
                                  restartCount: rec.restartCount, imageDigest: rec.spec.image.digest,
                                  startedAtSeconds: rec.startedAt, message: rec.message,
                                  service: rec.spec.service, address: addr, port: rec.spec.port)
        let val = st.encode()
        if val == rec.lastReportedBytes { return }   // nothing changed; skip the write
        let key = SletKeys.status(cid)

        // First try the expected cursor (absent for a fresh status). On a CAS miss
        // (another writer, or our cursor is stale after a restart) re-read and retry once.
        if let newRev = store.putCAS(key: key, value: val, expect: rec.lastStatusRev) {
            commitReported(cid: cid, rev: newRev, val: val); return
        }
        if let cur = store.get(key) {
            if let newRev = store.putCAS(key: key, value: val, expect: cur.modRevision) {
                commitReported(cid: cid, rev: newRev, val: val)
            }
        } else if let newRev = store.putCAS(key: key, value: val, expect: nil) {
            commitReported(cid: cid, rev: newRev, val: val)
        }
    }

    private func commitReported(cid: String, rev: Revision, val: Bytes) {
        guard let i = idx(cid) else { return }
        var rec = cells[i]; rec.lastStatusRev = rev; rec.lastReportedBytes = val; upsert(rec)
    }

    // MARK: - Introspection (for tests / observability)

    /// Whether a Cell is currently tracked as running with a live handle.
    func isRunning(_ cellId: String) -> Bool {
        guard let i = idx(cellId) else { return false }
        return cells[i].handle != nil && cells[i].phase == .running
    }
    func liveCellIds() -> [String] { cellIds().filter { isRunning($0) } }
    func restartCount(_ cellId: String) -> UInt32 {
        guard let i = idx(cellId) else { return 0 }
        return cells[i].restartCount
    }

    // MARK: - Helpers

    private func reason(_ v: ImageVerifyResult) -> String {
        switch v {
        case .ok: return "ok"
        case .notStaged: return "not staged locally"
        case .digestMismatch: return "digest mismatch"
        case .badSignature: return "bad signature"
        }
    }
    private func policyName(_ p: RestartPolicy) -> String {
        switch p { case .always: return "Always"; case .onFailure: return "OnFailure"; case .never: return "Never" }
    }
    private func placeholderSpec(cid: String) -> CellSpec {
        CellSpec(cellId: cid, node: node, image: ImageRef(digest: [UInt8](repeating: 0, count: 32), signature: []),
                 capabilities: [], resources: ResourceLimits(cpuMillis: 0, memBytes: 0),
                 namespaceRoot: "/", args: [], env: [], tmpfsScratch: true, volume: nil, restartPolicy: .always)
    }
}
