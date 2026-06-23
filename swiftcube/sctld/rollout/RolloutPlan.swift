// SPDX-License-Identifier: Apache-2.0
// RolloutPlan.swift — the pure rollout state-transition functions (SC9b).
//
// Like SC4 split the pure `schedule()` from the store-backed `SchedulerLoop`, the rollout splits
// its decision logic (here — a deterministic function of the record + observed readiness + clock)
// from the store reconcile loop (RolloutController.swift). That makes the rolling/blue-green/canary
// strategies and the automatic rollback trivially testable (cases 3–8 call these directly) and
// keeps the loop a thin read→plan→write shell (case 9).
//
// The model: a rollout transitions ONE app from an old revision to a new (target) revision. The
// plan tracks a per-revision DESIRED replica count and a TRAFFIC weight; the controller writes the
// counts to /schedrev (the scheduler places them) and the weights to /traffic (the LB/endpoints
// admit them). Readiness is observed per revision (SC5) and is the gate every strategy waits on.

// MARK: - Helpers

private func ceilDiv(_ a: UInt32, _ b: UInt32) -> UInt32 { b == 0 ? 0 : (a &+ b &- 1) / b }
private func subClamp(_ a: UInt32, _ b: UInt32) -> UInt32 { a >= b ? a - b : 0 }

/// The non-target ("old") revision still present in the plan, if any.
private func oldRevision(_ rec: RolloutRecord) -> UInt64? {
    for r in rec.revisions where r.revision != rec.targetRevision { return r.revision }
    return nil
}

// MARK: - Start / restart a rollout toward a new target

/// Build the initial record for a rollout toward `targetRevision` (replicas `N`, strategy `update`).
/// `oldRevision` is the revision currently serving (nil on a first deploy). Called by the controller
/// when it detects a new target. `history` is the prior target history to extend.
func startRollout(app: String, targetRevision: UInt64, replicas N: UInt32, update: UpdateStrategy,
                  oldRevision: UInt64?, history: [UInt64], now: UInt64) -> RolloutRecord {
    var hist = history
    if let o = oldRevision, !hist.contains(o) { hist.append(o) }
    if !hist.contains(targetRevision) { hist.append(targetRevision) }

    var rec = RolloutRecord(app: app, strategy: update.strategy, targetRevision: targetRevision,
                            replicas: N, maxSurge: update.maxSurge, maxUnavailable: update.maxUnavailable,
                            canarySteps: update.canaryStepPercents.isEmpty ? [100] : update.canaryStepPercents,
                            canaryIndex: 0, progressDeadlineSeconds: update.progressDeadlineSeconds,
                            startedAtSeconds: now, phase: .progressing, revisions: [], weights: [],
                            blueGreenSwitched: false, failedRevision: 0, history: hist, message: "")

    guard let old = oldRevision else {
        // First deploy: just bring the target up to N; complete when ready.
        rec.revisions = [RevisionDesired(revision: targetRevision, desired: N)]
        rec.weights = [TrafficShare(revision: targetRevision, weight: 100)]
        return rec
    }
    switch update.strategy {
    case .rolling:
        // Start old at N, new at 0; the step function surges new and drains old as new becomes ready.
        rec.revisions = [RevisionDesired(revision: old, desired: N),
                         RevisionDesired(revision: targetRevision, desired: 0)]
        rec.weights = [TrafficShare(revision: old, weight: 100)]
    case .blueGreen:
        // Bring the full new revision up alongside the old; traffic stays 100% old until the switch.
        rec.revisions = [RevisionDesired(revision: old, desired: N),
                         RevisionDesired(revision: targetRevision, desired: N)]
        rec.weights = [TrafficShare(revision: old, weight: 100)]
    case .canary:
        let p = rec.canarySteps[0]
        let newD = ceilDiv(N &* p, 100)
        rec.revisions = [RevisionDesired(revision: old, desired: subClamp(N, newD)),
                         RevisionDesired(revision: targetRevision, desired: newD)]
        rec.weights = [TrafficShare(revision: old, weight: subClamp(100, p)),
                       TrafficShare(revision: targetRevision, weight: p)]
    }
    return rec
}

// MARK: - One reconcile step

/// Advance a Progressing rollout by one step against the observed readiness, or trip the automatic
/// rollback if the progress deadline has passed without the target reaching its ready target. Pure:
/// the same (rec, observed, now) always yields the same result. A terminal rollout (complete/failed)
/// is returned unchanged.
func planRollout(_ input: RolloutRecord, observed: [RevisionObservation], now: UInt64) -> RolloutRecord {
    var rec = input
    guard rec.phase == .progressing else { return rec }

    // Automatic rollback: deadline exceeded and the target has not reached N ready.
    let N = rec.replicas
    let newReady = observed.ready(rec.targetRevision)
    if now &- rec.startedAtSeconds > UInt64(rec.progressDeadlineSeconds) && !targetSatisfied(rec, observed) {
        return rollback(rec, observed: observed)
    }

    // A first deploy (no old revision to shift from) just brings the target up to N regardless of
    // strategy — canary/blue-green are degenerate with nothing to compare against.
    if oldRevision(rec) == nil {
        stepFirstDeploy(&rec, observed: observed)
        return rec
    }

    switch rec.strategy {
    case .rolling:   stepRolling(&rec, observed: observed)
    case .blueGreen: stepBlueGreen(&rec, observed: observed)
    case .canary:    stepCanary(&rec, observed: observed)
    }
    _ = newReady; _ = N
    return rec
}

private func stepFirstDeploy(_ rec: inout RolloutRecord, observed: [RevisionObservation]) {
    rec.revisions = [RevisionDesired(revision: rec.targetRevision, desired: rec.replicas)]
    rec.weights = [TrafficShare(revision: rec.targetRevision, weight: 100)]
    if observed.ready(rec.targetRevision) >= rec.replicas { complete(&rec) }
}

/// Whether the target revision has reached its full readiness for the strategy (so the deadline is
/// moot). For blue-green/canary the "satisfied" bar before completion is N ready new.
private func targetSatisfied(_ rec: RolloutRecord, _ observed: [RevisionObservation]) -> Bool {
    observed.ready(rec.targetRevision) >= rec.replicas
}

// MARK: - Rolling

private func stepRolling(_ rec: inout RolloutRecord, observed: [RevisionObservation]) {
    let N = rec.replicas, S = rec.maxSurge, U = rec.maxUnavailable
    let new = rec.targetRevision
    let newReady = observed.ready(new)
    let old = oldRevision(rec)
    let oldDesiredCur = old.map { rec.desired($0) } ?? 0
    let oldReady = old.map { observed.ready($0) } ?? 0

    // Keep availability ≥ N − maxUnavailable: old may shrink only to cover the gap new-ready hasn't
    // filled. With maxUnavailable = 0 the old revision stays at N until the new is fully ready.
    let minAvail = subClamp(N, U)
    let oldDesired = min(oldDesiredCur, subClamp(minAvail, newReady))
    // Grow new to the surge ceiling above whatever old remains; never reduce new.
    var newDesired = min(N, subClamp(N &+ S, oldDesired))
    newDesired = max(newDesired, rec.desired(new))

    var revs: [RevisionDesired] = []
    if let o = old, (oldDesired > 0 || oldReady > 0) { revs.append(RevisionDesired(revision: o, desired: oldDesired)) }
    revs.append(RevisionDesired(revision: new, desired: newDesired))
    rec.revisions = revs
    rec.weights = rotationWeights(revs, observed: observed)

    if newReady >= N && oldDesired == 0 && oldReady == 0 {
        complete(&rec)
    }
}

// MARK: - Blue-green

private func stepBlueGreen(_ rec: inout RolloutRecord, observed: [RevisionObservation]) {
    let N = rec.replicas
    let new = rec.targetRevision
    let newReady = observed.ready(new)
    let old = oldRevision(rec)
    let oldReady = old.map { observed.ready($0) } ?? 0
    let oldRunning = old.map { observed.running($0) } ?? 0

    if !rec.blueGreenSwitched {
        // Full new up alongside old; no traffic to new until ALL new Cells are ready.
        var revs = [RevisionDesired(revision: new, desired: N)]
        if let o = old { revs.insert(RevisionDesired(revision: o, desired: N), at: 0) }
        rec.revisions = revs
        rec.weights = old != nil ? [TrafficShare(revision: old!, weight: 100)]
                                 : [TrafficShare(revision: new, weight: 100)]
        if newReady >= N {
            rec.blueGreenSwitched = true                    // atomic switch old → new
            rec.weights = [TrafficShare(revision: new, weight: 100)]
        } else {
            return
        }
    }
    // Switched: tear the old revision down; complete once it is gone.
    if let o = old, (oldReady > 0 || oldRunning > 0) {
        rec.revisions = [RevisionDesired(revision: o, desired: 0), RevisionDesired(revision: new, desired: N)]
        rec.weights = [TrafficShare(revision: new, weight: 100)]
    } else {
        rec.revisions = [RevisionDesired(revision: new, desired: N)]
        rec.weights = [TrafficShare(revision: new, weight: 100)]
        if newReady >= N { complete(&rec) }
    }
}

// MARK: - Canary

private func stepCanary(_ rec: inout RolloutRecord, observed: [RevisionObservation]) {
    let N = rec.replicas
    let new = rec.targetRevision
    let newReady = observed.ready(new)
    let old = oldRevision(rec)
    let steps = rec.canarySteps
    let i = Int(min(rec.canaryIndex, UInt32(steps.count - 1)))
    let p = steps[i]
    let newDesired = ceilDiv(N &* p, 100)
    let oldDesired = subClamp(N, newDesired)

    if p >= 100 {
        // Final step: full new, drain old, complete once old is gone.
        let oldReady = old.map { observed.ready($0) } ?? 0
        let oldRunning = old.map { observed.running($0) } ?? 0
        if let o = old, (oldReady > 0 || oldRunning > 0) {
            rec.revisions = [RevisionDesired(revision: o, desired: 0), RevisionDesired(revision: new, desired: N)]
        } else {
            rec.revisions = [RevisionDesired(revision: new, desired: N)]
        }
        rec.weights = [TrafficShare(revision: new, weight: 100)]
        if newReady >= N && (old == nil || ((old.map { observed.ready($0) } ?? 0) == 0 && (old.map { observed.running($0) } ?? 0) == 0)) {
            complete(&rec)
        }
        return
    }

    // Intermediate step: hold the split at this weight; advance only when this step's new Cells ready.
    var revs: [RevisionDesired] = []
    if let o = old { revs.append(RevisionDesired(revision: o, desired: oldDesired)) }
    revs.append(RevisionDesired(revision: new, desired: newDesired))
    rec.revisions = revs
    rec.weights = old != nil ? [TrafficShare(revision: old!, weight: subClamp(100, p)),
                                TrafficShare(revision: new, weight: p)]
                             : [TrafficShare(revision: new, weight: 100)]
    if newReady >= newDesired { rec.canaryIndex = rec.canaryIndex &+ 1 }   // ramp on the next pass
}

// MARK: - Rollback / completion

/// Revert to the previous revision: drain the (failed) target to 0, restore the old to N, route all
/// traffic to old, and mark the rollout Failed (the old revision served throughout). The failed
/// revision is recorded so the same broken spec is not auto-retried.
private func rollback(_ input: RolloutRecord, observed: [RevisionObservation]) -> RolloutRecord {
    var rec = input
    let N = rec.replicas
    let failed = rec.targetRevision
    rec.failedRevision = failed
    if let o = oldRevision(rec) {
        rec.revisions = [RevisionDesired(revision: o, desired: N), RevisionDesired(revision: failed, desired: 0)]
        rec.weights = [TrafficShare(revision: o, weight: 100)]
        rec.targetRevision = o                  // the serving revision is the old one again
        rec.blueGreenSwitched = false
        rec.phase = .failed
        rec.message = "progress deadline exceeded — rolled back to r\(o)"
    } else {
        // First deploy with nothing to fall back to: mark failed but keep the (only) revision.
        rec.phase = .failed
        rec.message = "progress deadline exceeded — no previous revision to roll back to"
    }
    return rec
}

private func complete(_ rec: inout RolloutRecord) {
    rec.phase = .complete
    rec.revisions = [RevisionDesired(revision: rec.targetRevision, desired: rec.replicas)]
    rec.weights = [TrafficShare(revision: rec.targetRevision, weight: 100)]
    rec.message = "rolled out to r\(rec.targetRevision)"
}

/// Rolling traffic: every in-rotation revision shares traffic by its ready count (all ready
/// endpoints serve). Falls back to an equal split when nothing is ready yet.
private func rotationWeights(_ revs: [RevisionDesired], observed: [RevisionObservation]) -> [TrafficShare] {
    var totalReady: UInt32 = 0
    for r in revs { totalReady &+= observed.ready(r.revision) }
    if totalReady == 0 {
        // Nothing ready: keep the revision with desired>0 in rotation at 100 (old, early on).
        for r in revs where r.desired > 0 { return [TrafficShare(revision: r.revision, weight: 100)] }
        return revs.isEmpty ? [] : [TrafficShare(revision: revs[0].revision, weight: 100)]
    }
    var out: [TrafficShare] = []
    for r in revs {
        let rd = observed.ready(r.revision)
        if rd > 0 { out.append(TrafficShare(revision: r.revision, weight: rd &* 100 / totalReady)) }
    }
    return out
}
