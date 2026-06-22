// SPDX-License-Identifier: Apache-2.0
// ProbeRunner.swift — the per-Cell readiness/liveness state machine driven by slet (SC5).
//
// The runner owns the debounced health state for every Cell `slet` supervises. It is a
// thin, deterministic layer over the `ProbeProber` seam: each pass the reconciler calls
// `run()`, the runner fires whichever probes are due (respecting each probe's `period`
// and `initialDelay`), folds the outcome into consecutive success/failure counters, and
// flips the Cell's readiness / liveness verdict only when a threshold is crossed. The
// reconciler then reads `verdict(cellId)` to (a) write `ready` into the Cell status and
// (b) restart a Cell whose liveness has failed. All timing comes from the injected
// `CubeClock`, so host tests advance time by hand and the machine is fully deterministic.
//
// Readiness and liveness are kept strictly distinct (the SC5 contract):
//   • readiness flip ⇒ only the `ready` bit moves (the endpoints loop adds/removes the
//     Cell); the Cell is NEVER restarted for a readiness failure.
//   • liveness flip to failed ⇒ the reconciler restarts the Cell; the runner is reset for
//     the fresh generation (a new `initialDelay` window, counters cleared).
//
// Bookkeeping is a plain array keyed by cellId (no Dictionary — matching the cubestore /
// reconciler idiom; per-node Cell counts are small). Foundation-free.

/// The debounced verdict for one Cell, read by the reconciler each pass.
struct ProbeVerdict: Equatable {
    var ready: Bool            // readiness gate (false until a configured readiness probe passes)
    var livenessFailed: Bool   // true once liveness has failed past its threshold
    var hasReadinessProbe: Bool // whether readiness is probe-gated (vs. ready-when-running)
}

/// Per-probe consecutive-outcome counters + scheduling cursor.
private struct ProbeCounters {
    var consecutiveSuccess: UInt32 = 0
    var consecutiveFailure: UInt32 = 0
    var lastRunAt: UInt64 = 0
    var hasRun: Bool = false
}

/// One Cell's tracked probe state.
private struct TrackedCell {
    var cellId: String
    var address: String
    var readiness: ProbeSpec
    var liveness: ProbeSpec
    var startedAt: UInt64
    var rc = ProbeCounters()
    var lc = ProbeCounters()
    var ready: Bool             // current readiness verdict
    var livenessFailed: Bool    // current liveness verdict
}

final class ProbeRunner {
    let prober: ProbeProber
    let clock: CubeClock

    private var cells: [TrackedCell] = []

    init(prober: ProbeProber, clock: CubeClock) {
        self.prober = prober; self.clock = clock
    }

    private func idx(_ cellId: String) -> Int? {
        for i in 0..<cells.count where cells[i].cellId == cellId { return i }
        return nil
    }

    // MARK: - Tracking (driven by the reconciler's create/adopt/restart/reap)

    /// Begin (or restart) tracking a Cell's probes. Called when a generation launches; on a
    /// restart the reconciler calls it again with the new `startedAt`, which resets every
    /// counter and re-opens the `initialDelay` window. A Cell with an active readiness probe
    /// starts NOT ready (it must prove readiness first); without one it is ready when running.
    func track(cellId: String, address: String, readiness: ProbeSpec, liveness: ProbeSpec, startedAt: UInt64) {
        let initialReady = !readiness.isActive   // no readiness probe ⇒ ready as soon as it runs
        let t = TrackedCell(cellId: cellId, address: address, readiness: readiness,
                            liveness: liveness, startedAt: startedAt,
                            ready: initialReady, livenessFailed: false)
        if let i = idx(cellId) { cells[i] = t } else { cells.append(t) }
    }

    /// Stop tracking a Cell (reaped, terminal, or about to be re-tracked for a new generation).
    func untrack(_ cellId: String) {
        if let i = idx(cellId) { cells.remove(at: i) }
    }

    func isTracked(_ cellId: String) -> Bool { idx(cellId) != nil }

    /// The current debounced verdict for a Cell, or nil if it is not tracked.
    func verdict(_ cellId: String) -> ProbeVerdict? {
        guard let i = idx(cellId) else { return nil }
        let t = cells[i]
        return ProbeVerdict(ready: t.ready, livenessFailed: t.livenessFailed,
                            hasReadinessProbe: t.readiness.isActive)
    }

    // MARK: - One pass: fire due probes, fold outcomes into the verdicts

    /// Run every probe that is due as of `clock.nowSeconds()`. Idempotent within an instant
    /// (a probe will not re-run before its period elapses), so extra reconcile passes never
    /// distort the counters.
    func run() {
        let now = clock.nowSeconds()
        for i in 0..<cells.count {
            stepReadiness(&cells[i], now: now)
            stepLiveness(&cells[i], now: now)
        }
    }

    private func stepReadiness(_ t: inout TrackedCell, now: UInt64) {
        guard t.readiness.isActive else { return }     // ready-when-running; nothing to do
        guard let outcome = fire(t.readiness, address: t.address, startedAt: t.startedAt,
                                 counters: &t.rc, now: now) else { return }
        switch outcome {
        case .healthy:   t.ready = true
        case .unhealthy: t.ready = false
        case .pending:   break                         // below threshold ⇒ hold (debounce)
        }
    }

    private func stepLiveness(_ t: inout TrackedCell, now: UInt64) {
        guard t.liveness.isActive else { return }      // no liveness probe ⇒ never fails
        guard let outcome = fire(t.liveness, address: t.address, startedAt: t.startedAt,
                                 counters: &t.lc, now: now) else { return }
        switch outcome {
        case .healthy:   t.livenessFailed = false      // recovered before the reconciler acted
        case .unhealthy: t.livenessFailed = true
        case .pending:   break
        }
    }

    private enum Threshold { case healthy, unhealthy, pending }

    /// Fire one probe if it is due, fold its outcome into `counters`, and report whether a
    /// threshold was crossed. Returns nil if the probe did not run this pass (startup window
    /// not elapsed, or its period has not come round yet).
    private func fire(_ spec: ProbeSpec, address: String, startedAt: UInt64,
                      counters: inout ProbeCounters, now: UInt64) -> Threshold? {
        // Startup grace: no probe runs — and so none can fail — before initialDelay elapses.
        let openAt = startedAt &+ UInt64(spec.initialDelaySeconds)
        if now < openAt { return nil }
        // Period gate: don't re-run before the period elapses (first run fires immediately).
        let period = UInt64(spec.periodSeconds == 0 ? 1 : spec.periodSeconds)
        if counters.hasRun && now < counters.lastRunAt &+ period { return nil }

        let outcome = prober.probe(spec, address: address)
        counters.lastRunAt = now
        counters.hasRun = true
        switch outcome {
        case .success:
            counters.consecutiveSuccess &+= 1
            counters.consecutiveFailure = 0
            let need = spec.successThreshold == 0 ? 1 : spec.successThreshold
            return counters.consecutiveSuccess >= need ? .healthy : .pending
        case .failure, .timeout:
            counters.consecutiveFailure &+= 1
            counters.consecutiveSuccess = 0
            let need = spec.failureThreshold == 0 ? 1 : spec.failureThreshold
            return counters.consecutiveFailure >= need ? .unhealthy : .pending
        }
    }
}
