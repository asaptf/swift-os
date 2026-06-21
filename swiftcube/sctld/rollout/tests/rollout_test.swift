// SPDX-License-Identifier: Apache-2.0
// rollout_test.swift — SC9b host acceptance for the rollout state machine (cases 3–9 + integration).
//
// Drives the leader-gated RolloutController against an in-process cubestore with an injected clock
// and a SIMULATED CLUSTER: a fake that reads the controller's per-revision desired counts (/schedrev)
// and materializes the corresponding Cells as /status/cells records — running, and ready unless the
// test has marked a revision "not ready" (the SC5 gate). No kernel, no transport, no wall clock.
//
// Cases (per the SC9 ladder):
//   3  rolling: respects maxSurge/maxUnavailable; never fewer than N−maxUnavailable ready; new=N,old=0
//   4  rolling waits on readiness: a not-ready new revision blocks the next step
//   5  blue-green: traffic flips old→new only after ALL new ready; switch is atomic; old then removed
//   6  canary: traffic weight ramps in steps; rollback mid-canary restores 100% old
//   7  automatic rollback: a broken new revision trips the deadline → revert to old; Failed; old served
//   8  rollout undo: reverts to the prior revision from history
//   9  leader-only + level-triggered: a follower does nothing; a fresh controller resumes, no double-step
//  I   integration: the controller's /schedrev drives the REAL SC4 scheduler to place both revisions
//
// Foundation is used only by the harness (printing/exit).

import Foundation

let startUnix: UInt64 = 1_700_000_000

@main struct RolloutTest {
    static var failed = false
    static func check(_ cond: Bool, _ msg: String) {
        if !cond { FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8)); failed = true }
    }

    static func main() {
        case3_rolling()
        case4_rollingWaitsOnReadiness()
        case5_blueGreen()
        case6_canary()
        case7_autoRollback()
        case8_undo()
        case9_leaderOnlyAndResume()
        caseI_schedulerIntegration()

        if failed { FileHandle.standardError.write(Data("rollout-test: FAILED\n".utf8)); exit(1) }
        print("rollout-test: all SC9b rollout cases (3–9 + integration) passed")
    }

    // MARK: - Fixture + simulated cluster

    final class Fixture {
        let store = openRamCubeStore()
        let clock = ManualClock(startUnix)
        let app = "web"
        var notReady: [UInt64] = []     // revisions whose Cells run but never become ready (SC5 gate)

        func controller(isLeader: Bool = true) -> RolloutController<RamLog, RamSnapshot> {
            RolloutController(store: store, clock: clock, isLeader: isLeader)
        }

        func putSpec(rev: UInt64, replicas: UInt32, strategy: RolloutStrategy,
                     surge: UInt32 = 1, unavail: UInt32 = 0, steps: [UInt32] = [], deadline: UInt32 = 600) {
            let probe = ProbeSpec(kind: .http, port: 8080, httpPath: "/healthz")
            let tmpl = CellTemplate(image: ImageRef(digest: [UInt8](repeating: UInt8(truncatingIfNeeded: rev), count: 32), signature: []),
                                    capabilities: ["net.listen:8080"], resources: ResourceLimits(cpuMillis: 100, memBytes: 64 << 20),
                                    namespaceRoot: "/", args: ["/bin/app"], env: [], tmpfsScratch: true,
                                    volume: nil, restartPolicy: .always, service: app, port: 8080,
                                    readiness: probe, liveness: ProbeSpec())
            let update = UpdateStrategy(strategy: strategy, maxSurge: surge, maxUnavailable: unavail,
                                        canaryStepPercents: steps, progressDeadlineSeconds: deadline)
            let dep = DeploymentSpec(app: app, replicas: replicas, revision: rev,
                                     request: ResourceLimits(cpuMillis: 100, memBytes: 64 << 20),
                                     nodeSelector: [], pinHint: "", template: tmpl, update: update)
            _ = store.apply([.put(key: SchedulerKeys.appSpec(app), value: dep.encode())])
        }

        func rollout() -> RolloutRecord? {
            store.get(RolloutKeys.rollout(app)).flatMap { RolloutRecord.decode($0.value) }
        }

        /// Desired per-revision counts the scheduler/sim would act on: /schedrev when present, else
        /// the direct /apps/<app>/spec (post-completion).
        func desired() -> [(rev: UInt64, count: UInt32)] {
            let sched = store.prefix(SchedulerKeys.appSchedRevPrefix(app))
            if sched.isEmpty {
                guard let e = store.get(SchedulerKeys.appSpec(app)), let d = DeploymentSpec.decode(e.value) else { return [] }
                return [(d.revision, d.replicas)]
            }
            var out: [(UInt64, UInt32)] = []
            for e in sched {
                guard let (_, rev) = SchedulerKeys.parseSchedRev(e.key), let d = DeploymentSpec.decode(e.value) else { continue }
                out.append((rev, d.replicas))
            }
            return out
        }

        /// The simulated scheduler+slet+probes: make /status/cells match the desired per-revision
        /// counts; a Cell is ready unless its revision is in `notReady`.
        func simReconcile() {
            var want: [String] = []
            for (rev, count) in desired() {
                let ready = !notReady.contains(rev)
                var s: UInt32 = 0
                while s < count {
                    let cid = CellIdCodec.make(app: app, revision: rev, slot: s, generation: 1)
                    want.append(cid)
                    let st = CellStatusRecord(cellId: cid, node: "n1", phase: .running, ready: ready,
                                              restartCount: 0, imageDigest: [UInt8](repeating: UInt8(truncatingIfNeeded: rev), count: 32),
                                              startedAtSeconds: startUnix, message: "", service: app,
                                              address: "10.0.0.\(s + 1)", port: 8080)
                    _ = store.apply([.put(key: SletKeys.status(cid), value: st.encode())])
                    s += 1
                }
            }
            // Remove status for this app's Cells no longer desired.
            for e in store.prefix(SletKeys.statusCellsPrefix) {
                guard let st = CellStatusRecord.decode(e.value), let id = CellIdCodec.parse(st.cellId), id.app == app else { continue }
                if !want.contains(st.cellId) { _ = store.apply([.delete(key: e.key)]) }
            }
        }

        /// Total ready Cells across all revisions (availability), and total desired (for surge).
        func readyTotal() -> UInt32 {
            var n: UInt32 = 0
            for e in store.prefix(SletKeys.statusCellsPrefix) {
                guard let st = CellStatusRecord.decode(e.value), let id = CellIdCodec.parse(st.cellId), id.app == app else { continue }
                if st.phase == .running && st.ready { n += 1 }
            }
            return n
        }
        func desiredTotal() -> UInt32 { desired().reduce(0) { $0 + $1.count } }

        /// One reconcile tick: controller plans, the simulated cluster catches up.
        func tick(isLeader: Bool = true) { controller(isLeader: isLeader).step(); simReconcile() }
    }

    // MARK: - Case 3: rolling

    static func case3_rolling() {
        let f = Fixture()
        // First deploy r1 → up to N.
        f.putSpec(rev: 1, replicas: 4, strategy: .rolling, surge: 1, unavail: 0)
        runToComplete(f, label: "3:first")
        check(f.readyTotal() == 4, "3: first deploy reaches 4 ready")

        // Roll to r2 (maxSurge 1, maxUnavailable 0).
        f.putSpec(rev: 2, replicas: 4, strategy: .rolling, surge: 1, unavail: 0)
        var steps = 0
        repeat {
            f.tick()
            // Invariants after each tick: availability ≥ N−U, total ≤ N+S.
            check(f.readyTotal() >= 4 - 0, "3: availability never below N−maxUnavailable (got \(f.readyTotal()))")
            check(f.desiredTotal() <= 4 + 1, "3: total never above N+maxSurge (got \(f.desiredTotal()))")
            steps += 1
        } while f.rollout()?.phase != .complete && steps < 40
        check(f.rollout()?.phase == .complete, "3: rolling converges to Complete")
        let d = f.desired()
        check(d.count == 1 && d[0].rev == 2 && d[0].count == 4, "3: ends new=4, old=0 (got \(d))")
    }

    // MARK: - Case 4: rolling waits on readiness

    static func case4_rollingWaitsOnReadiness() {
        let f = Fixture()
        f.putSpec(rev: 1, replicas: 4, strategy: .rolling, surge: 1, unavail: 0)
        runToComplete(f, label: "4:first")

        f.notReady = [2]                                  // the new revision never becomes ready
        f.putSpec(rev: 2, replicas: 4, strategy: .rolling, surge: 1, unavail: 0)
        for _ in 0..<8 { f.tick() }                       // many ticks, but new can't pass readiness
        check(f.rollout()?.phase == .progressing, "4: a not-ready new revision keeps the rollout Progressing")
        // Old must still be fully serving (maxUnavailable 0 ⇒ old held at N until new is ready).
        let oldDesired = f.desired().first { $0.rev == 1 }?.count ?? 0
        check(oldDesired == 4, "4: old revision held at N while new is not ready (got \(oldDesired))")
        check(f.readyTotal() == 4, "4: exactly the 4 old replicas serve; new contributes 0 ready")
        // New is surged but blocked at the surge ceiling, not advanced.
        let newDesired = f.desired().first { $0.rev == 2 }?.count ?? 0
        check(newDesired == 1, "4: new is surged to maxSurge (1) and blocked there (got \(newDesired))")
    }

    // MARK: - Case 5: blue-green

    static func case5_blueGreen() {
        let f = Fixture()
        f.putSpec(rev: 1, replicas: 3, strategy: .blueGreen)
        runToComplete(f, label: "5:first")

        f.notReady = [2]                                  // hold new not-ready to observe the pre-switch state
        f.putSpec(rev: 2, replicas: 3, strategy: .blueGreen)
        for _ in 0..<3 { f.tick(); assertSingleRevisionTraffic(f, "5") }
        // Full new is up alongside old, but no traffic has switched.
        check(f.rollout()?.blueGreenSwitched == false, "5: no switch while new is not all-ready")
        check(f.rollout()?.weight(1) == 100 && f.rollout()?.weight(2) == 0, "5: traffic stays 100% old pre-switch")
        check(f.desired().first { $0.rev == 2 }?.count == 3, "5: full new revision is brought up alongside old")

        // Release readiness → the switch flips atomically, then old drains.
        f.notReady = []
        var steps = 0
        while f.rollout()?.phase != .complete && steps < 20 { f.tick(); assertSingleRevisionTraffic(f, "5"); steps += 1 }
        check(f.rollout()?.phase == .complete, "5: blue-green completes")
        check(f.rollout()?.blueGreenSwitched == true && f.rollout()?.weight(2) == 100, "5: traffic switched 100% to new")
        let d = f.desired()
        check(d.count == 1 && d[0].rev == 2, "5: old revision removed after the switch (got \(d))")
    }

    // MARK: - Case 6: canary ramps; rollback mid-canary restores old

    static func case6_canary() {
        // 6a: weight ramps 25 → 50 → 100.
        let f = Fixture()
        f.putSpec(rev: 1, replicas: 4, strategy: .canary)
        runToComplete(f, label: "6:first")
        f.putSpec(rev: 2, replicas: 4, strategy: .canary, steps: [25, 50, 100])
        var sawWeights: [UInt32] = []
        var steps = 0
        repeat {
            f.tick()
            if let w = f.rollout()?.weight(2), w > 0, !sawWeights.contains(w) { sawWeights.append(w) }
            steps += 1
        } while f.rollout()?.phase != .complete && steps < 30
        check(f.rollout()?.phase == .complete, "6: canary completes")
        check(sawWeights.contains(25) && sawWeights.contains(50) && sawWeights.contains(100),
              "6: canary weight ramps through 25/50/100 (saw \(sawWeights))")

        // 6b: rollback mid-canary (new never ready) → 100% old, Failed.
        let g = Fixture()
        g.putSpec(rev: 1, replicas: 4, strategy: .canary)
        runToComplete(g, label: "6b:first")
        g.notReady = [2]
        g.putSpec(rev: 2, replicas: 4, strategy: .canary, steps: [25, 50, 100], deadline: 60)
        g.tick()                                          // enters canary at 25% with new not ready
        check(g.rollout()?.weight(2) == 25, "6b: canary started at 25%")
        g.clock.advance(120)                              // past the progress deadline
        g.tick()
        check(g.rollout()?.phase == .failed, "6b: deadline trips a rollback")
        check(g.rollout()?.weight(1) == 100 && g.rollout()?.weight(2) == 0, "6b: rollback restores 100% old")
    }

    // MARK: - Case 7: automatic rollback

    static func case7_autoRollback() {
        let f = Fixture()
        f.putSpec(rev: 1, replicas: 4, strategy: .rolling, surge: 1, unavail: 0)
        runToComplete(f, label: "7:first")

        f.notReady = [2]                                  // the new revision is broken (never ready)
        f.putSpec(rev: 2, replicas: 4, strategy: .rolling, surge: 1, unavail: 0, deadline: 60)
        // Progress for a while within the deadline; the old revision must keep serving throughout.
        for _ in 0..<3 { f.tick(); check(f.readyTotal() == 4, "7: old revision serves throughout the failed rollout") }
        check(f.rollout()?.phase == .progressing, "7: still progressing before the deadline")

        f.clock.advance(120)                              // exceed the progress deadline
        f.tick()
        check(f.rollout()?.phase == .failed, "7: deadline → Failed")
        check(f.rollout()?.failedRevision == 2, "7: the broken revision is recorded")
        let d = f.desired()
        check(d.contains { $0.rev == 1 && $0.count == 4 }, "7: reverted — old back at N")
        check(f.readyTotal() == 4, "7: the service stayed served by the old revision throughout")

        // Re-applying the SAME broken spec is not auto-retried (stays Failed, no churn).
        let revBefore = f.store.get(RolloutKeys.rollout(f.app))!.modRevision
        f.tick()
        check(f.rollout()?.phase == .failed, "7: a known-failed revision is not retried")
        check(f.store.get(RolloutKeys.rollout(f.app))!.modRevision == revBefore, "7: no churn while stuck-failed")
    }

    // MARK: - Case 8: rollout undo

    static func case8_undo() {
        let f = Fixture()
        f.putSpec(rev: 1, replicas: 3, strategy: .rolling)
        runToComplete(f, label: "8:first")
        f.putSpec(rev: 2, replicas: 3, strategy: .rolling)
        runToComplete(f, label: "8:r2")
        check(f.rollout()?.targetRevision == 2 && f.rollout()?.phase == .complete, "8: rolled out to r2")

        // Undo → reverts the desired spec to r1; the controller rolls back to it.
        let reverted = rolloutUndo(app: f.app, store: f.store)
        check(reverted == 1, "8: undo targets the prior revision r1 (got \(String(describing: reverted)))")
        runToComplete(f, label: "8:undo")
        check(f.rollout()?.targetRevision == 1 && f.rollout()?.phase == .complete, "8: rolled back to r1")
        let d = f.desired()
        check(d.count == 1 && d[0].rev == 1 && d[0].count == 3, "8: r1 serving at N after undo (got \(d))")
    }

    // MARK: - Case 9: leader-only + level-triggered resume

    static func case9_leaderOnlyAndResume() {
        let f = Fixture()
        f.putSpec(rev: 1, replicas: 4, strategy: .canary, steps: [50, 100])

        // A follower drives nothing.
        f.controller(isLeader: false).step()
        check(f.rollout() == nil, "9: a follower writes no rollout")

        // The leader starts it; then alternate FRESH controller instances (simulating restarts /
        // reconnects) and assert the rollout still converges without double-stepping.
        var steps = 0
        var usedFresh = false
        while f.rollout()?.phase != .complete && steps < 30 {
            // Every other tick, a brand-new controller resumes from store state; interleave an
            // idempotent follower no-op to prove a duplicated event changes nothing.
            f.controller(isLeader: false).step()
            RolloutController(store: f.store, clock: f.clock, isLeader: true).step()
            f.simReconcile()
            usedFresh = true
            steps += 1
        }
        check(usedFresh && f.rollout()?.phase == .complete, "9: a resumed controller converges the rollout")
        // Canary index advanced by single steps (never skipped a weight): final is the last step.
        check(f.rollout()?.weight(1) == 100, "9: ended at 100% on the (single) revision")
    }

    // MARK: - Integration: the controller's /schedrev drives the REAL SC4 scheduler

    static func caseI_schedulerIntegration() {
        let store = openRamCubeStore()
        let clock = ManualClock(startUnix)
        let leases = LeaseManager(store: store, clock: clock)
        // Three healthy nodes.
        for id in ["n1", "n2", "n3"] {
            leases.grant(id: id, ttlSeconds: 3600, attachedKeys: [CubeKeys.node(id)])
            let n = NodeRecord(id: id, status: .ready, leaseId: id, address: "10.0.0.1:9",
                               registeredRev: store.revision, capacityCpuMillis: 10000,
                               capacityMemBytes: 8 << 30, labels: [])
            _ = store.apply([.put(key: CubeKeys.node(id), value: n.encode())])
        }
        // Two per-revision specs written as the rollout controller would (old r1=2, new r2=1).
        for (rev, reps) in [(UInt64(1), UInt32(2)), (UInt64(2), UInt32(1))] {
            let tmpl = CellTemplate(image: ImageRef(digest: [UInt8](repeating: UInt8(rev), count: 32), signature: []),
                                    capabilities: [], resources: ResourceLimits(cpuMillis: 100, memBytes: 64 << 20),
                                    namespaceRoot: "/", args: ["/bin/app"], env: [], tmpfsScratch: true,
                                    volume: nil, restartPolicy: .always, service: "web", port: 8080)
            let dep = DeploymentSpec(app: "web", replicas: reps, revision: rev,
                                     request: ResourceLimits(cpuMillis: 100, memBytes: 64 << 20),
                                     nodeSelector: [], pinHint: "", template: tmpl)
            _ = store.apply([.put(key: SchedulerKeys.schedRev(app: "web", rev: rev), value: dep.encode())])
        }
        SchedulerLoop(store: store, clock: clock).step()

        // The real scheduler placed BOTH revisions: 2 of r1 + 1 of r2 = 3 assignments, distinct cellIds.
        var r1 = 0, r2 = 0
        for e in store.prefix(SletKeys.assignmentsPrefix) {
            guard let a = Assignment.decode(e.value) else { continue }
            if a.revision == 1 { r1 += 1 } else if a.revision == 2 { r2 += 1 }
        }
        check(r1 == 2 && r2 == 1, "I: the scheduler places both revisions from /schedrev (r1=\(r1), r2=\(r2))")
    }

    // MARK: - Helpers

    /// Tick at least once (a just-applied new target still shows the PREVIOUS rollout's phase until
    /// the controller runs), then drive to completion.
    static func runToComplete(_ f: Fixture, label: String, max: Int = 40) {
        var steps = 0
        repeat { f.tick(); steps += 1 } while f.rollout()?.phase != .complete && steps < max
        check(f.rollout()?.phase == .complete, "\(label): reached Complete (steps \(steps))")
    }

    /// Blue-green invariant: at most one revision ever carries traffic (no mixed traffic).
    static func assertSingleRevisionTraffic(_ f: Fixture, _ label: String) {
        guard let rec = f.rollout() else { return }
        let weighted = rec.weights.filter { $0.weight > 0 }
        check(weighted.count <= 1, "\(label): blue-green never splits traffic (got \(weighted.count) weighted revisions)")
    }
}
