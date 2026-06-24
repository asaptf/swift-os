// SPDX-License-Identifier: Apache-2.0
// ServiceReconciler.swift — the leader-gated, level-triggered service-registry reconciler (SC7).
//
// This is the controller-side loop that materializes the east-west registry: it derives the
// desired set of services, allocates each a stable vIP/proxyPort, and writes /services/<name>
// — the object every node's node-proxy and resolver read. Like every reconciler in the system
// it is LEVEL-triggered (each pass re-derives the world from /svcspec + /endpoints and the live
// /services subtree) and LEADER-ONLY (only the leader allocates, so two controllers never hand
// the same service different vIPs). A follower's `step()` is a no-op.
//
// Desired services = the union of:
//   • explicit /svcspec/<name> objects (the sctl/SC9 seam), and
//   • services SYNTHESIZED from /endpoints/<service> — a service that has ready endpoints but
//     no explicit spec gets one derived from its endpoints (servicePort = the endpoints' port).
//     This is what makes "A reaches B by name" need zero config: B's ready Cells imply service B.
//
// Allocation is deterministic AND stable: a service already in /services keeps its `allocIndex`
// (read back, never reshuffled); a NEW service gets the lowest free index not held by a kept
// service, with new services processed in sorted name order so a fresh allocation is reproducible.
// A service no longer desired has its /services key deleted, freeing its slot. All writes are CAS
// (create-if-absent / update-on-revision / delete-on-revision) so a stale follower that briefly
// believes it leads cannot clobber.
//
// Foundation-free; Dictionary-free (small parallel-array state, like the SC4/SC5/SC6 loops).
// Generic over the cubestore durability seams, so it runs over the SC2 RAM store in host tests
// and the datafs-backed store on-device unchanged.

final class ServiceReconciler<Log: AppendLog, Snap: SnapshotStore> {
    let store: CubeStore<Log, Snap>
    let allocator: ServiceAllocator

    /// Leader gate (SC2/SC4/SC5/SC6-style): only the leader allocates + writes services.
    var isLeader: Bool

    init(store: CubeStore<Log, Snap>, allocator: ServiceAllocator = ServiceAllocator(),
         isLeader: Bool = true) {
        self.store = store; self.allocator = allocator; self.isLeader = isLeader
    }

    // MARK: - One reconcile pass

    /// Run one level-triggered pass. No-op on a follower.
    func step() {
        guard isLeader else { return }
        let desired = buildDesired()
        applyServices(desired)
    }

    // MARK: - Desired set: explicit specs ∪ endpoints-derived

    /// The desired services, sorted by name. Explicit /svcspec wins over a synthesized one
    /// (so an operator can override the derived port/selector).
    func buildDesired() -> [ServiceSpec] {
        var names: [String] = []
        var specs: [ServiceSpec] = []

        // Explicit specs first (authoritative).
        for e in store.prefix(ServiceKeys.svcSpecPrefix) {
            guard ServiceKeys.nameOfSpecKey(e.key) != nil, let s = ServiceSpec.decode(e.value) else { continue }
            if let i = indexOf(names, s.name) { specs[i] = s } else { names.append(s.name); specs.append(s) }
        }

        // Synthesize from endpoints for any service without an explicit spec.
        for e in store.prefix(EndpointKeys.endpointsPrefix) {
            guard let svc = EndpointKeys.service(ofKey: e.key), let set = EndpointSet.decode(e.value),
                  indexOf(names, svc) == nil else { continue }
            let port = derivePort(set.endpoints)
            guard port != 0 else { continue }           // no usable port ⇒ cannot synthesize
            names.append(svc); specs.append(ServiceSpec(name: svc, selector: svc, servicePort: port))
        }

        specs.sort { $0.name < $1.name }
        return specs
    }

    /// The cluster port a synthesized service exposes: the port the endpoints share. Endpoints
    /// of one service all carry the same backend port in v1, so the first one is representative.
    private func derivePort(_ eps: [Endpoint]) -> UInt16 {
        for e in eps where e.port != 0 { return e.port }
        return 0
    }

    // MARK: - Allocate + apply (stable, leader-only, CAS)

    private func applyServices(_ desired: [ServiceSpec]) {
        // 1. Read the live registry: existing allocations are sticky.
        let existing = store.prefix(ServiceKeys.servicesPrefix)
        var current: [Service] = []
        for e in existing {
            guard ServiceKeys.nameOfServiceKey(e.key) != nil, let s = Service.decode(e.value) else { continue }
            current.append(s)
        }

        // 2. Indices held by services that are STILL desired stay reserved.
        var reserved: [UInt32] = []
        for s in current where isDesired(desired, s.name) { reserved.append(s.allocIndex) }

        // 3. Assign each desired service an index: keep an existing one, else lowest free.
        //    `desired` is already sorted by name, so fresh allocation is deterministic.
        var nextFree: UInt32 = 0
        func lowestFree() -> UInt32 {
            while contains(reserved, nextFree) { nextFree &+= 1 }
            let i = nextFree; reserved.append(i); nextFree &+= 1
            return i
        }

        var desiredKeys: [Bytes] = []
        for spec in desired {
            let index: UInt32
            if let cur = currentNamed(current, spec.name) { index = cur.allocIndex } else { index = lowestFree() }
            let svc = Service(name: spec.name, selector: spec.selector, servicePort: spec.servicePort,
                              clusterIP: allocator.clusterIP(index), proxyPort: allocator.proxyPort(index),
                              allocIndex: index)
            let key = ServiceKeys.service(spec.name)
            desiredKeys.append(key)
            writeService(key: key, value: svc.encode(), existing: existing)
        }

        // 4. Delete services no longer desired (frees their slot for a future allocation).
        for e in existing where !containsKey(desiredKeys, e.key) {
            _ = store.compareAndApply(conditions: [.modRevisionEquals(key: e.key, e.modRevision)],
                                      [.delete(key: e.key)])
        }
    }

    /// CAS-write one materialized service, skipping the write when nothing changed (no churn).
    private func writeService(key: Bytes, value: Bytes, existing: [Entry]) {
        if let cur = entry(existing, key) {
            if cur.value == value { return }                                  // unchanged ⇒ no churn
            _ = store.compareAndApply(conditions: [.modRevisionEquals(key: key, cur.modRevision)],
                                      [.put(key: key, value: value)])
        } else {
            _ = store.compareAndApply(conditions: [.keyAbsent(key: key)], [.put(key: key, value: value)])
        }
    }

    // MARK: - Small helpers (linear scans; keyspaces are small)

    private func isDesired(_ d: [ServiceSpec], _ name: String) -> Bool {
        for s in d where s.name == name { return true }
        return false
    }
    private func currentNamed(_ cur: [Service], _ name: String) -> Service? {
        for s in cur where s.name == name { return s }
        return nil
    }
    private func indexOf(_ xs: [String], _ x: String) -> Int? {
        for i in 0..<xs.count where xs[i] == x { return i }
        return nil
    }
    private func entry(_ entries: [Entry], _ key: Bytes) -> Entry? {
        for e in entries where e.key == key { return e }
        return nil
    }
    private func contains(_ xs: [UInt32], _ x: UInt32) -> Bool {
        for v in xs where v == x { return true }
        return false
    }
    private func containsKey(_ keys: [Bytes], _ key: Bytes) -> Bool {
        for k in keys where k == key { return true }
        return false
    }
}
