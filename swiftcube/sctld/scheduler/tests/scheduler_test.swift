// SPDX-License-Identifier: Apache-2.0
// scheduler_test.swift — SC4 host acceptance for the spread+fit scheduler (cases 1–10).
//
// Drives the leader-gated reconcile loop and the pure schedule() function against an
// in-process cubestore with an injected clock — no kernel, no transport, no wall clock,
// fully deterministic. Nodes are made "healthy" by granting a lease (SC2) and "down" by
// deleting that lease; Deployments and node capacity/labels are written straight into the
// store. Foundation is used only by the harness (printing/exit).
//
// Cases (per the SC4 ladder):
//   1  replicas=3, 3 healthy nodes → 3 Assignments, one per node (spread)
//   2  fit: a node too small for the request is never chosen
//   3  nodeSelector: replicas land only on label-matching nodes
//   4  scale up 3→5 → 2 new Assignments; the original 3 are untouched (no churn)
//   5  scale down 5→2 → 3 removed; the victims are the most-loaded node
//   6  node down: a lease expires → its Assignments vanish → replicas re-placed on survivors
//   7  transient crash (node alive): no reschedule, no Assignment churn
//   8  leader-only: a follower writes nothing; only the leader produces Assignments
//   9  determinism: schedule() called directly twice → identical placement
//  10  pending: an unplaceable replica is marked pending with a reason, then placed when
//      a fitting node joins

import Foundation

let startUnix: UInt64 = 1_700_000_000

@main struct SchedulerTest {
    static var failed = false
    static func check(_ cond: Bool, _ msg: String) {
        if !cond { FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8)); failed = true }
    }

    static func main() {
        case1_spread()
        case2_fit()
        case3_nodeSelector()
        case4_scaleUp()
        case5_scaleDown()
        case6_nodeDownReschedule()
        case7_transientCrashNoChurn()
        case8_leaderOnly()
        case9_determinism()
        case10_pending()

        if failed { FileHandle.standardError.write(Data("scheduler-test: FAILED\n".utf8)); exit(1) }
        print("scheduler-test: all SC4 cases (1–10) passed")
    }

    // MARK: - Fixture

    final class Fixture {
        let store = openRamCubeStore()
        let clock = ManualClock(startUnix)
        let leases: LeaseManager<RamLog, RamSnapshot>
        init() { leases = LeaseManager(store: store, clock: clock) }

        /// A healthy node: grant its lease (attaching the node key, as SC2 does) and
        /// write its capacity + labels.
        func addNode(_ id: String, cpu: UInt32, mem: UInt64, labels: [String] = [], ttl: UInt64 = 3600) {
            leases.grant(id: id, ttlSeconds: ttl, attachedKeys: [CubeKeys.node(id)])
            let n = NodeRecord(id: id, status: .ready, leaseId: id, address: "10.0.0.1:9",
                               registeredRev: store.revision,
                               capacityCpuMillis: cpu, capacityMemBytes: mem, labels: labels)
            _ = store.apply([.put(key: CubeKeys.node(id), value: n.encode())])
        }

        /// Take a node down the way the reaper would: drop its lease (and node key).
        func killNode(_ id: String) {
            _ = store.apply([.delete(key: CubeKeys.lease(id)), .delete(key: CubeKeys.node(id))])
        }

        func putDeployment(_ d: DeploymentSpec) {
            _ = store.apply([.put(key: SchedulerKeys.appSpec(d.app), value: d.encode())])
        }
        func putStatus(_ st: CellStatusRecord) {
            _ = store.apply([.put(key: SletKeys.status(st.cellId), value: st.encode())])
        }

        func loop(isLeader: Bool = true) -> SchedulerLoop<RamLog, RamSnapshot> {
            SchedulerLoop(store: store, clock: clock, isLeader: isLeader)
        }

        // Inspection helpers.
        func assignments() -> [(node: String, cellId: String, rev: Revision, asg: Assignment)] {
            var out: [(String, String, Revision, Assignment)] = []
            for e in store.prefix(SletKeys.assignmentsPrefix) {
                guard let p = SchedulerKeys.parseAssignmentKey(e.key), let a = Assignment.decode(e.value) else { continue }
                out.append((p.node, p.cellId, e.modRevision, a))
            }
            return out
        }
        func countOnNode(_ node: String) -> Int { assignments().filter { $0.node == node }.count }
        func pendings() -> [PendingRecord] {
            store.prefix(SchedulerKeys.pendingPrefix).compactMap { PendingRecord.decode($0.value) }
        }
    }

    // MARK: - Builders

    static func req(_ cpu: UInt32, _ mem: UInt64) -> ResourceLimits { ResourceLimits(cpuMillis: cpu, memBytes: mem) }

    static func template(_ request: ResourceLimits) -> CellTemplate {
        CellTemplate(image: ImageRef(digest: [UInt8](repeating: 7, count: 32),
                                     signature: [UInt8](repeating: 9, count: 64)),
                     capabilities: ["net.listen:8080"], resources: request, namespaceRoot: "/",
                     args: ["/bin/app"], env: ["LOG_LEVEL=info"], tmpfsScratch: true,
                     volume: nil, restartPolicy: .always)
    }

    static func dep(_ app: String, replicas: UInt32, request: ResourceLimits,
                    selector: [String] = [], pin: String = "", rev: UInt64 = 1) -> DeploymentSpec {
        DeploymentSpec(app: app, replicas: replicas, revision: rev, request: request,
                       nodeSelector: selector, pinHint: pin, template: template(request))
    }

    // MARK: - Case 1: spread

    static func case1_spread() {
        let f = Fixture()
        f.addNode("n1", cpu: 1000, mem: 1 << 30)
        f.addNode("n2", cpu: 1000, mem: 1 << 30)
        f.addNode("n3", cpu: 1000, mem: 1 << 30)
        f.putDeployment(dep("web", replicas: 3, request: req(100, 64 << 20)))
        f.loop().step()

        let a = f.assignments()
        check(a.count == 3, "1: 3 assignments (got \(a.count))")
        check(f.countOnNode("n1") == 1 && f.countOnNode("n2") == 1 && f.countOnNode("n3") == 1,
              "1: exactly one replica per node (spread)")
    }

    // MARK: - Case 2: fit

    static func case2_fit() {
        let f = Fixture()
        f.addNode("big1", cpu: 1000, mem: 1 << 30)
        f.addNode("big2", cpu: 1000, mem: 1 << 30)
        f.addNode("tiny", cpu: 1000, mem: 8 << 20)        // mem below the request
        f.putDeployment(dep("web", replicas: 2, request: req(100, 64 << 20)))
        f.loop().step()

        check(f.assignments().count == 2, "2: 2 assignments placed")
        check(f.countOnNode("tiny") == 0, "2: the too-small node is never chosen")
        check(f.countOnNode("big1") == 1 && f.countOnNode("big2") == 1, "2: replicas land on fitting nodes")
    }

    // MARK: - Case 3: nodeSelector

    static func case3_nodeSelector() {
        let f = Fixture()
        f.addNode("eu1", cpu: 1000, mem: 1 << 30, labels: ["zone=eu"])
        f.addNode("eu2", cpu: 1000, mem: 1 << 30, labels: ["zone=eu"])
        f.addNode("us1", cpu: 1000, mem: 1 << 30, labels: ["zone=us"])
        f.putDeployment(dep("web", replicas: 2, request: req(100, 64 << 20), selector: ["zone=eu"]))
        f.loop().step()

        check(f.assignments().count == 2, "3: 2 assignments placed")
        check(f.countOnNode("us1") == 0, "3: the non-matching node is never chosen")
        check(f.countOnNode("eu1") == 1 && f.countOnNode("eu2") == 1, "3: replicas land on label-matching nodes")
    }

    // MARK: - Case 4: scale up (no churn on the originals)

    static func case4_scaleUp() {
        let f = Fixture()
        f.addNode("n1", cpu: 1000, mem: 1 << 30)
        f.addNode("n2", cpu: 1000, mem: 1 << 30)
        f.addNode("n3", cpu: 1000, mem: 1 << 30)
        f.putDeployment(dep("web", replicas: 3, request: req(100, 64 << 20)))
        let lp = f.loop()
        lp.step()
        let before = Set(f.assignments().map { $0.cellId })
        check(before.count == 3, "4: 3 before scale-up")

        f.putDeployment(dep("web", replicas: 5, request: req(100, 64 << 20)))
        lp.step()
        let after = f.assignments()
        let afterIds = Set(after.map { $0.cellId })
        check(after.count == 5, "4: 5 after scale-up (got \(after.count))")
        check(before.isSubset(of: afterIds), "4: the original 3 replicas are untouched (no churn)")
        let added = afterIds.subtracting(before)
        check(added.count == 2, "4: exactly 2 new Assignments")
        // Best spread over 3 nodes = 2,2,1.
        let counts = [f.countOnNode("n1"), f.countOnNode("n2"), f.countOnNode("n3")].sorted()
        check(counts == [1, 2, 2], "4: 5 replicas spread 2/2/1 (got \(counts))")
    }

    // MARK: - Case 5: scale down (victims are the most-loaded node)

    static func case5_scaleDown() {
        let f = Fixture()
        // Two equal nodes: the deterministic 5-replica spread is n1=3, n2=2.
        f.addNode("n1", cpu: 10000, mem: 8 << 30)
        f.addNode("n2", cpu: 10000, mem: 8 << 30)
        f.putDeployment(dep("web", replicas: 5, request: req(100, 64 << 20)))
        let lp = f.loop()
        lp.step()
        check(f.countOnNode("n1") == 3 && f.countOnNode("n2") == 2, "5: pre-state 3/2 (got \(f.countOnNode("n1"))/\(f.countOnNode("n2")))")

        f.putDeployment(dep("web", replicas: 2, request: req(100, 64 << 20)))
        lp.step()
        check(f.assignments().count == 2, "5: 3 Assignments removed → 2 remain (got \(f.assignments().count))")
        check(f.countOnNode("n1") == 0, "5: the most-loaded node (n1) is fully evicted")
        check(f.countOnNode("n2") == 2, "5: survivors are on the least-loaded node (n2)")
    }

    // MARK: - Case 6: node down → reschedule onto survivors

    static func case6_nodeDownReschedule() {
        let f = Fixture()
        f.addNode("n1", cpu: 1000, mem: 1 << 30)
        f.addNode("n2", cpu: 1000, mem: 1 << 30)
        f.addNode("n3", cpu: 1000, mem: 1 << 30)
        f.putDeployment(dep("web", replicas: 3, request: req(100, 64 << 20)))
        let lp = f.loop()
        lp.step()
        check(f.countOnNode("n3") == 1, "6: n3 holds a replica before it dies")

        f.killNode("n3")                 // lease expires → node gone
        lp.step()

        let a = f.assignments()
        check(a.count == 3, "6: total healthy replicas converge back to 3 (got \(a.count))")
        check(f.countOnNode("n3") == 0, "6: n3's stranded Assignment is deleted")
        check(f.countOnNode("n1") + f.countOnNode("n2") == 3, "6: all 3 replicas now on survivors n1+n2")
    }

    // MARK: - Case 7: transient crash on a live node → no reschedule, no churn

    static func case7_transientCrashNoChurn() {
        let f = Fixture()
        f.addNode("n1", cpu: 1000, mem: 1 << 30)
        f.addNode("n2", cpu: 1000, mem: 1 << 30)
        f.addNode("n3", cpu: 1000, mem: 1 << 30)
        f.putDeployment(dep("web", replicas: 3, request: req(100, 64 << 20)))
        let lp = f.loop()
        lp.step()
        let before = f.assignments().map { (id: $0.cellId, rev: $0.rev) }.sorted { $0.id < $1.id }

        // A transient crash: slet reports a non-terminal phase (dead/restarting), NOT
        // .failed. The node stays alive. The scheduler must not touch the Assignment —
        // local restart is slet's job (SC3).
        let victim = before[0].id
        let vnode = f.assignments().first { $0.cellId == victim }!.node
        f.putStatus(CellStatusRecord(cellId: victim, node: vnode, phase: .dead(exitCode: 1),
                                     ready: false, restartCount: 1,
                                     imageDigest: [UInt8](repeating: 7, count: 32),
                                     startedAtSeconds: startUnix, message: "crashed; restarting"))
        lp.step()

        let after = f.assignments().map { (id: $0.cellId, rev: $0.rev) }.sorted { $0.id < $1.id }
        check(before.map { $0.id } == after.map { $0.id }, "7: no Assignment added or removed")
        // Unchanged values mean the loop wrote nothing — modRevisions are stable.
        check(before.map { $0.rev } == after.map { $0.rev }, "7: no churn (Assignments not rewritten)")
    }

    // MARK: - Case 8: leader-only

    static func case8_leaderOnly() {
        let f = Fixture()
        f.addNode("n1", cpu: 1000, mem: 1 << 30)
        f.addNode("n2", cpu: 1000, mem: 1 << 30)
        f.putDeployment(dep("web", replicas: 2, request: req(100, 64 << 20)))

        let follower = f.loop(isLeader: false)
        let leader = f.loop(isLeader: true)

        follower.step()
        check(f.assignments().isEmpty, "8: a follower writes no Assignments")

        leader.step()
        check(f.assignments().count == 2, "8: only the leader produces Assignments")

        follower.step()   // still a no-op; must not duplicate or conflict
        check(f.assignments().count == 2, "8: follower never duplicates the leader's Assignments")
    }

    // MARK: - Case 9: determinism (pure function called directly)

    static func case9_determinism() {
        let nodes = [
            NodeView(id: "a", healthy: true, capacity: req(1000, 1 << 30), labels: []),
            NodeView(id: "b", healthy: true, capacity: req(1000, 1 << 30), labels: []),
            NodeView(id: "c", healthy: true, capacity: req(1000, 1 << 30), labels: []),
        ]
        let d = dep("web", replicas: 3, request: req(100, 64 << 20))
        let r1 = schedule(deployments: [d], nodes: nodes, placements: [])
        let r2 = schedule(deployments: [d], nodes: nodes, placements: [])
        check(r1 == r2, "9: same inputs ⇒ identical ScheduleResult")
        // The placement is fully predictable: one replica per node, slots 0/1/2.
        let placed = Set(r1.desired.map { "\($0.node):\($0.cellId)" })
        check(placed == ["a:web--r1-s0-g1", "b:web--r1-s1-g1", "c:web--r1-s2-g1"],
              "9: deterministic node/slot/cellId assignment")
        check(r1.pending.isEmpty, "9: nothing pending")
    }

    // MARK: - Case 10: pending then placed when a fitting node joins

    static func case10_pending() {
        let f = Fixture()
        // One node with room for exactly one replica; replicas=2 ⇒ slot 1 cannot fit.
        f.addNode("n1", cpu: 100, mem: 64 << 20)
        f.putDeployment(dep("web", replicas: 2, request: req(100, 64 << 20)))
        let lp = f.loop()
        lp.step()

        check(f.assignments().count == 1, "10: one replica placed, one cannot fit")
        let pend = f.pendings()
        check(pend.count == 1 && pend[0].app == "web" && pend[0].slot == 1,
              "10: the unplaceable replica is marked pending (not dropped)")
        check(pend.first?.reason.contains("capacity") == true, "10: pending carries an actionable reason")

        // A fitting node joins → the pending replica is placed and the marker cleared.
        f.addNode("n2", cpu: 1000, mem: 1 << 30)
        lp.step()
        check(f.assignments().count == 2, "10: pending replica placed when capacity appears")
        check(f.countOnNode("n2") == 1, "10: it landed on the new node")
        check(f.pendings().isEmpty, "10: the pending marker is cleared")
    }
}
