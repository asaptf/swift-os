// SPDX-License-Identifier: Apache-2.0
// EndpointsLoop.swift — the leader-gated, level-triggered ready-only endpoints loop (SC5).
//
// This is the controller-side reconciler that closes the readiness half of design §4/§8:
// it watches the Cell statuses `slet` reports and writes, per service, the set of ready,
// reachable endpoints to `/endpoints/<service>` — the input SC6 (LB) and SC7 (east-west)
// consume. Its single correctness property, the foundation safe rollout (SC9) stands on:
// **only a ready Cell is an endpoint.** A Cell that is not ready, has failed/gone away, or
// was torn down (its status went terminal) is simply absent from the rebuilt set, so its
// endpoint disappears.
//
// Like every reconciler in the system it is LEVEL-triggered — each pass re-reads the whole
// `/status/cells/` world and rebuilds the desired endpoint sets from scratch; watch events
// are only wakeups, so a missed/duplicate event, a reconnect, or a controller restart never
// matters. Because the rebuilt set is deterministically sorted, a stable cluster re-encodes
// to byte-identical values and the CAS write is skipped — no churn.
//
// Each pass (`step`):
//   1. Leader gate — only the Raft leader programs endpoints, so two controllers never write
//      conflicting sets. A follower returns immediately (reuses the SC2/SC4 `isLeader` signal).
//   2. Read   — every /status/cells/<id> record.
//   3. Filter — keep only Cells that are READY ∧ phase==running ∧ have a reachable address.
//   4. Group  — by service (service = app for now; the explicit-service-object seam is the
//      `service` field on the status). Sort each group deterministically.
//   5. Apply  — diff the desired sets against the live /endpoints subtree and apply the delta
//      with CAS (create-if-absent / update-on-revision / delete-on-revision), defensively so
//      a stale follower that briefly believes it leads cannot clobber. A service that no
//      longer has any ready Cell has its key deleted.
//
// Foundation-free; Dictionary-free (small linear scans, like the SC3/SC4 reconcilers).
// Generic over the cubestore durability seams, so it runs over the SC2 RAM store in host
// tests and the datafs-backed store on-device unchanged.

final class EndpointsLoop<Log: AppendLog, Snap: SnapshotStore> {
    let store: CubeStore<Log, Snap>

    /// Leader gate (SC2/SC4-style): only the leader writes endpoints. Follows Raft
    /// leadership once multiple controllers exist.
    var isLeader: Bool

    init(store: CubeStore<Log, Snap>, isLeader: Bool = true) {
        self.store = store; self.isLeader = isLeader
    }

    // MARK: - One reconcile pass

    /// Run one level-triggered pass. No-op on a follower.
    func step() {
        guard isLeader else { return }
        let desired = buildDesired()
        applyEndpoints(desired)
    }

    // MARK: - Build the desired endpoint sets from ready Cells

    /// Read every Cell status, keep the ready+reachable ones, and group them into sorted
    /// per-service `EndpointSet`s. The returned array is sorted by service for determinism.
    func buildDesired() -> [EndpointSet] {
        // Grouped accumulation without a Dictionary: a parallel list of (service, endpoints).
        var services: [String] = []
        var groups: [[Endpoint]] = []

        for e in store.prefix(SletKeys.statusCellsPrefix) {
            guard let st = CellStatusRecord.decode(e.value) else { continue }
            guard isEndpointEligible(st) else { continue }
            let ep = Endpoint(cellId: st.cellId, address: st.address, port: st.port)
            if let i = indexOf(services, st.service) {
                groups[i].append(ep)
            } else {
                services.append(st.service); groups.append([ep])
            }
        }

        var out: [EndpointSet] = []
        for i in 0..<services.count {
            var eps = groups[i]
            eps.sort(by: Endpoint.less)
            out.append(EndpointSet(service: services[i], endpoints: eps))
        }
        out.sort { $0.service < $1.service }
        return out
    }

    /// The readiness gate: a Cell is an endpoint iff it is ready, currently running, names a
    /// service, and reports a reachable address. Everything else (not ready, failed, dead/
    /// removed, no address) is excluded — that is how an endpoint is removed.
    private func isEndpointEligible(_ st: CellStatusRecord) -> Bool {
        guard st.ready, st.phase == .running else { return false }
        guard !st.service.isEmpty, !st.address.isEmpty, st.port != 0 else { return false }
        return true
    }

    // MARK: - Apply: diff desired sets against the store, delta via CAS

    private func applyEndpoints(_ desired: [EndpointSet]) {
        let existing = store.prefix(EndpointKeys.endpointsPrefix)

        // Create or update every desired service set.
        var desiredKeys: [Bytes] = []
        for set in desired {
            let key = EndpointKeys.endpoints(set.service)
            desiredKeys.append(key)
            let value = set.encode()
            if let cur = entry(existing, key) {
                if cur.value == value { continue }                       // unchanged ⇒ no churn
                _ = store.compareAndApply(conditions: [.modRevisionEquals(key: key, cur.modRevision)],
                                          [.put(key: key, value: value)])
            } else {
                _ = store.compareAndApply(conditions: [.keyAbsent(key: key)],
                                          [.put(key: key, value: value)])  // create-if-absent
            }
        }

        // Delete the set for any service that no longer has a ready Cell.
        for e in existing where !containsKey(desiredKeys, e.key) {
            _ = store.compareAndApply(conditions: [.modRevisionEquals(key: e.key, e.modRevision)],
                                      [.delete(key: e.key)])
        }
    }

    // MARK: - Small helpers (linear scans; keyspaces are small)

    private func indexOf(_ xs: [String], _ x: String) -> Int? {
        for i in 0..<xs.count where xs[i] == x { return i }
        return nil
    }
    private func entry(_ entries: [Entry], _ key: Bytes) -> Entry? {
        for e in entries where e.key == key { return e }
        return nil
    }
    private func containsKey(_ keys: [Bytes], _ key: Bytes) -> Bool {
        for k in keys where k == key { return true }
        return false
    }
}
