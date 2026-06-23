// SPDX-License-Identifier: Apache-2.0
// store_test.swift — host test for SC1b: cubestore as the Raft state machine.
//
// Compiled against the cubestore core + the Raft core + the deterministic
// simulator, then run with no arguments. Drives a 3-node cluster whose replicated
// state machine is cubestore (`CubeStateMachine`), exercising the SC1b acceptance
// cases:
//   2  — a write proposed to the leader commits and applies on all three; the
//        cubestore revision and keyspace are identical across nodes.
//   3  — talk-to-any: a write submitted to a follower is forwarded to the leader
//        and applied cluster-wide.
//   9  — compare-and-apply under Raft: a CAS proposed on any node yields the same
//        accept/reject on every node and the correct post-state.
//   10 — linearizable read: a ReadIndex read on the leader returns the latest
//        committed state, while the same read on a partitioned ex-leader does not
//        return stale committed data (it fails / would forward).
//
// The simulator continuously asserts the Raft safety properties (now with
// cubestore state digests as the cross-node equality check), so any divergence
// fails the run even if a case's own checks pass.

import Foundation

@main
struct StoreTest {
    static var failed = false

    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failed = true
        }
    }

    static func b(_ s: String) -> Bytes { Array(s.utf8) }
    static func cube(_ r: Replica) -> CubeStateMachine { r.sm as! CubeStateMachine }
    static func enc(_ conds: [Cond] = [], _ ops: [Op]) -> Bytes {
        WriteRequestCodec.encode(WriteRequest(conditions: conds, ops: ops))
    }

    static func newCluster(_ members: [NodeId], _ seed: UInt64) -> Cluster {
        Cluster(members: members, seed: seed, makeSM: { CubeStateMachine() })
    }

    static func electLeader(_ c: Cluster, maxTicks: Int = 200) -> Replica? {
        _ = c.run(maxTicks: maxTicks, until: { c.leader() != nil })
        return c.leader()
    }

    /// Run until every up node's cubestore has reached at least `rev`.
    @discardableResult
    static func waitRevisionAll(_ c: Cluster, _ rev: Revision, maxTicks: Int = 300) -> Bool {
        c.run(maxTicks: maxTicks, until: { c.replicasUp().allSatisfy { cube($0).revision >= rev } })
    }

    /// All up nodes agree on cubestore state (digest equality).
    static func allAgree(_ c: Cluster) -> Bool {
        guard let first = c.replicasUp().first else { return true }
        let d = cube(first).digest()
        return c.replicasUp().allSatisfy { cube($0).digest() == d }
    }

    static func main() {
        case2_writeReplicates()
        case3_talkToAnyForwards()
        case9_casUnderRaft()
        case10_linearizableRead()

        if failed {
            FileHandle.standardError.write(Data("store-test: FAILED\n".utf8))
            exit(1)
        }
        print("store-test: all SC1b cases (2,3,9,10) passed")
    }

    // 2. A write proposed to the leader commits + applies on all three; revision
    //    and keyspace identical across nodes.
    static func case2_writeReplicates() {
        let c = newCluster([1, 2, 3], 0x2A)
        guard let l = electLeader(c) else { check(false, "2: no leader"); return }
        _ = l.node.propose(enc([], [.put(key: b("/a"), value: b("1"))]))
        check(waitRevisionAll(c, 1), "2: write commits + applies on all nodes")
        for r in c.replicasUp() {
            check(cube(r).revision == 1, "2: node \(r.id) revision is 1 (\(cube(r).revision))")
            check(cube(r).get(b("/a"))?.value == b("1"), "2: node \(r.id) has the value")
        }
        check(allAgree(c), "2: cubestore keyspace identical across nodes")
        check(c.violations.isEmpty, "2: no safety violation (\(c.violations.first ?? ""))")
    }

    // 3. talk-to-any: a write submitted to a follower is forwarded to the leader
    //    and applied cluster-wide.
    static func case3_talkToAnyForwards() {
        let c = newCluster([1, 2, 3], 0x3B)
        guard let l = electLeader(c) else { check(false, "3: no leader"); return }
        c.run(3)                                   // let followers learn leaderId
        let follower = c.replicasUp().first { !$0.node.isLeader }!
        check(!follower.node.isLeader, "3: submitting to a non-leader")
        let idx = c.submitWrite(to: follower.id, enc([], [.put(key: b("/k"), value: b("v"))]))
        check(idx != nil, "3: follower forwarded the write to the leader")
        check(waitRevisionAll(c, 1), "3: forwarded write applies cluster-wide")
        for r in c.replicasUp() {
            check(cube(r).get(b("/k"))?.value == b("v"), "3: node \(r.id) has the forwarded value")
        }
        check(l.node.isLeader, "3: leadership stable")
        check(allAgree(c) && c.violations.isEmpty, "3: agreement, no safety violation")
    }

    // 9. CAS under Raft: a create-if-absent proposed on any node commits once;
    //    a second create-if-absent rejects on every node; post-state identical.
    static func case9_casUnderRaft() {
        let c = newCluster([1, 2, 3], 0x9C)
        guard electLeader(c) != nil else { check(false, "9: no leader"); return }
        c.run(3)
        let followers = c.replicasUp().filter { !$0.node.isLeader }

        // First CAS, submitted to a follower (forwarded): should commit.
        guard let i1 = c.submitWrite(to: followers[0].id,
                                     enc([.keyAbsent(key: b("lock"))], [.put(key: b("lock"), value: b("A"))])) else {
            check(false, "9: first CAS not routed"); return
        }
        // Second CAS, submitted to the other follower: key now exists → reject.
        guard let i2 = c.submitWrite(to: followers[1].id,
                                     enc([.keyAbsent(key: b("lock"))], [.put(key: b("lock"), value: b("B"))])) else {
            check(false, "9: second CAS not routed"); return
        }
        let applied = c.run(maxTicks: 300, until: {
            c.replicasUp().allSatisfy { $0.node.commitIndex >= i2 && cube($0).lastAppliedIndex >= i2 }
        })
        check(applied, "9: both CAS entries committed + applied on all nodes")

        // Same verdict on every node, and the correct post-state.
        for r in c.replicasUp() {
            check(cube(r).casResult(at: i1)?.committed == true, "9: node \(r.id) accepts CAS #1")
            check(cube(r).casResult(at: i2)?.committed == false, "9: node \(r.id) rejects CAS #2")
            check(cube(r).get(b("lock"))?.value == b("A"), "9: node \(r.id) post-state is A")
        }
        check(allAgree(c), "9: identical post-state across nodes")
        check(c.violations.isEmpty, "9: no safety violation (\(c.violations.first ?? ""))")
    }

    // 10. Linearizable (ReadIndex) read: latest committed on the leader; a
    //     partitioned ex-leader does not return stale committed data.
    static func case10_linearizableRead() {
        let c = newCluster([1, 2, 3], 0xA0)
        guard let l = electLeader(c) else { check(false, "10: no leader"); return }
        _ = l.node.propose(enc([], [.put(key: b("/x"), value: b("1"))]))
        check(waitRevisionAll(c, 1), "10: seed write committed")

        // ReadIndex on the leader returns the latest committed value.
        let fresh = c.linearizableRead(on: l.id, maxTicks: 50) { cube($0).get(b("/x"))?.value }
        check(fresh == b("1"), "10: ReadIndex on the leader returns the latest committed state")

        // Isolate the leader alone; the majority {other two} elects a new leader.
        let others = [1, 2, 3].filter { $0 != l.id }
        c.bus.partition([[l.id], others])

        // The partitioned ex-leader cannot confirm a read → no stale data.
        let stale = c.linearizableRead(on: l.id, maxTicks: 60) { cube($0).get(b("/x"))?.value }
        check(stale == nil, "10: a partitioned ex-leader does not serve a stale ReadIndex read")

        // The majority elects a new leader that can serve the latest committed read.
        let gotNew = c.run(maxTicks: 200, until: { c.leaders().contains { others.contains($0.id) } })
        guard let l2 = c.leaders().first(where: { others.contains($0.id) }) else {
            check(false, "10: majority did not elect a new leader"); return
        }
        check(gotNew, "10: majority elected a new leader")
        let onNew = c.linearizableRead(on: l2.id, maxTicks: 80) { cube($0).get(b("/x"))?.value }
        check(onNew == b("1"), "10: new leader serves the latest committed value")
        check(c.violations.isEmpty, "10: no safety violation (\(c.violations.first ?? ""))")
    }
}
