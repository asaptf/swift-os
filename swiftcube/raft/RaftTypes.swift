// SPDX-License-Identifier: Apache-2.0
// RaftTypes.swift — Raft value types, Foundation-free.
//
// SC1a of SwiftCube. The consensus core is a deterministic state machine in the
// etcd-raft / raft-rs mould: it consumes inbound messages plus logical ticks and
// emits outbound messages plus "entry committed" / "apply snapshot" notifications.
// It never touches a socket or a wall clock. Everything here is a value type so
// the same definitions compile under Embedded Swift later; the `Bytes` payload,
// the byte (de)serializers, the CRC, and the AppendLog/SnapshotStore seams are
// shared verbatim with cubestore (SC0) — the committed Raft log *is* cubestore's
// durability log (see FORMAT.md, "one log not two").

/// Monotonic election term. Starts at 0; a new election bumps it by 1.
typealias Term = UInt64

/// 1-based position of an entry in the replicated log. Index 0 is the synthetic
/// "before the first entry" position (its term is 0).
typealias LogIndex = UInt64

/// Stable identity of a cluster member. Static 3-node config in SC1; dynamic
/// membership / joint consensus is deferred (see the milestone note).
typealias NodeId = Int

/// What a committed log entry means to the state machine.
///
/// `.noop` is the empty entry a freshly elected leader appends to commit at its
/// own term (the Raft leader-completeness requirement: a leader may only advance
/// the commit index via an entry from its current term). The state machine must
/// **ignore** `.noop` entries — in particular they must not bump the cubestore
/// revision. `.normal` carries an opaque state-machine command (in SC1b, a
/// cubestore write batch); only `.normal` entries drive the application.
enum EntryKind: UInt8 {
    case noop = 0
    case normal = 1
}

/// One replicated log entry. `(term, index)` is its identity for the
/// log-matching property; `data` is opaque to the consensus core.
struct RaftEntry: Equatable {
    var term: Term
    var index: LogIndex
    var kind: EntryKind
    var data: Bytes      // empty for .noop; a state-machine command for .normal

    init(term: Term, index: LogIndex, kind: EntryKind, data: Bytes = []) {
        self.term = term
        self.index = index
        self.kind = kind
        self.data = data
    }
}

// MARK: - Wire messages (transport-agnostic)

struct RequestVote: Equatable {
    var term: Term
    var candidate: NodeId
    var lastLogIndex: LogIndex
    var lastLogTerm: Term
}

struct RequestVoteResp: Equatable {
    var term: Term
    var voteGranted: Bool
}

struct AppendEntries: Equatable {
    var term: Term
    var leader: NodeId
    var prevLogIndex: LogIndex
    var prevLogTerm: Term
    var entries: [RaftEntry]
    var leaderCommit: LogIndex
    /// Heartbeat round tag, echoed by the follower, used by the leader's ReadIndex
    /// confirmation to prove it still commands a quorum at the current term.
    var round: UInt64 = 0
}

struct AppendEntriesResp: Equatable {
    var term: Term
    var success: Bool
    /// On success: the follower's highest matched index. On failure: a backtrack
    /// hint — the index the leader should retry from (bounded, no per-index
    /// probing). 0 is never a valid hint (the log is 1-based).
    var matchIndex: LogIndex
    var conflictIndex: LogIndex
    /// The `round` from the AppendEntries this responds to (ReadIndex proof).
    var round: UInt64 = 0
}

/// Single-shot snapshot transfer. SC1's simulated bus delivers whole blobs, so
/// there is no chunking; the real transport (SC2) may chunk without changing the
/// algorithm. `data` is the *state-machine* snapshot (opaque to consensus).
struct InstallSnapshot: Equatable {
    var term: Term
    var leader: NodeId
    var lastIncludedIndex: LogIndex
    var lastIncludedTerm: Term
    var data: Bytes
}

struct InstallSnapshotResp: Equatable {
    var term: Term
    var lastIncludedIndex: LogIndex
}

/// The closed set of consensus messages.
enum RaftMessage: Equatable {
    case requestVote(RequestVote)
    case requestVoteResp(RequestVoteResp)
    case appendEntries(AppendEntries)
    case appendEntriesResp(AppendEntriesResp)
    case installSnapshot(InstallSnapshot)
    case installSnapshotResp(InstallSnapshotResp)

    /// The term carried by the message (used by the bus only for tracing).
    var term: Term {
        switch self {
        case .requestVote(let m):        return m.term
        case .requestVoteResp(let m):    return m.term
        case .appendEntries(let m):      return m.term
        case .appendEntriesResp(let m):  return m.term
        case .installSnapshot(let m):    return m.term
        case .installSnapshotResp(let m): return m.term
        }
    }
}

/// A routed message: who sent it, who receives it, what it is. The consensus
/// core only fills `from`/`to`; the transport (sim bus in SC1, TCP in SC2) moves
/// it.
struct Envelope: Equatable {
    var from: NodeId
    var to: NodeId
    var message: RaftMessage
}
