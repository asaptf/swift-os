// SPDX-License-Identifier: Apache-2.0
// Rollout.swift — the SC9b rollout object, key schema, and per-revision desired/traffic model.
//
// A manifest change creates a new REVISION (the DeploymentSpec.revision SC9a bumps). The rollout
// controller (RolloutController.swift) manages, per app, the transition from the old revision to
// the new one: it drives PER-REVISION desired replica counts (the scheduler places each revision)
// and the TRAFFIC split (the endpoints/LB program only what the rollout admits), gating on SC5
// readiness, and rolls back automatically if the new revision does not converge within a deadline.
//
// The rollout sits ABOVE the scheduler and REUSES it: the controller writes a per-revision
// DeploymentSpec to `/schedrev/<app>/<rev>`, and the SC4 scheduler — which already keys placement
// on `dep.revision` — places each revision independently, sharing node capacity. So surge (old +
// new running at once), readiness gating, and node-loss reschedule all fall out of SC3–SC5
// unchanged; the rollout only decides the counts and the traffic.
//
// Objects in the cubestore schema (SC2 owns /nodes,/leases,/tokens; SC3 /assignments,/status/cells;
// SC4 /apps,/pending; SC5 /endpoints; SC6 /expose,/lb; SC7 /svcspec,/services; SC8 /volumes):
//
//   /rollouts/<app>          — the rollout state machine record (this file). Written by the leader
//                              rollout controller; read by `sctl rollout status`.
//   /schedrev/<app>/<rev>    — DESIRED: a per-revision DeploymentSpec (the scheduler's input during
//                              a rollout). The controller owns these; when none exist for an app the
//                              scheduler falls back to /apps/<app>/spec (the SC4 direct path).
//   /history/<app>/<rev>     — a snapshot of each revision's DeploymentSpec, kept for `rollout undo`
//                              and to keep the draining old revision running.
//   /traffic/<app>           — the per-revision traffic weights the rollout admits (the blue-green
//                              switch / canary ramp). The LB/endpoints consumption is the wiring
//                              seam surfaced in FORMAT.md (the nginx weight gap).
//
// Foundation-free; little-endian ByteIO, like every other cubestore record.

// MARK: - Key schema

enum RolloutKeys {
    static let rolloutsPrefix: Bytes = Array("/rollouts/".utf8)
    static let historyPrefix:  Bytes = Array("/history/".utf8)
    static let trafficPrefix:  Bytes = Array("/traffic/".utf8)
    // The per-revision scheduler input (`/schedrev/<app>/<rev>`) is a scheduler-layer contract —
    // see `SchedulerKeys.schedRev` in Deployment.swift; the controller writes it there.

    static func rollout(_ app: String) -> Bytes { rolloutsPrefix + Array(app.utf8) }
    static func traffic(_ app: String) -> Bytes { trafficPrefix + Array(app.utf8) }
    static func history(app: String, rev: UInt64) -> Bytes {
        historyPrefix + Array(app.utf8) + Array("/".utf8) + Array("\(rev)".utf8)
    }

    static func appOfRolloutKey(_ key: Bytes) -> String? {
        guard key.count > rolloutsPrefix.count else { return nil }
        for i in 0..<rolloutsPrefix.count where key[i] != rolloutsPrefix[i] { return nil }
        return String(decoding: key[rolloutsPrefix.count...], as: UTF8.self)
    }
}

// MARK: - Phase

/// The rollout lifecycle (design §8). `progressing` while stepping toward the target; `complete`
/// once new=N and old=0 ready; `rollingBack` while reverting after a deadline trip; `failed` once
/// reverted (the service kept serving on the old revision throughout).
enum RolloutPhase: UInt8, Equatable {
    case progressing = 0
    case complete    = 1
    case failed      = 2
    case rollingBack = 3

    var name: String {
        switch self {
        case .progressing: return "Progressing"
        case .complete:    return "Complete"
        case .failed:      return "Failed"
        case .rollingBack: return "RollingBack"
        }
    }
}

// MARK: - Per-revision desired + traffic

/// The controller's desired replica count for one revision (the value written to /schedrev).
struct RevisionDesired: Equatable {
    var revision: UInt64
    var desired: UInt32
}

/// The traffic weight (0–100) the rollout admits for one revision. A revision with weight 0 is out
/// of rotation; the endpoints/LB serve only weighted revisions (blue-green = one at 100; canary =
/// the split; rolling = every in-rotation revision at its share).
struct TrafficShare: Equatable {
    var revision: UInt64
    var weight: UInt32
}

// MARK: - RolloutRecord (the value at /rollouts/<app>)

struct RolloutRecord: Equatable {
    var app: String
    var strategy: RolloutStrategy
    var targetRevision: UInt64
    var replicas: UInt32                 // N — the desired count at the target
    var maxSurge: UInt32
    var maxUnavailable: UInt32
    var canarySteps: [UInt32]            // canary percent ramp, last == 100
    var canaryIndex: UInt32              // current canary step
    var progressDeadlineSeconds: UInt32
    var startedAtSeconds: UInt64         // when the current target's rollout began (deadline base)
    var phase: RolloutPhase
    var revisions: [RevisionDesired]     // per-revision desired counts (≤ 2 during a transition)
    var weights: [TrafficShare]          // current admitted traffic split
    var blueGreenSwitched: Bool          // blue-green: has traffic flipped to the new revision yet
    var failedRevision: UInt64           // a revision whose rollout failed; not auto-retried (0 = none)
    var history: [UInt64]                // target revisions oldest→newest (for `rollout undo`)
    var message: String

    func desired(_ rev: UInt64) -> UInt32 {
        for r in revisions where r.revision == rev { return r.desired }
        return 0
    }
    func weight(_ rev: UInt64) -> UInt32 {
        for w in weights where w.revision == rev { return w.weight }
        return 0
    }

    func encode() -> Bytes {
        var w = ByteWriter()
        w.u8(1)
        w.blob(Array(app.utf8))
        w.u8(strategy.rawValue)
        w.u64(targetRevision)
        w.u32(replicas)
        w.u32(maxSurge)
        w.u32(maxUnavailable)
        w.u32(UInt32(canarySteps.count)); for s in canarySteps { w.u32(s) }
        w.u32(canaryIndex)
        w.u32(progressDeadlineSeconds)
        w.u64(startedAtSeconds)
        w.u8(phase.rawValue)
        w.u32(UInt32(revisions.count)); for r in revisions { w.u64(r.revision); w.u32(r.desired) }
        w.u32(UInt32(weights.count)); for t in weights { w.u64(t.revision); w.u32(t.weight) }
        w.u8(blueGreenSwitched ? 1 : 0)
        w.u64(failedRevision)
        w.u32(UInt32(history.count)); for h in history { w.u64(h) }
        w.blob(Array(message.utf8))
        return w.bytes
    }

    static func decode(_ bytes: Bytes) -> RolloutRecord? {
        var r = ByteReader(bytes)
        guard let ver = r.u8(), ver == 1, let appB = r.blob(), let sB = r.u8(),
              let strat = RolloutStrategy(rawValue: sB), let tRev = r.u64(), let reps = r.u32(),
              let surge = r.u32(), let unavail = r.u32(), let nSteps = r.u32() else { return nil }
        var steps: [UInt32] = []; var i: UInt32 = 0
        while i < nSteps { guard let s = r.u32() else { return nil }; steps.append(s); i += 1 }
        guard let cIdx = r.u32(), let deadline = r.u32(), let started = r.u64(),
              let pB = r.u8(), let phase = RolloutPhase(rawValue: pB), let nRev = r.u32() else { return nil }
        var revs: [RevisionDesired] = []; i = 0
        while i < nRev { guard let rv = r.u64(), let d = r.u32() else { return nil }; revs.append(RevisionDesired(revision: rv, desired: d)); i += 1 }
        guard let nW = r.u32() else { return nil }
        var ws: [TrafficShare] = []; i = 0
        while i < nW { guard let rv = r.u64(), let wt = r.u32() else { return nil }; ws.append(TrafficShare(revision: rv, weight: wt)); i += 1 }
        guard let switchedB = r.u8(), let failed = r.u64(), let nH = r.u32() else { return nil }
        var hist: [UInt64] = []; i = 0
        while i < nH { guard let h = r.u64() else { return nil }; hist.append(h); i += 1 }
        guard let msgB = r.blob() else { return nil }
        return RolloutRecord(app: String(decoding: appB, as: UTF8.self), strategy: strat,
                             targetRevision: tRev, replicas: reps, maxSurge: surge, maxUnavailable: unavail,
                             canarySteps: steps, canaryIndex: cIdx, progressDeadlineSeconds: deadline,
                             startedAtSeconds: started, phase: phase, revisions: revs, weights: ws,
                             blueGreenSwitched: switchedB != 0, failedRevision: failed, history: hist,
                             message: String(decoding: msgB, as: UTF8.self))
    }
}

// MARK: - TrafficPolicy (the value at /traffic/<app>)

/// The admitted traffic split the LB/endpoints consume. Mirrors the rollout's `weights` so the
/// data plane has a single object to read without decoding the whole rollout record.
struct TrafficPolicy: Equatable {
    var service: String
    var shares: [TrafficShare]

    func encode() -> Bytes {
        var w = ByteWriter()
        w.u8(1); w.blob(Array(service.utf8))
        w.u32(UInt32(shares.count)); for s in shares { w.u64(s.revision); w.u32(s.weight) }
        return w.bytes
    }
    static func decode(_ bytes: Bytes) -> TrafficPolicy? {
        var r = ByteReader(bytes)
        guard let ver = r.u8(), ver == 1, let svcB = r.blob(), let n = r.u32() else { return nil }
        var shares: [TrafficShare] = []; var i: UInt32 = 0
        while i < n { guard let rv = r.u64(), let wt = r.u32() else { return nil }; shares.append(TrafficShare(revision: rv, weight: wt)); i += 1 }
        return TrafficPolicy(service: String(decoding: svcB, as: UTF8.self), shares: shares)
    }
}

// MARK: - Observed readiness (the controller's input)

/// Observed Cell counts for one revision (distilled from /status/cells by the controller, or set
/// by the simulated cluster in host tests). `ready` is the SC5 readiness gate count.
struct RevisionObservation: Equatable {
    var revision: UInt64
    var running: UInt32
    var ready: UInt32
}

extension Array where Element == RevisionObservation {
    func ready(_ rev: UInt64) -> UInt32 { for o in self where o.revision == rev { return o.ready }; return 0 }
    func running(_ rev: UInt64) -> UInt32 { for o in self where o.revision == rev { return o.running }; return 0 }
}
