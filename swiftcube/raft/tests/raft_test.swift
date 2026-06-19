// SPDX-License-Identifier: Apache-2.0
// raft_test.swift — host test for the SC1a Raft consensus core + simulator.
//
// Compiled with the host Swift toolchain against the Foundation-free Raft core
// (which reuses cubestore's Bytes/ByteIO/Crc32/StorageSink seams) plus the
// in-process simulator, then run with no arguments. Covers the SC1a acceptance
// cases — 1 (single-node elect+commit), 4 (leader failure), 5 (partition + heal,
// no divergence), 6 (follower catch-up via AppendEntries), 7 (persistence /
// restart), 8 (snapshot / InstallSnapshot), 11 (determinism) — driving a trivial
// replicated state machine. SC1b swaps cubestore in as the state machine and adds
// cases 2, 3, 9, 10. Throughout, the simulator continuously asserts the Raft
// safety properties (election safety, log matching, leader/state-machine
// completeness); a violation fails the run even if the case's own checks pass.

import Foundation

/// SC1a drives the trivial `KVStateMachine`; this exposes its applied command
/// list for the assertions below.
extension Replica {
    var applied: [Bytes] { (sm as! KVStateMachine).appliedPayloads }
}

@main
struct RaftTest {
    static var failed = false

    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failed = true
        }
    }

    static func b(_ s: String) -> Bytes { Array(s.utf8) }

    /// Run until a single leader emerges; returns it (or nil on timeout).
    static func electLeader(_ c: Cluster, maxTicks: Int = 200) -> Replica? {
        _ = c.run(maxTicks: maxTicks, until: { c.leader() != nil })
        return c.leader()
    }

    /// Run until every up node has applied at least `count` normal commands.
    @discardableResult
    static func waitAppliedAtLeast(_ c: Cluster, _ count: Int, maxTicks: Int = 300) -> Bool {
        c.run(maxTicks: maxTicks, until: {
            c.replicasUp().allSatisfy { $0.applied.count >= count }
        })
    }

    static func main() {
        case1_singleNode()
        case4_leaderFailure()
        case5_partitionHeal()
        case6_followerCatchUp()
        case7_persistenceRestart()
        case8_snapshotInstall()
        case11_determinism()

        if failed {
            FileHandle.standardError.write(Data("raft-test: FAILED\n".utf8))
            exit(1)
        }
        print("raft-test: all SC1a cases (1,4-8,11) passed")
    }

    // 1. Single node elects itself and commits.
    static func case1_singleNode() {
        let c = Cluster(members: [1], seed: 0xA1)
        guard let l = electLeader(c, maxTicks: 50) else { check(false, "1: single node failed to elect"); return }
        check(l.id == 1 && l.node.currentTerm >= 1, "1: lone node becomes leader")
        _ = l.node.propose(b("hello"))
        c.run(3)
        check(l.applied == [b("hello")], "1: single node commits + applies its write")
        check(c.violations.isEmpty, "1: no safety violation (\(c.violations.first ?? ""))")
    }

    // 4. Kill the leader → a new leader within bounded ticks → writes continue →
    //    no committed entry lost.
    static func case4_leaderFailure() {
        let c = Cluster(members: [1, 2, 3], seed: 0x4B)
        guard let l1 = electLeader(c) else { check(false, "4: no initial leader"); return }
        _ = l1.node.propose(b("a"))
        _ = l1.node.propose(b("b"))
        check(waitAppliedAtLeast(c, 2), "4: initial writes commit on all nodes")

        c.setDown(l1.id, true)                       // kill the leader
        let elected = c.run(maxTicks: 200, until: { c.leader() != nil })
        guard let l2 = c.leader() else { check(false, "4: no new leader after failure"); return }
        check(elected && l2.id != l1.id, "4: a new leader emerges (node \(l2.id))")

        _ = l2.node.propose(b("c"))                  // writes continue
        let ok = c.run(maxTicks: 200, until: {
            c.replicasUp().allSatisfy { $0.applied.count >= 3 }
        })
        check(ok, "4: writes continue under the new leader")
        for r in c.replicasUp() {
            check(r.applied == [b("a"), b("b"), b("c")],
                  "4: no committed entry lost on node \(r.id)")
        }
        check(c.violations.isEmpty, "4: no safety violation (\(c.violations.first ?? ""))")
    }

    // 5. Isolate the leader into a minority → majority elects a new leader and
    //    progresses → old leader cannot commit and steps down on the higher term
    //    → after heal its uncommitted entries are overwritten; no divergence.
    static func case5_partitionHeal() {
        let c = Cluster(members: [1, 2, 3, 4, 5], seed: 0x5C)
        guard let l1 = electLeader(c) else { check(false, "5: no initial leader"); return }
        _ = l1.node.propose(b("w1"))
        check(waitAppliedAtLeast(c, 1), "5: w1 commits cluster-wide pre-partition")

        // Minority {leader + one follower}; majority = the other three.
        let companion = [1, 2, 3, 4, 5].first { $0 != l1.id }!
        let minority = [l1.id, companion]
        let majority = [1, 2, 3, 4, 5].filter { !minority.contains($0) }
        c.bus.partition([minority, majority])

        // The ex-leader appends a doomed write it can never commit (no quorum).
        _ = l1.node.propose(b("w2-doomed"))
        c.run(40)
        check(!l1.applied.contains(b("w2-doomed")), "5: minority leader cannot commit w2")

        // Majority elects a fresh leader and makes progress.
        let gotNew = c.run(maxTicks: 200, until: {
            c.leaders().contains { majority.contains($0.id) }
        })
        guard let l2 = c.leaders().first(where: { majority.contains($0.id) }) else {
            check(false, "5: majority did not elect a leader"); return
        }
        check(gotNew && l2.node.currentTerm > l1.node.currentTerm, "5: new leader at a higher term")
        _ = l2.node.propose(b("w3"))
        let majProgress = c.run(maxTicks: 200, until: {
            majority.allSatisfy { c.replica($0).applied.contains(b("w3")) }
        })
        check(majProgress, "5: majority commits w3 while partitioned")

        // Heal → ex-leader steps down, drops w2, catches up. No divergence.
        c.bus.heal()
        let converged = c.run(maxTicks: 300, until: {
            let want = c.replica(l2.id).applied
            return c.replicasUp().allSatisfy { $0.applied == want }
        })
        check(converged, "5: all nodes converge after heal")
        check(c.replicasUp().allSatisfy { !$0.applied.contains(b("w2-doomed")) },
              "5: the uncommitted w2 is overwritten everywhere")
        check(c.replica(l1.id).applied == [b("w1"), b("w3")], "5: ex-leader caught up to w1,w3")
        check(c.leaders().count <= 1, "5: at most one leader after heal")
        check(c.violations.isEmpty, "5: no safety violation (\(c.violations.first ?? ""))")
    }

    // 6. A follower that was down/behind converges via AppendEntries.
    static func case6_followerCatchUp() {
        let c = Cluster(members: [1, 2, 3], seed: 0x6D)
        guard let l = electLeader(c) else { check(false, "6: no leader"); return }
        let behind = [1, 2, 3].first { $0 != l.id }!
        c.setDown(behind, true)                      // a follower misses everything

        for k in 0..<5 { _ = l.node.propose(b("k\(k)")) }
        let majOk = c.run(maxTicks: 200, until: {
            c.replicasUp().allSatisfy { $0.applied.count >= 5 }
        })
        check(majOk, "6: majority commits the 5 writes with one node down")

        c.setDown(behind, false)                     // bring it back
        let caughtUp = c.run(maxTicks: 300, until: {
            c.replica(behind).applied.count >= 5
        })
        check(caughtUp, "6: the lagging follower converges")
        check(c.replica(behind).applied == c.replica(l.id).applied,
              "6: caught-up follower matches the leader's applied state")
        check(c.violations.isEmpty, "6: no safety violation (\(c.violations.first ?? ""))")
    }

    // 7. Persist {term, votedFor, log}; restart nodes from their sinks → recover
    //    and rejoin without violating safety (no double-vote within a term).
    static func case7_persistenceRestart() {
        let c = Cluster(members: [1, 2, 3], seed: 0x7E)
        guard let l = electLeader(c) else { check(false, "7: no leader"); return }
        _ = l.node.propose(b("p"))
        _ = l.node.propose(b("q"))
        check(waitAppliedAtLeast(c, 2), "7: writes commit before restart")

        // A follower's durable hard state survives a restart (no double vote).
        let follower = c.replicasUp().first { !$0.node.isLeader }!
        let termBefore = follower.node.currentTerm
        follower.restart()
        check(follower.node.currentTerm == termBefore, "7: currentTerm recovered from sink")
        check(follower.node.lastLogIndex >= 3, "7: log recovered from sink")

        // Restart the entire cluster: committed writes are durable; the cluster
        // re-elects and re-applies them from the recovered log.
        for r in c.replicas { r.restart() }
        let reElected = c.run(maxTicks: 300, until: {
            c.leader() != nil && c.replicasUp().allSatisfy { $0.applied.count >= 2 }
        })
        check(reElected, "7: cluster recovers, re-elects, and re-applies committed writes")
        for r in c.replicasUp() {
            check(r.applied == [b("p"), b("q")], "7: node \(r.id) recovered committed state")
        }
        check(c.violations.isEmpty, "7: no safety violation across restart (\(c.violations.first ?? ""))")
    }

    // 8. Snapshot at the applied index, truncate the log, install on a lagging
    //    follower → it converges via InstallSnapshot; SM identical across nodes.
    static func case8_snapshotInstall() {
        let c = Cluster(members: [1, 2, 3], seed: 0x8F)
        guard let l = electLeader(c) else { check(false, "8: no leader"); return }
        let behind = [1, 2, 3].first { $0 != l.id }!
        c.setDown(behind, true)                      // this node will need a snapshot

        for k in 0..<6 { _ = l.node.propose(b("s\(k)")) }
        let majOk = c.run(maxTicks: 200, until: {
            c.replicasUp().allSatisfy { $0.applied.count >= 6 }
        })
        check(majOk, "8: majority commits 6 writes with one node down")

        // Compact the up nodes through their applied index → the entries the
        // down node still needs are gone from the leader's log.
        for r in c.replicasUp() {
            r.node.compact(throughIndex: r.node.commitIndex, snapshotData: r.sm.snapshot())
        }
        check(l.node.lastIncludedIndex > 0, "8: leader compacted its log")

        // Drain any pre-compaction AppendEntries still in flight (the follower is
        // still down, so they are dropped); the compacted leader now offers only
        // InstallSnapshot, so the only path back is a snapshot.
        c.run(5)
        c.setDown(behind, false)                     // must catch up via InstallSnapshot
        let caughtUp = c.run(maxTicks: 400, until: {
            c.replica(behind).applied.count >= 6
        })
        check(caughtUp, "8: lagging follower converges via snapshot install")
        check(c.replica(behind).node.lastIncludedIndex > 0, "8: follower adopted a snapshot")
        let want = c.replica(l.id).applied
        check(c.replicasUp().allSatisfy { $0.applied == want },
              "8: state-machine state identical across all nodes")
        check(c.violations.isEmpty, "8: no safety violation (\(c.violations.first ?? ""))")
    }

    // 11. Same (seed, scenario) ⇒ identical message + apply ordering.
    static func case11_determinism() {
        func runScenario(_ seed: UInt64) -> Cluster {
            let c = Cluster(members: [1, 2, 3, 4, 5], seed: seed)
            c.bus.minDelay = 1; c.bus.maxDelay = 3; c.bus.dropRate = 0.1   // delay+reorder+loss
            _ = electLeader(c)
            if let l = c.leader() { _ = l.node.propose(b("x")); _ = l.node.propose(b("y")) }
            c.run(40)
            // A partition, some progress, then heal.
            if let l = c.leader() {
                let others = [1, 2, 3, 4, 5].filter { $0 != l.id }
                c.bus.partition([[l.id, others[0]], [others[1], others[2], others[3]]])
            }
            c.run(60)
            c.bus.heal()
            c.run(80)
            return c
        }
        let a = runScenario(0xD1CE)
        let d = runScenario(0xD1CE)
        check(a.trace == d.trace, "11: identical event trace for the same (seed, scenario)")
        check(a.replicas.map { $0.applied } == d.replicas.map { $0.applied },
              "11: identical applied state for the same (seed, scenario)")
        // A different seed must diverge somewhere (sanity: the trace is seed-sensitive).
        let e = runScenario(0xBEEF)
        check(a.trace != e.trace, "11: a different seed yields a different trace")
        check(a.violations.isEmpty && d.violations.isEmpty && e.violations.isEmpty,
              "11: no safety violation under chaos (\(a.violations.first ?? ""))")
    }
}
