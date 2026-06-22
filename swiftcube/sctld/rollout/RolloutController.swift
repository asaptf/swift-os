// SPDX-License-Identifier: Apache-2.0
// RolloutController.swift — the leader-gated, level-triggered rollout reconcile loop (SC9b).
//
// The thin store shell around the pure stepper (RolloutPlan.swift): each pass re-reads the world,
// plans one step, and writes the result — so a missed/duplicate watch event, a reconnect, or a
// controller restart never double-steps a rollout (case 9). It is LEADER-ONLY: only the Raft leader
// drives rollouts, reusing the same `isLeader` gate as the SC2 reaper / SC4 scheduler / SC5
// endpoints loop, so two controllers never fight over a revision.
//
// Per app per pass:
//   1. Read the desired Deployment (/apps/<app>/spec) — the target revision/replicas/strategy.
//   2. Observe per-revision readiness from /status/cells (SC5/SC3 report it; the harness fakes it).
//   3. Detect a new target ⇒ start a rollout (snapshot the spec into /history); else step the
//      current rollout (or stay put if it already failed on this exact revision).
//   4. Write the per-revision desired counts to /schedrev (the SC4 scheduler places them), the
//      admitted traffic to /traffic, and the status/history to /rollouts.
//
// Foundation-free; generic over the cubestore durability seams, so it runs over the SC2 RAM store
// in host tests and the datafs-backed store on-device unchanged.

final class RolloutController<Log: AppendLog, Snap: SnapshotStore> {
    let store: CubeStore<Log, Snap>
    let clock: CubeClock
    var isLeader: Bool

    init(store: CubeStore<Log, Snap>, clock: CubeClock, isLeader: Bool = true) {
        self.store = store; self.clock = clock; self.isLeader = isLeader
    }

    // MARK: - One reconcile pass

    func step() {
        guard isLeader else { return }
        let now = clock.nowSeconds()

        // Reconcile every app that has a desired Deployment.
        var liveApps: [String] = []
        for e in store.prefix(SchedulerKeys.appsPrefix) {
            guard let app = SchedulerKeys.appOfSpecKey(e.key), let target = DeploymentSpec.decode(e.value) else { continue }
            liveApps.append(app)
            reconcileApp(app, target: target, now: now)
        }

        // Clean up rollout state for apps whose Deployment was deleted.
        for e in store.prefix(RolloutKeys.rolloutsPrefix) {
            guard let app = RolloutKeys.appOfRolloutKey(e.key), !liveApps.contains(app) else { continue }
            cleanup(app)
        }
    }

    // MARK: - Per-app reconcile

    private func reconcileApp(_ app: String, target: DeploymentSpec, now: UInt64) {
        let current = readRollout(app)
        let observed = observe(app)

        // A rollout that already failed on THIS exact revision is not auto-retried: it stays Failed
        // (serving the old revision) until a different spec is applied. The /schedrev written at the
        // failure pass keeps the old revision at N, so we simply leave everything in place.
        if let rec = current, rec.phase == .failed, target.revision == rec.failedRevision {
            return
        }

        var rec: RolloutRecord
        if current == nil || (target.revision != current!.targetRevision && target.revision != current!.failedRevision) {
            // New target ⇒ start (or restart) a rollout toward it. Snapshot the desired spec so the
            // draining old revision and a later `undo` can recover it.
            snapshotHistory(app: app, spec: target)
            let old = current?.targetRevision     // the revision currently serving (nil on first deploy)
            rec = startRollout(app: app, targetRevision: target.revision, replicas: target.replicas,
                               update: target.update, oldRevision: old,
                               history: current?.history ?? [], now: now)
        } else {
            // Continue the in-flight rollout: keep N/strategy params fresh, then step.
            rec = current!
            rec.replicas = target.replicas
            rec.maxSurge = target.update.maxSurge
            rec.maxUnavailable = target.update.maxUnavailable
            rec.progressDeadlineSeconds = target.update.progressDeadlineSeconds
            rec = planRollout(rec, observed: observed, now: now)
        }

        writeOutputs(app: app, rec: rec, target: target)
    }

    // MARK: - Observe readiness from /status/cells

    /// Count running/ready Cells per revision for one app (the SC5 readiness signal the rollout
    /// gates on). Foundation-free linear scan; the status keyspace is small.
    private func observe(_ app: String) -> [RevisionObservation] {
        var revs: [UInt64] = []
        var running: [UInt32] = []
        var ready: [UInt32] = []
        for e in store.prefix(SletKeys.statusCellsPrefix) {
            guard let st = CellStatusRecord.decode(e.value), let id = CellIdCodec.parse(st.cellId), id.app == app else { continue }
            guard st.phase == .running else { continue }
            let idx: Int
            if let i = indexOf(revs, id.revision) { idx = i }
            else { revs.append(id.revision); running.append(0); ready.append(0); idx = revs.count - 1 }
            running[idx] += 1
            if st.ready { ready[idx] += 1 }
        }
        var out: [RevisionObservation] = []
        for i in 0..<revs.count { out.append(RevisionObservation(revision: revs[i], running: running[i], ready: ready[i])) }
        return out
    }

    // MARK: - Writes

    private func writeOutputs(app: String, rec: RolloutRecord, target: DeploymentSpec) {
        let existing = store.prefix(SchedulerKeys.appSchedRevPrefix(app))
        if rec.phase == .complete {
            // Hand placement back to the SC4 direct path: /apps/<app>/spec already names the target
            // revision at N, and its cellIds match the per-revision spec we were writing, so removing
            // /schedrev is seamless (no churn).
            for e in existing { delete(e.key, e.modRevision) }
        } else {
            var desiredKeys: [Bytes] = []
            for r in rec.revisions {
                guard let spec = specForRevision(app: app, rev: r.revision, desired: r.desired, target: target) else { continue }
                let key = SchedulerKeys.schedRev(app: app, rev: r.revision)
                desiredKeys.append(key)
                putIfChanged(key, spec.encode(), existing)
            }
            for e in existing where !containsKey(desiredKeys, e.key) { delete(e.key, e.modRevision) }
        }

        putIfChanged(RolloutKeys.traffic(app), TrafficPolicy(service: app, shares: rec.weights).encode(), nil)
        putIfChanged(RolloutKeys.rollout(app), rec.encode(), nil)
    }

    /// The DeploymentSpec to schedule for one revision: the live target spec for the target
    /// revision, else the history snapshot, with `replicas` set to the rollout's desired count.
    private func specForRevision(app: String, rev: UInt64, desired: UInt32, target: DeploymentSpec) -> DeploymentSpec? {
        if rev == target.revision {
            var d = target; d.replicas = desired; return d
        }
        guard let e = store.get(RolloutKeys.history(app: app, rev: rev)), var d = DeploymentSpec.decode(e.value) else { return nil }
        d.replicas = desired
        return d
    }

    private func snapshotHistory(app: String, spec: DeploymentSpec) {
        let key = RolloutKeys.history(app: app, rev: spec.revision)
        if store.get(key) == nil { _ = store.apply([.put(key: key, value: spec.encode())]) }
    }

    private func cleanup(_ app: String) {
        for e in store.prefix(SchedulerKeys.appSchedRevPrefix(app)) { delete(e.key, e.modRevision) }
        delete(RolloutKeys.rollout(app), nil)
        delete(RolloutKeys.traffic(app), nil)
        // History snapshots are retained (cheap) for audit; a later same-app deploy reuses them.
    }

    // MARK: - Store helpers (idempotent, leader-gated single writer)

    /// Write `key=value` only if it changed (skip to avoid revision churn — important for "no
    /// double-step" on reconnect). `pool` is a pre-read snapshot to avoid a re-read when available.
    private func putIfChanged(_ key: Bytes, _ value: Bytes, _ pool: [Entry]?) {
        if let pool = pool, let cur = entry(pool, key) {
            if cur.value == value { return }
        } else if let cur = store.get(key), cur.value == value {
            return
        }
        _ = store.apply([.put(key: key, value: value)])
    }

    private func delete(_ key: Bytes, _ modRevision: Revision?) {
        if store.get(key) != nil { _ = store.apply([.delete(key: key)]) }
    }

    private func readRollout(_ app: String) -> RolloutRecord? {
        guard let e = store.get(RolloutKeys.rollout(app)) else { return nil }
        return RolloutRecord.decode(e.value)
    }

    private func indexOf(_ xs: [UInt64], _ x: UInt64) -> Int? { for i in 0..<xs.count where xs[i] == x { return i }; return nil }
    private func entry(_ entries: [Entry], _ key: Bytes) -> Entry? { for e in entries where e.key == key { return e }; return nil }
    private func containsKey(_ keys: [Bytes], _ key: Bytes) -> Bool { for k in keys where k == key { return true }; return false }
}

// MARK: - `rollout undo` (shared by the controller's CLI verb and tests)

/// Revert the desired Deployment to its previous revision from the rollout history, by writing that
/// revision's snapshot back to /apps/<app>/spec. The controller then rolls toward it like any new
/// target. Returns the revision reverted to, or nil if there is no prior revision recorded.
func rolloutUndo<Log, Snap>(app: String, store: CubeStore<Log, Snap>) -> UInt64? {
    guard let re = store.get(RolloutKeys.rollout(app)), let rec = RolloutRecord.decode(re.value) else { return nil }
    // The prior revision is the history entry before the current target.
    var prior: UInt64? = nil
    for h in rec.history where h != rec.targetRevision { prior = h }   // last non-target in order
    guard let target = prior, let he = store.get(RolloutKeys.history(app: app, rev: target)),
          let spec = DeploymentSpec.decode(he.value) else { return nil }
    _ = store.apply([.put(key: SchedulerKeys.appSpec(app), value: spec.encode())])
    return target
}
