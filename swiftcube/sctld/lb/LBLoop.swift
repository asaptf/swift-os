// SPDX-License-Identifier: Apache-2.0
// LBLoop.swift — the leader-gated, debounced, level-triggered LB programmer loop (SC6).
//
// This is the controller-side loop that closes the north-south half of design §8: it watches
// each service's `/expose/<service>` config and its SC5 `/endpoints/<service>` set, computes the
// provider-agnostic desired state, and calls `provider.reconcile` to make the external LB's
// backend pool track the live ready endpoints. After each reconcile it records `/lb/<service>`
// (applied generation, healthy, last error).
//
// Like every reconciler in the system it is LEVEL-triggered — each pass re-reads the whole
// /expose + /endpoints world and converges; watch events are only wakeups, so a missed event, a
// reconnect, or a controller restart never matters. The three properties this loop adds on top:
//
//   - LEADER-ONLY: exactly one controller may program the external LB. Two controllers reloading
//     nginx with different configs is the failure mode to prevent, so a follower returns
//     immediately (reuses the SC2/SC4/SC5 `isLeader` signal). A node-loss handover means the new
//     leader re-derives state from /expose + /endpoints and the applier's live config — no
//     in-memory state is authoritative.
//   - DEBOUNCED: rapid endpoint flips (a rollout churning the ready set) are coalesced. A changed
//     desired state (fingerprint) restarts a settle timer; the reconcile fires only once the set
//     has been stable for `debounceWindow`, so a burst of N changes becomes ONE reload.
//   - BACKOFF: a provider/reload failure never crashes the loop. It is recorded in /lb/<service>
//     and retried with capped exponential backoff; because the loop is level-triggered the
//     desired state is simply re-applied on the next eligible pass until it sticks.
//
// Foundation-free; Dictionary-free (small parallel-array state, like the SC4/SC5 reconcilers).
// Generic over the cubestore durability seams, so it runs over the SC2 RAM store in host tests
// and the datafs-backed store on-device unchanged.

final class LBLoop<Log: AppendLog, Snap: SnapshotStore> {
    let store: CubeStore<Log, Snap>
    let clock: CubeClock
    let provider: LBProvider

    /// Leader gate: only the leader programs the LB. Follows Raft leadership once multiple
    /// controllers exist (SC2/SC4/SC5-style).
    var isLeader: Bool

    /// Debounce window in seconds: a desired-state change must be stable this long before it is
    /// applied, coalescing a burst of endpoint flips into one reconcile.
    let debounceWindow: UInt64
    /// Backoff after a failed apply: `backoffBase << min(failures-1, shift cap)`, capped at max.
    let backoffBase: UInt64
    let backoffMax: UInt64

    init(store: CubeStore<Log, Snap>, clock: CubeClock, provider: LBProvider,
         isLeader: Bool = true, debounceWindow: UInt64 = 2,
         backoffBase: UInt64 = 1, backoffMax: UInt64 = 30) {
        self.store = store; self.clock = clock; self.provider = provider
        self.isLeader = isLeader; self.debounceWindow = debounceWindow
        self.backoffBase = backoffBase; self.backoffMax = backoffMax
    }

    // MARK: - Per-service loop state (in-memory; never authoritative — see leader handover note)

    private struct ServiceState {
        var service: String
        var pendingFingerprint: UInt32   // the desired fingerprint currently settling
        var pendingSince: UInt64         // when it last changed (debounce anchor)
        var appliedFingerprint: UInt32   // the desired fingerprint last successfully applied
        var hasApplied: Bool
        var failures: UInt32
        var nextAttemptAt: UInt64        // backoff gate after a failure
    }
    private var states: [ServiceState] = []

    // MARK: - One reconcile pass

    /// Run one level-triggered pass. No-op on a follower.
    func step() {
        guard isLeader else { return }
        let now = clock.nowSeconds()
        let exposes = readExposes()

        var live: [String] = []
        for ex in exposes {
            live.append(ex.service)
            reconcileService(ex, now: now)
        }
        removeStale(live: live)
    }

    // MARK: - Read desired

    private func readExposes() -> [ServiceExpose] {
        var out: [ServiceExpose] = []
        for e in store.prefix(LBKeys.exposePrefix) {
            guard LBKeys.serviceOfExposeKey(e.key) != nil, let ex = ServiceExpose.decode(e.value) else { continue }
            out.append(ex)
        }
        out.sort { $0.service < $1.service }   // deterministic order
        return out
    }

    /// The SC5 ready endpoints backing a service (the backend pool). Empty when the service has
    /// no ready Cell yet — a legal pool the provider renders as an explicit no-backends config.
    private func readEndpoints(_ service: String) -> [Endpoint] {
        guard let e = store.get(EndpointKeys.endpoints(service)),
              let set = EndpointSet.decode(e.value) else { return [] }
        return set.endpoints
    }

    // MARK: - Reconcile one service (debounce + backoff + provider call + status)

    private func reconcileService(_ ex: ServiceExpose, now: UInt64) {
        let desired = LBDesiredState(service: ex.service, listener: ex.listener,
                                     backends: readEndpoints(ex.service), health: ex.health)
        let fp = desired.fingerprint()
        var s = stateFor(ex.service)

        // A wrong-provider expose is a config error, not a crash: report it and do nothing.
        if ex.provider != provider.name {
            writeStatus(service: ex.service, generation: 0, backends: UInt32(desired.backends.count),
                        healthy: false, error: "no provider for \"\(ex.provider)\" (have \"\(provider.name)\")")
            s.pendingFingerprint = fp; s.pendingSince = now
            saveState(s); return
        }

        // Debounce: a changed desired restarts the settle timer.
        if fp != s.pendingFingerprint { s.pendingFingerprint = fp; s.pendingSince = now }

        // Steady state: already applied this exact desired ⇒ idempotent, nothing to do.
        if s.hasApplied && fp == s.appliedFingerprint { saveState(s); return }

        // Still coalescing rapid changes, or backing off after a failure ⇒ defer to a later pass.
        guard now >= s.pendingSince &+ debounceWindow else { saveState(s); return }
        guard now >= s.nextAttemptAt else { saveState(s); return }

        // Apply via the provider (idempotent; validates before swapping; never throws).
        let result = provider.reconcile(desired)
        if result.error == nil {
            s.appliedFingerprint = fp; s.hasApplied = true; s.failures = 0; s.nextAttemptAt = 0
        } else {
            s.failures &+= 1
            s.nextAttemptAt = now &+ backoff(s.failures)
        }
        writeStatus(service: ex.service, generation: result.generation,
                    backends: UInt32(desired.backends.count), healthy: result.healthy, error: result.error)
        saveState(s)
    }

    // MARK: - Remove services whose expose config vanished

    private func removeStale(live: [String]) {
        // Any /lb/<service> status (or in-memory state) without a current /expose config is a
        // removed service: tear down its LB config and delete its status.
        for e in store.prefix(LBKeys.lbPrefix) {
            guard let svc = LBKeys.serviceOfLBKey(e.key), !contains(live, svc) else { continue }
            _ = provider.remove(service: svc)
            _ = store.compareAndApply(conditions: [.modRevisionEquals(key: e.key, e.modRevision)],
                                      [.delete(key: e.key)])
        }
        // Drop in-memory state for services no longer exposed (so a re-add starts clean).
        states.removeAll { !contains(live, $0.service) }
    }

    // MARK: - Status write (CAS, no churn)

    private func writeStatus(service: String, generation: UInt32, backends: UInt32,
                             healthy: Bool, error: String?) {
        let key = LBKeys.lb(service)
        let value = LBStatusRecord(service: service, generation: generation, backends: backends,
                                   healthy: healthy, lastError: error ?? "").encode()
        if let cur = store.get(key) {
            if cur.value == value { return }                              // unchanged ⇒ no churn
            _ = store.compareAndApply(conditions: [.modRevisionEquals(key: key, cur.modRevision)],
                                      [.put(key: key, value: value)])
        } else {
            _ = store.compareAndApply(conditions: [.keyAbsent(key: key)], [.put(key: key, value: value)])
        }
    }

    // MARK: - Backoff schedule

    private func backoff(_ failures: UInt32) -> UInt64 {
        guard failures > 0 else { return 0 }
        let shift = min(UInt64(failures - 1), 5)          // cap the shift so we never overflow
        let v = backoffBase << shift
        return min(v, backoffMax)
    }

    // MARK: - In-memory state helpers (parallel array; keyspaces are small)

    private func stateFor(_ service: String) -> ServiceState {
        for s in states where s.service == service { return s }
        return ServiceState(service: service, pendingFingerprint: 0, pendingSince: 0,
                            appliedFingerprint: 0, hasApplied: false, failures: 0, nextAttemptAt: 0)
    }
    private func saveState(_ s: ServiceState) {
        for i in 0..<states.count where states[i].service == s.service { states[i] = s; return }
        states.append(s)
    }
    private func contains(_ xs: [String], _ x: String) -> Bool {
        for v in xs where v == x { return true }
        return false
    }
}
