// SPDX-License-Identifier: Apache-2.0
// SchedulerLoop.swift — the leader-gated reconcile loop around the pure schedule() (SC4).
//
// This is the controller-side control loop that closes the self-healing cycle of design
// §4: it watches Deployments and live node state, runs the pure placement function, and
// writes the `Assignment` objects SC3's `slet` consumes. Like every reconciler in the
// system it is LEVEL-triggered — each pass re-reads the whole world from cubestore and
// converges; watch events (SC0/SC2) are only wakeups, so a missed or duplicate event
// never matters.
//
// Each pass (`step`):
//   1. Leader gate — only the Raft leader schedules, so two controllers never write
//      conflicting Assignments. A follower returns immediately. (Reuses the same
//      `isLeader` signal SC2's reaper is gated on.)
//   2. Read  — Deployments (/apps/<app>/spec), nodes (/nodes/ + their /leases liveness),
//      current Assignments (/assignments/), and observed status (/status/cells/).
//   3. Decide — call the pure `schedule(...)` to get the desired Assignment set + the
//      pending (unplaceable) list.
//   4. Apply  — diff desired against the live /assignments and apply the delta with CAS
//      (create-if-absent / update-on-revision / delete-on-revision), defensively so a
//      stale follower that briefly believes it leads cannot clobber. Stale Assignments
//      on a dead node fall out of the desired set and are deleted here — that, plus the
//      pure function re-placing their slots, is the node-loss reschedule.
//   5. Pending — write a /pending/<app>/s<slot> marker for each unplaceable replica and
//      clear markers that no longer apply. Replicas are never silently dropped.
//
// Foundation-free; Dictionary-free (small linear scans). Generic over the cubestore
// durability seams like LeaseManager, so it runs over the SC2 RAM store in host tests
// and the datafs-backed store on-device unchanged.

final class SchedulerLoop<Log: AppendLog, Snap: SnapshotStore> {
    let store: CubeStore<Log, Snap>
    let clock: CubeClock
    private let leases: LeaseManager<Log, Snap>

    /// Leader gate (SC2-style): true for a single controller; follows Raft leadership
    /// once multiple controllers exist. Only the leader writes Assignments.
    var isLeader: Bool

    init(store: CubeStore<Log, Snap>, clock: CubeClock, isLeader: Bool = true) {
        self.store = store; self.clock = clock; self.isLeader = isLeader
        self.leases = LeaseManager(store: store, clock: clock)
    }

    // MARK: - One reconcile pass

    /// Run one level-triggered pass. No-op on a follower.
    func step() {
        guard isLeader else { return }
        let deployments = readDeployments()
        let nodes = readNodes()
        let placements = readPlacements(deployments: deployments)
        let bindings = readBindings()
        let result = schedule(deployments: deployments, nodes: nodes, placements: placements,
                              bindings: bindings)
        applyAssignments(result.desired)
        applyPending(result.pending)
    }

    // MARK: - Read: PV bindings (SC8 — distilled from /volumes/<id>)

    /// The node-local sticky bindings the scheduler pins on: every volume that a node has
    /// bound (`bound`/`mounted`/`released` — a `deleted` tombstone is dropped). Written by
    /// `slet` (the node authority); the scheduler only reads them to pin each ordinal.
    private func readBindings() -> [VolumeBinding] {
        var out: [VolumeBinding] = []
        for e in store.prefix(VolumeKeys.volumesPrefix) {
            guard let v = VolumeRecord.decode(e.value), v.state != .deleted, !v.node.isEmpty else { continue }
            out.append(VolumeBinding(app: v.app, ordinal: v.ordinal, node: v.node))
        }
        return out
    }

    // MARK: - Read: Deployments

    private func readDeployments() -> [DeploymentSpec] {
        var out: [DeploymentSpec] = []
        // SC9b: per-revision rollout specs first. An app with any /schedrev entry is "managed" by
        // the rollout controller — the scheduler places each of its revisions and ignores the app's
        // /apps/<app>/spec (else the target revision would be double-counted at full replicas).
        var managed: [String] = []
        for e in store.prefix(SchedulerKeys.schedRevPrefix) {
            guard let (app, _) = SchedulerKeys.parseSchedRev(e.key), let dep = DeploymentSpec.decode(e.value) else { continue }
            out.append(dep)
            if !managed.contains(app) { managed.append(app) }
        }
        for e in store.prefix(SchedulerKeys.appsPrefix) {
            guard let app = SchedulerKeys.appOfSpecKey(e.key), let dep = DeploymentSpec.decode(e.value) else { continue }
            if managed.contains(app) { continue }   // managed by an active rollout
            out.append(dep)
        }
        return out
    }

    // MARK: - Read: nodes (+ lease liveness → healthy)

    private func readNodes() -> [NodeView] {
        var out: [NodeView] = []
        for e in store.prefix(CubeKeys.nodesPrefix) {
            guard let n = NodeRecord.decode(e.value) else { continue }
            out.append(NodeView(id: n.id,
                                healthy: leases.isAlive(id: n.leaseId),
                                capacity: ResourceLimits(cpuMillis: n.capacityCpuMillis, memBytes: n.capacityMemBytes),
                                labels: n.labels))
        }
        return out
    }

    // MARK: - Read: current placements (Assignments joined with observed status)

    private func readPlacements(deployments: [DeploymentSpec]) -> [Placement] {
        // Observed terminal failures keyed by cellId (restart policy exhausted).
        var failedCellIds: [String] = []
        for e in store.prefix(SletKeys.statusCellsPrefix) {
            guard let st = CellStatusRecord.decode(e.value) else { continue }
            if st.phase == .failed { failedCellIds.append(st.cellId) }
        }

        var out: [Placement] = []
        for e in store.prefix(SletKeys.assignmentsPrefix) {
            guard let parsed = SchedulerKeys.parseAssignmentKey(e.key),
                  let asg = Assignment.decode(e.value),
                  let id = CellIdCodec.parse(parsed.cellId) else { continue }
            // The scheduling request comes from the owning Deployment when it still
            // exists (request may differ from the cell's enforced limit); otherwise fall
            // back to the cell's limits so an orphaned replica still accounts for resources.
            var request = asg.spec.resources
            for dep in deployments where dep.app == id.app { request = dep.request; break }
            out.append(Placement(cellId: parsed.cellId, app: id.app, revision: id.revision,
                                 slot: id.slot, generation: id.generation, node: parsed.node,
                                 request: request,
                                 terminalFailed: failedCellIds.contains(parsed.cellId)))
        }
        return out
    }

    // MARK: - Apply: diff desired Assignments against the store, delta via CAS

    private func applyAssignments(_ desired: [DesiredAssignment]) {
        // Snapshot the live /assignments subtree once.
        let existing = store.prefix(SletKeys.assignmentsPrefix)

        // Create or update every desired Assignment.
        var desiredKeys: [Bytes] = []
        for d in desired {
            let key = SletKeys.assignment(node: d.node, cellId: d.cellId)
            desiredKeys.append(key)
            let value = d.assignment.encode()
            if let cur = entry(existing, key) {
                if cur.value == value { continue }                       // unchanged ⇒ no churn
                _ = store.compareAndApply(conditions: [.modRevisionEquals(key: key, cur.modRevision)],
                                          [.put(key: key, value: value)])
            } else {
                _ = store.compareAndApply(conditions: [.keyAbsent(key: key)],
                                          [.put(key: key, value: value)])  // create-if-absent
            }
        }

        // Delete every live Assignment no longer desired: scale-down victims, replaced
        // failures, and — crucially — assignments stranded on a node whose lease expired.
        for e in existing where !containsKey(desiredKeys, e.key) {
            _ = store.compareAndApply(conditions: [.modRevisionEquals(key: e.key, e.modRevision)],
                                      [.delete(key: e.key)])
        }
    }

    // MARK: - Apply: pending markers (no silent drops)

    private func applyPending(_ pending: [PendingPlacement]) {
        let existing = store.prefix(SchedulerKeys.pendingPrefix)
        var keys: [Bytes] = []
        for p in pending {
            let key = SchedulerKeys.pending(app: p.app, slot: p.slot)
            keys.append(key)
            let value = PendingRecord(app: p.app, slot: p.slot, reason: p.reason).encode()
            if let cur = entry(existing, key) {
                if cur.value == value { continue }
                _ = store.compareAndApply(conditions: [.modRevisionEquals(key: key, cur.modRevision)],
                                          [.put(key: key, value: value)])
            } else {
                _ = store.compareAndApply(conditions: [.keyAbsent(key: key)], [.put(key: key, value: value)])
            }
        }
        // Clear stale markers (the replica was placed, or the Deployment shrank/vanished).
        for e in existing where !containsKey(keys, e.key) {
            _ = store.compareAndApply(conditions: [.modRevisionEquals(key: e.key, e.modRevision)],
                                      [.delete(key: e.key)])
        }
    }

    // MARK: - Small helpers (linear scans; keyspaces are small)

    private func entry(_ entries: [Entry], _ key: Bytes) -> Entry? {
        for e in entries where e.key == key { return e }
        return nil
    }
    private func containsKey(_ keys: [Bytes], _ key: Bytes) -> Bool {
        for k in keys where k == key { return true }
        return false
    }
}
