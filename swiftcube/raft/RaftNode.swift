// SPDX-License-Identifier: Apache-2.0
// RaftNode.swift — the Raft consensus state machine, Foundation-free.
//
// SC1a. A single replica of the Raft algorithm: leader election (randomized,
// seeded, tick-based timeouts), terms + voting, log replication via
// AppendEntries, commit-index advance under the leader-completeness rule,
// step-down on a higher term, and snapshot transfer via InstallSnapshot. It is a
// pure state machine: `tick()` advances logical time, `step()` consumes one
// inbound message, `propose()` submits a command; all three only mutate state and
// queue outbound messages / committed-entry notifications. No socket, no clock —
// the simulator (SC1) and the TCP transport (SC2) drive it identically.
//
// Durable state lives in `SinkRaftStorage` (term, votedFor, log, snapshot); the
// node holds only volatile state (role, commit index, election/heartbeat timers,
// the leader's per-peer progress). On restart the volatile state is rebuilt and
// the durable state recovered — commit index re-derives from replication, which
// is standard Raft.
//
// No Dictionary/Set: per-peer state is kept in arrays parallel to `peers`, in the
// cubestore "ordering is intrinsic, stay Embedded-friendly" style.

enum Role { case follower, candidate, leader }

struct RaftConfig {
    var id: NodeId
    /// All cluster members including `id`. Static 3-node config in SC1.
    var members: [NodeId]
    var electionTimeoutMin: Int   // ticks
    var electionTimeoutMax: Int   // ticks
    var heartbeatInterval: Int    // ticks
    /// Base seed; the per-node election-timeout PRNG is varied by `id`.
    var seed: UInt64
}

final class RaftNode<Log: AppendLog, Snap: SnapshotStore> {
    let id: NodeId
    private let members: [NodeId]
    private let peers: [NodeId]          // members \ id, sorted
    private let quorum: Int
    private let cfg: RaftConfig
    private let storage: SinkRaftStorage<Log, Snap>
    private var rng: SplitMix64

    private(set) var role: Role = .follower
    private(set) var leaderId: NodeId? = nil

    /// Highest index known committed; volatile, rebuilt after restart.
    private(set) var commitIndex: LogIndex = 0
    /// Highest index already surfaced to the driver as committed/applied.
    private var lastEmitted: LogIndex = 0

    // Timers (in ticks).
    private var electionElapsed = 0
    private var electionTimeout = 0
    private var heartbeatElapsed = 0

    // Candidate state.
    private var votesGranted: [NodeId] = []

    // Leader state, parallel to `peers`.
    private var nextIndex: [LogIndex] = []
    private var matchIndex: [LogIndex] = []
    /// Highest heartbeat round each peer has acknowledged (ReadIndex proof).
    private var ackedRound: [UInt64] = []

    // ReadIndex (linearizable reads). A read is confirmed once a quorum of peers
    // has acked a heartbeat round issued at/after the request — proving current
    // leadership — at which point the recorded `readIndex` may be served.
    private var heartbeatRound: UInt64 = 0
    private var nextReadId: UInt64 = 1
    private struct PendingRead { var id: UInt64; var readIndex: LogIndex; var round: UInt64 }
    private var pendingReads: [PendingRead] = []
    private var readReady: [(id: UInt64, index: LogIndex)] = []

    // Output buffers drained by the driver.
    private var outbox: [Envelope] = []
    private var committedOut: [RaftEntry] = []
    private var snapshotToApply: (index: LogIndex, data: Bytes)? = nil

    init(config: RaftConfig, storage: SinkRaftStorage<Log, Snap>) {
        self.cfg = config
        self.id = config.id
        self.members = config.members.sorted()
        self.peers = config.members.filter { $0 != config.id }.sorted()
        self.quorum = config.members.count / 2 + 1
        self.storage = storage
        self.rng = SplitMix64(seed: config.seed ^ UInt64(bitPattern: Int64(config.id)) &* 0x100_0000_01B3)
        self.commitIndex = storage.lastIncludedIndex
        self.lastEmitted = storage.lastIncludedIndex
        self.nextIndex = [LogIndex](repeating: storage.lastIndex + 1, count: peers.count)
        self.matchIndex = [LogIndex](repeating: 0, count: peers.count)
        self.ackedRound = [UInt64](repeating: 0, count: peers.count)
        resetElectionTimer()
    }

    // MARK: - Driver-facing accessors

    var isLeader: Bool { role == .leader }
    var currentTerm: Term { storage.currentTerm }
    var lastLogIndex: LogIndex { storage.lastIndex }
    var lastLogTerm: Term { storage.lastTerm }
    var lastIncludedIndex: LogIndex { storage.lastIncludedIndex }
    var snapshotData: Bytes { storage.snapshotData }

    /// In-memory log entries (post-snapshot), for the simulator's safety audits.
    var auditEntries: [RaftEntry] { storage.auditEntries }
    func logTerm(at index: LogIndex) -> Term? { storage.term(at: index) }

    /// Drain queued outbound messages (cleared by the call).
    func takeMessages() -> [Envelope] { defer { outbox.removeAll() }; return outbox }
    /// Drain newly committed entries, in strict index order (cleared by the call).
    func takeCommitted() -> [RaftEntry] { defer { committedOut.removeAll() }; return committedOut }
    /// Drain a pending "reset the state machine to this snapshot" notification. The
    /// driver applies it *before* any committed entries returned in the same round.
    func takeSnapshotToApply() -> (index: LogIndex, data: Bytes)? {
        defer { snapshotToApply = nil }; return snapshotToApply
    }
    /// Drain reads that have been confirmed linearizable: each `readIndex` is safe
    /// to serve once the state machine has applied up to it. Cleared by the call.
    func takeReadReady() -> [(id: UInt64, index: LogIndex)] { defer { readReady.removeAll() }; return readReady }

    // MARK: - Inputs

    /// Advance one logical tick: drive elections (follower/candidate) or heartbeat
    /// fan-out (leader).
    func tick() {
        if role == .leader {
            heartbeatElapsed += 1
            if heartbeatElapsed >= cfg.heartbeatInterval {
                heartbeatElapsed = 0
                heartbeatRound += 1                 // a fresh round each heartbeat
                for p in peers { sendAppend(to: p) }
            }
        } else {
            electionElapsed += 1
            if electionElapsed >= electionTimeout { startElection() }
        }
    }

    /// Submit a state-machine command. Only the leader accepts it; followers
    /// reject (the driver forwards to `leaderId`). Returns the assigned index, or
    /// nil if not leader.
    @discardableResult
    func propose(_ data: Bytes, kind: EntryKind = .normal) -> LogIndex? {
        guard role == .leader else { return nil }
        let e = RaftEntry(term: storage.currentTerm, index: storage.lastIndex + 1, kind: kind, data: data)
        storage.append([e])
        for p in peers { sendAppend(to: p) }
        leaderMaybeCommit()        // single-node clusters commit immediately
        return e.index
    }

    /// Compact the durable log through `throughIndex` (already applied by the
    /// driver), folding in the state-machine snapshot. Drives InstallSnapshot for
    /// lagging followers.
    func compact(throughIndex idx: LogIndex, snapshotData data: Bytes) {
        guard idx <= commitIndex else { return }
        storage.compact(throughIndex: idx, snapshotData: data)
    }

    /// Request a linearizable read (ReadIndex). Records the current commit index
    /// and triggers a heartbeat round; the read surfaces via `takeReadReady()`
    /// only once a quorum confirms current leadership, so a partitioned ex-leader
    /// never serves stale data. Returns the read id, or nil if not leader (the
    /// driver then forwards). The caller serves the read against state at/after
    /// `readIndex` once the state machine has applied that far.
    func requestRead() -> UInt64? {
        guard role == .leader else { return nil }
        let id = nextReadId; nextReadId += 1
        heartbeatRound += 1
        let round = heartbeatRound
        pendingReads.append(PendingRead(id: id, readIndex: commitIndex, round: round))
        for p in peers { sendAppend(to: p) }   // carries the fresh round
        tryConfirmReads()                       // single-node: self is the quorum
        return id
    }

    /// Consume one inbound message from `from`.
    func step(_ message: RaftMessage, from: NodeId) {
        switch message {
        case .requestVote(let m):        handleRequestVote(m)
        case .requestVoteResp(let m):    handleRequestVoteResp(from: from, m)
        case .appendEntries(let m):      handleAppendEntries(m)
        case .appendEntriesResp(let m):  handleAppendEntriesResp(from: from, m)
        case .installSnapshot(let m):    handleInstallSnapshot(m)
        case .installSnapshotResp(let m): handleInstallSnapshotResp(from: from, m)
        }
    }

    // MARK: - Elections

    private func startElection() {
        role = .candidate
        storage.saveHardState(term: storage.currentTerm + 1, votedFor: id)
        leaderId = nil
        votesGranted = [id]
        resetElectionTimer()
        let li = storage.lastIndex, lt = storage.lastTerm, term = storage.currentTerm
        for p in peers {
            send(to: p, .requestVote(RequestVote(term: term, candidate: id,
                                                 lastLogIndex: li, lastLogTerm: lt)))
        }
        if votesGranted.count >= quorum { becomeLeader() }   // single-node cluster
    }

    private func handleRequestVote(_ m: RequestVote) {
        if m.term > storage.currentTerm { becomeFollower(term: m.term, leader: nil) }
        var grant = false
        if m.term >= storage.currentTerm {
            let canVote = storage.votedFor == nil || storage.votedFor == m.candidate
            if canVote && candidateUpToDate(lastIndex: m.lastLogIndex, lastTerm: m.lastLogTerm) {
                grant = true
                storage.saveHardState(term: storage.currentTerm, votedFor: m.candidate)
                resetElectionTimer()       // a granted vote defers our own election
            }
        }
        send(to: m.candidate, .requestVoteResp(RequestVoteResp(term: storage.currentTerm, voteGranted: grant)))
    }

    private func handleRequestVoteResp(from: NodeId, _ m: RequestVoteResp) {
        if m.term > storage.currentTerm { becomeFollower(term: m.term, leader: nil); return }
        guard role == .candidate, m.term == storage.currentTerm, m.voteGranted else { return }
        if !votesGranted.contains(from) { votesGranted.append(from) }
        if votesGranted.count >= quorum { becomeLeader() }
    }

    /// Raft's up-to-date test: longer term wins; equal term, longer log wins.
    private func candidateUpToDate(lastIndex li: LogIndex, lastTerm lt: Term) -> Bool {
        if lt != storage.lastTerm { return lt > storage.lastTerm }
        return li >= storage.lastIndex
    }

    private func becomeLeader() {
        role = .leader
        leaderId = id
        nextIndex = [LogIndex](repeating: storage.lastIndex + 1, count: peers.count)
        matchIndex = [LogIndex](repeating: 0, count: peers.count)
        ackedRound = [UInt64](repeating: 0, count: peers.count)   // reads need fresh acks
        pendingReads.removeAll()
        heartbeatElapsed = 0
        // A no-op at the new term lets the leader commit at its own term (the
        // leader-completeness requirement). The state machine ignores .noop.
        let noop = RaftEntry(term: storage.currentTerm, index: storage.lastIndex + 1, kind: .noop)
        storage.append([noop])
        for p in peers { sendAppend(to: p) }
        leaderMaybeCommit()
    }

    // MARK: - Log replication (leader → follower)

    private func sendAppend(to peer: NodeId) {
        guard let k = peerIndex(peer) else { return }
        let ni = nextIndex[k]
        if ni <= storage.lastIncludedIndex {
            // The next needed entry is compacted away → ship a snapshot instead.
            send(to: peer, .installSnapshot(InstallSnapshot(
                term: storage.currentTerm, leader: id,
                lastIncludedIndex: storage.lastIncludedIndex,
                lastIncludedTerm: storage.lastIncludedTerm,
                data: storage.snapshotData)))
            return
        }
        let prev = ni - 1
        let prevTerm = storage.term(at: prev) ?? storage.lastIncludedTerm
        let es = storage.slice(from: ni, to: storage.lastIndex)
        send(to: peer, .appendEntries(AppendEntries(
            term: storage.currentTerm, leader: id,
            prevLogIndex: prev, prevLogTerm: prevTerm,
            entries: es, leaderCommit: commitIndex, round: heartbeatRound)))
    }

    private func handleAppendEntries(_ m: AppendEntries) {
        if m.term < storage.currentTerm {
            send(to: m.leader, .appendEntriesResp(AppendEntriesResp(
                term: storage.currentTerm, success: false, matchIndex: 0, conflictIndex: 0, round: m.round)))
            return
        }
        // Valid leader for this (or a newer) term: adopt it, reset our timer.
        becomeFollower(term: m.term, leader: m.leader)

        // Consistency check at prevLogIndex.
        if m.prevLogIndex > storage.lastIndex {
            send(to: m.leader, .appendEntriesResp(AppendEntriesResp(
                term: storage.currentTerm, success: false, matchIndex: 0,
                conflictIndex: storage.lastIndex + 1, round: m.round)))
            return
        }
        if m.prevLogIndex >= storage.lastIncludedIndex,
           let t = storage.term(at: m.prevLogIndex), t != m.prevLogTerm {
            // Backtrack to the first index of the conflicting term (bounded probe).
            var ci = m.prevLogIndex
            while ci > storage.lastIncludedIndex + 1, storage.term(at: ci - 1) == t { ci -= 1 }
            send(to: m.leader, .appendEntriesResp(AppendEntriesResp(
                term: storage.currentTerm, success: false, matchIndex: 0, conflictIndex: ci, round: m.round)))
            return
        }

        // prevLog matches (or is below our snapshot floor → already committed):
        // splice the new entries, truncating the first conflicting suffix.
        var i = 0
        while i < m.entries.count {
            let e = m.entries[i]
            if e.index <= storage.lastIncludedIndex { i += 1; continue }
            if e.index <= storage.lastIndex {
                if storage.term(at: e.index) == e.term { i += 1; continue }  // already present
                storage.truncateSuffix(from: e.index)                       // conflict → drop tail
            }
            storage.append(Array(m.entries[i...]))
            break
        }

        let lastNew = m.entries.isEmpty ? m.prevLogIndex : m.entries[m.entries.count - 1].index
        if m.leaderCommit > commitIndex {
            advanceCommit(to: min(m.leaderCommit, lastNew))
        }
        send(to: m.leader, .appendEntriesResp(AppendEntriesResp(
            term: storage.currentTerm, success: true,
            matchIndex: max(lastNew, storage.lastIncludedIndex), conflictIndex: 0, round: m.round)))
    }

    private func handleAppendEntriesResp(from: NodeId, _ m: AppendEntriesResp) {
        if m.term > storage.currentTerm { becomeFollower(term: m.term, leader: nil); return }
        guard role == .leader, m.term == storage.currentTerm, let k = peerIndex(from) else { return }
        // The peer responded at our term → it acknowledges us as leader for this
        // round (success or log-mismatch alike): a ReadIndex confirmation signal.
        if m.round > ackedRound[k] { ackedRound[k] = m.round }
        if m.success {
            if m.matchIndex > matchIndex[k] { matchIndex[k] = m.matchIndex }
            nextIndex[k] = matchIndex[k] + 1
            leaderMaybeCommit()
        } else {
            nextIndex[k] = max(1, m.conflictIndex)
            sendAppend(to: from)       // retry immediately with the hint
        }
        tryConfirmReads()
    }

    // MARK: - Snapshot transfer

    private func handleInstallSnapshot(_ m: InstallSnapshot) {
        if m.term < storage.currentTerm {
            send(to: m.leader, .installSnapshotResp(InstallSnapshotResp(
                term: storage.currentTerm, lastIncludedIndex: storage.lastIncludedIndex)))
            return
        }
        becomeFollower(term: m.term, leader: m.leader)

        if m.lastIncludedIndex > storage.lastIncludedIndex && m.lastIncludedIndex > commitIndex {
            storage.installSnapshot(lastIncludedIndex: m.lastIncludedIndex,
                                    lastIncludedTerm: m.lastIncludedTerm, data: m.data)
            commitIndex = m.lastIncludedIndex
            lastEmitted = m.lastIncludedIndex
            snapshotToApply = (m.lastIncludedIndex, m.data)
        }
        send(to: m.leader, .installSnapshotResp(InstallSnapshotResp(
            term: storage.currentTerm, lastIncludedIndex: storage.lastIncludedIndex)))
    }

    private func handleInstallSnapshotResp(from: NodeId, _ m: InstallSnapshotResp) {
        if m.term > storage.currentTerm { becomeFollower(term: m.term, leader: nil); return }
        guard role == .leader, m.term == storage.currentTerm, let k = peerIndex(from) else { return }
        if m.lastIncludedIndex > matchIndex[k] { matchIndex[k] = m.lastIncludedIndex }
        nextIndex[k] = matchIndex[k] + 1
        leaderMaybeCommit()
    }

    // MARK: - Commit advance

    /// Leader rule: the highest index replicated on a quorum *and* at the current
    /// term may be committed (entries from prior terms commit only indirectly).
    private func leaderMaybeCommit() {
        var idx = storage.lastIndex
        while idx > commitIndex {
            if storage.term(at: idx) == storage.currentTerm {
                var count = 1                                   // self
                for mi in matchIndex where mi >= idx { count += 1 }
                if count >= quorum { advanceCommit(to: idx); return }
            }
            idx -= 1
        }
    }

    private func advanceCommit(to newCommit: LogIndex) {
        guard newCommit > commitIndex else { return }
        commitIndex = newCommit
        var i = lastEmitted + 1
        while i <= commitIndex {
            if let e = storage.entry(at: i) { committedOut.append(e) }
            i += 1
        }
        lastEmitted = commitIndex
    }

    // MARK: - Role transitions / helpers

    private func becomeFollower(term: Term, leader: NodeId?) {
        if term > storage.currentTerm { storage.saveHardState(term: term, votedFor: nil) }
        role = .follower
        leaderId = leader
        votesGranted.removeAll()
        pendingReads.removeAll()        // pending reads fail; the driver forwards
        resetElectionTimer()
    }

    /// Promote any pending read whose round has been acked by a quorum (current
    /// leadership confirmed) to `readReady`.
    private func tryConfirmReads() {
        guard role == .leader else { pendingReads.removeAll(); return }
        var stillPending: [PendingRead] = []
        for r in pendingReads {
            var count = 1                                  // self
            for ar in ackedRound where ar >= r.round { count += 1 }
            if count >= quorum { readReady.append((r.id, r.readIndex)) }
            else { stillPending.append(r) }
        }
        pendingReads = stillPending
    }

    private func resetElectionTimer() {
        electionElapsed = 0
        electionTimeout = rng.int(in: cfg.electionTimeoutMin ... cfg.electionTimeoutMax)
    }

    private func send(to: NodeId, _ message: RaftMessage) {
        outbox.append(Envelope(from: id, to: to, message: message))
    }

    private func peerIndex(_ id: NodeId) -> Int? {
        for (k, p) in peers.enumerated() where p == id { return k }
        return nil
    }
}
