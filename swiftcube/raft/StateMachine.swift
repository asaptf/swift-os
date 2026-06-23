// SPDX-License-Identifier: Apache-2.0
// StateMachine.swift — the replicated state machine seam, Foundation-free.
//
// Raft replicates a log; a *state machine* turns that committed log into useful
// state, identically on every node. The consensus core (`RaftNode`) never touches
// the state machine directly — the driver drains `takeCommitted()` /
// `takeSnapshotToApply()` and feeds them here, in strict index order. This is the
// etcd-raft split: the algorithm and the application are separate, composed by a
// thin driver.
//
// SC1a drives a trivial state machine (an ordered command log, in the test
// harness). SC1b's real state machine is cubestore (`swiftcube/store/`): a
// committed `.normal` entry is a cubestore write batch that advances the MVCC
// revision; `.noop` entries are ignored. Because every node applies the same
// committed sequence, every node reaches the same state — including the same
// compare-and-apply verdict (deterministic-at-apply).

protocol RaftStateMachine: AnyObject {
    /// Highest log index this machine has applied (0 ⇒ nothing applied). Used by
    /// the driver for idempotency and by linearizable reads to know when a
    /// `readIndex` is visible.
    var lastAppliedIndex: LogIndex { get }

    /// Apply one committed entry. Implementations MUST be idempotent by index
    /// (ignore `entry.index <= lastAppliedIndex`, so entries re-emitted after a
    /// restart are no-ops) and MUST ignore `.noop` entries for application state
    /// while still advancing `lastAppliedIndex`. Returns true on the first
    /// application of this index (the driver uses it to trace/record exactly once).
    @discardableResult
    func apply(_ entry: RaftEntry) -> Bool

    /// Serialize the applied state at `lastAppliedIndex` for a Raft snapshot
    /// (log compaction / InstallSnapshot). Opaque to consensus.
    func snapshot() -> Bytes

    /// Reset the machine to a snapshot taken at `fromIndex` (a follower adopting a
    /// leader's snapshot, or a restart from durable storage).
    func restore(fromIndex: LogIndex, _ data: Bytes)

    /// A content fingerprint of the applied state, for cross-node equality checks
    /// in tests (two nodes at the same `lastAppliedIndex` must have equal digests).
    func digest() -> Bytes
}
