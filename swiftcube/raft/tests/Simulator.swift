// SPDX-License-Identifier: Apache-2.0
// Simulator.swift — deterministic in-process Raft cluster harness (NOT core).
//
// SC1a's test substrate: an N-node cluster driven over a controllable message bus
// that can drop, delay, reorder, partition, and heal — all from a seeded PRNG, so
// a (seed, scenario) pair reproduces byte-for-byte. The harness drives the
// Foundation-free consensus core but is itself allowed Foundation (per SC1). It
// asserts the Raft *safety* properties continuously (not merely "it worked"):
//   - election safety   : at most one leader per term;
//   - log matching      : equal (index, term) ⇒ identical prefix on any two nodes;
//   - leader completeness/state-machine safety: a committed index never changes,
//     and applied command sequences are prefixes of one another.
//
// The trivial state machine here (an ordered list of applied command payloads)
// stands in for cubestore; SC1b swaps cubestore in as the real state machine.

import Foundation

typealias SimStorage = SinkRaftStorage<MemAppendLog, MemSnapshotStore>
typealias SimNode = RaftNode<MemAppendLog, MemSnapshotStore>

// MARK: - In-memory durability sinks (retain bytes across reopen = restart)

final class MemAppendLog: AppendLog {
    private(set) var data: Bytes = []
    func append(_ bytes: Bytes) { data.append(contentsOf: bytes) }
    func sync() {}
    func readAll() -> Bytes { data }
    func reset() { data = [] }
}

final class MemSnapshotStore: SnapshotStore {
    private var best: (rev: Revision, bytes: Bytes)? = nil
    func put(_ bytes: Bytes, atRevision revision: Revision) {
        if best == nil || revision >= best!.rev { best = (revision, bytes) }
    }
    func latest() -> (revision: Revision, bytes: Bytes)? {
        guard let b = best else { return nil }
        return (b.rev, b.bytes)
    }
}

// MARK: - Trivial replicated state machine

/// An ordered log of applied `.normal` command payloads — the trivial state
/// machine for the SC1a cases. Idempotent by index, so re-emitted entries after a
/// restart are no-ops. Snapshots round-trip the state.
final class KVStateMachine: RaftStateMachine {
    private(set) var lastAppliedIndex: LogIndex = 0
    private(set) var appliedPayloads: [Bytes] = []

    @discardableResult
    func apply(_ e: RaftEntry) -> Bool {
        guard e.index > lastAppliedIndex else { return false }
        lastAppliedIndex = e.index
        if e.kind == .normal { appliedPayloads.append(e.data) }
        return true
    }

    func snapshot() -> Bytes {
        var w = ByteWriter()
        w.u32(UInt32(appliedPayloads.count))
        for p in appliedPayloads { w.blob(p) }
        return w.bytes
    }

    func restore(fromIndex: LogIndex, _ data: Bytes) {
        lastAppliedIndex = fromIndex
        var r = ByteReader(data)
        var out: [Bytes] = []
        if let n = r.u32() {
            var i: UInt32 = 0
            while i < n { guard let p = r.blob() else { break }; out.append(p); i += 1 }
        }
        appliedPayloads = out
    }

    func digest() -> Bytes { snapshot() }
}

// MARK: - One replica (node + storage + state machine + sinks)

final class Replica {
    let id: NodeId
    let cfg: RaftConfig
    let log = MemAppendLog()
    let snap = MemSnapshotStore()
    var storage: SimStorage
    var node: SimNode
    private let makeSM: () -> RaftStateMachine
    var sm: RaftStateMachine
    var down = false
    /// First-application trace (index, term, kind) for safety auditing.
    var applyTrace: [(index: LogIndex, term: Term, kind: EntryKind)] = []
    /// Linearizable reads confirmed on this node (ReadIndex), drained from the node.
    var readyReads: [(id: UInt64, index: LogIndex)] = []

    init(_ cfg: RaftConfig, makeSM: @escaping () -> RaftStateMachine) {
        self.id = cfg.id
        self.cfg = cfg
        self.makeSM = makeSM
        self.storage = SimStorage.open(log: log, snapshot: snap)
        self.node = SimNode(config: cfg, storage: storage)
        self.sm = makeSM()
    }

    /// Simulate a crash + restart: rebuild volatile node state and the state
    /// machine from durable storage over the same sinks.
    func restart() {
        storage = SimStorage.open(log: log, snapshot: snap)
        node = SimNode(config: cfg, storage: storage)
        sm = makeSM()
        readyReads.removeAll()
        if storage.hasSnapshot {
            sm.restore(fromIndex: storage.lastIncludedIndex, storage.snapshotData)
        }
    }

    /// The confirmed `readIndex` for a pending read id, if any.
    func confirmedReadIndex(_ id: UInt64) -> LogIndex? { readyReads.first { $0.id == id }?.index }
}

// MARK: - Message bus (drop / delay / reorder / partition / heal)

private struct InFlight { var deliverAt: UInt64; var seq: UInt64; var env: Envelope }

final class MessageBus {
    private var queue: [InFlight] = []
    private var seq: UInt64 = 0
    private var rng: SplitMix64

    /// Per-message independent drop probability [0, 1).
    var dropRate: Double = 0
    /// Latency window in ticks; maxDelay > minDelay enables reordering.
    var minDelay: Int = 1
    var maxDelay: Int = 1
    /// Network partition as disjoint groups; nil ⇒ fully connected (healed).
    private var groups: [[NodeId]]? = nil

    init(seed: UInt64) { self.rng = SplitMix64(seed: seed) }

    func partition(_ groups: [[NodeId]]) { self.groups = groups }
    func heal() { self.groups = nil }

    private func connected(_ a: NodeId, _ b: NodeId) -> Bool {
        guard let groups = groups else { return true }
        for g in groups where g.contains(a) { return g.contains(b) }
        return false
    }

    /// Offer an outbound message at `now`. May drop (partition or random loss);
    /// otherwise schedules delivery after a randomized latency.
    func offer(_ env: Envelope, now: UInt64) {
        guard connected(env.from, env.to) else { return }
        if dropRate > 0 {
            // Deterministic Bernoulli draw from the seeded stream.
            let r = Double(rng.int(in: 0...999_999)) / 1_000_000.0
            if r < dropRate { return }
        }
        let delay = UInt64(rng.int(in: minDelay...maxDelay))
        queue.append(InFlight(deliverAt: now + delay, seq: seq, env: env))
        seq += 1
    }

    /// Remove and return all messages due at/under `now`, in deterministic
    /// (deliverAt, seq) order. Messages whose path is now partitioned are dropped.
    func deliverDue(now: UInt64) -> [Envelope] {
        let due = queue.filter { $0.deliverAt <= now }.sorted {
            $0.deliverAt != $1.deliverAt ? $0.deliverAt < $1.deliverAt : $0.seq < $1.seq
        }
        queue.removeAll { $0.deliverAt <= now }
        return due.compactMap { connected($0.env.from, $0.env.to) ? $0.env : nil }
    }
}

// MARK: - Cluster driver + safety auditor

final class Cluster {
    private(set) var replicas: [Replica]
    let bus: MessageBus
    private(set) var tick: UInt64 = 0

    /// Recorded safety-property violations; the test asserts this stays empty.
    private(set) var violations: [String] = []
    /// Deterministic event trace (deliveries + first applies) for the
    /// determinism test (case 11).
    private(set) var trace: [String] = []

    // Auditor state.
    private var leaderOfTerm: [Term: NodeId] = [:]
    private var committedAt: [LogIndex: (term: Term, data: Bytes)] = [:]

    init(members: [NodeId], seed: UInt64,
         electionTimeout: ClosedRange<Int> = 10...20, heartbeat: Int = 1,
         makeSM: @escaping () -> RaftStateMachine = { KVStateMachine() }) {
        self.bus = MessageBus(seed: seed ^ 0xB05_5EED)
        self.replicas = members.map { id in
            Replica(RaftConfig(id: id, members: members,
                               electionTimeoutMin: electionTimeout.lowerBound,
                               electionTimeoutMax: electionTimeout.upperBound,
                               heartbeatInterval: heartbeat, seed: seed),
                    makeSM: makeSM)
        }
    }

    func replica(_ id: NodeId) -> Replica { replicas.first { $0.id == id }! }
    func replicasUp() -> [Replica] { replicas.filter { !$0.down } }
    private var up: [Replica] { replicas.filter { !$0.down } }

    func leaders() -> [Replica] { up.filter { $0.node.isLeader } }
    func leader() -> Replica? { leaders().first }

    func setDown(_ id: NodeId, _ value: Bool) { replica(id).down = value }

    // MARK: tick loop

    /// Advance one logical tick: deliver due messages, tick nodes, collect their
    /// outbound messages, apply newly committed entries, then audit invariants.
    func step() {
        tick += 1
        let now = tick

        for env in bus.deliverDue(now: now) {
            guard let r = replicas.first(where: { $0.id == env.to }), !r.down else { continue }
            trace.append("D@\(now) \(env.from)->\(env.to) \(kind(env.message))")
            r.node.step(env.message, from: env.from)
        }
        for r in up { r.node.tick() }
        for r in up {
            for env in r.node.takeMessages() { bus.offer(env, now: now) }
        }
        for r in up { applyReady(r) }
        audit()
    }

    /// Step until `done()` holds or `maxTicks` elapse. Returns whether it held.
    @discardableResult
    func run(maxTicks: Int, until done: () -> Bool) -> Bool {
        var n = 0
        while n < maxTicks {
            if done() { return true }
            step()
            n += 1
        }
        return done()
    }

    /// Step exactly `n` ticks.
    func run(_ n: Int) { for _ in 0..<n { step() } }

    private func applyReady(_ r: Replica) {
        if let snap = r.node.takeSnapshotToApply() {
            r.sm.restore(fromIndex: snap.index, snap.data)
        }
        for e in r.node.takeCommitted() where r.sm.apply(e) {
            r.applyTrace.append((e.index, e.term, e.kind))
            trace.append("A@\(tick) n=\(r.id) i=\(e.index)")
            recordCommitted(e)
        }
        r.readyReads.append(contentsOf: r.node.takeReadReady())
    }

    // MARK: proposing / forwarding / reads

    /// Propose on the current leader (sanity / direct path). Returns the index.
    @discardableResult
    func proposeOnLeader(_ data: Bytes) -> LogIndex? {
        guard let l = leader() else { return nil }
        return l.node.propose(data)
    }

    /// Submit a write to any node; if it is not the leader, follow its `leaderId`
    /// hint to route to the leader (the in-sim form of "talk-to-any" forwarding —
    /// the client-facing forwarding RPC is SC2). Returns the index the leader
    /// assigned, or nil if no leader is currently reachable.
    @discardableResult
    func submitWrite(to nodeId: NodeId, _ data: Bytes) -> LogIndex? {
        var current = nodeId
        for _ in 0..<replicas.count {
            let r = replica(current)
            if r.down { return nil }
            if r.node.isLeader { return r.node.propose(data) }
            guard let hint = r.node.leaderId, hint != current else { return nil }
            current = hint
        }
        return nil
    }

    /// Perform a linearizable (ReadIndex) read on `nodeId`: confirm leadership via
    /// a heartbeat round, then serve once the state machine has applied the read
    /// index. Returns nil if `nodeId` is not the leader or leadership cannot be
    /// confirmed within `maxTicks` (e.g. a partitioned ex-leader) — the caller
    /// then forwards or fails rather than returning stale data.
    func linearizableRead<T>(on nodeId: NodeId, maxTicks: Int, _ serve: (Replica) -> T) -> T? {
        let r = replica(nodeId)
        guard let id = r.node.requestRead() else { return nil }    // not leader → forward
        var n = 0
        while n < maxTicks {
            if let idx = r.confirmedReadIndex(id), r.sm.lastAppliedIndex >= idx {
                return serve(r)
            }
            step(); n += 1
        }
        return nil
    }

    // MARK: auditing

    private func recordCommitted(_ e: RaftEntry) {
        if let prev = committedAt[e.index] {
            if prev.term != e.term || prev.data != e.data {
                violations.append("state-machine safety: index \(e.index) committed twice with different content")
            }
        } else {
            committedAt[e.index] = (e.term, e.data)
        }
    }

    private func audit() {
        // Election safety: ≤ 1 leader per term.
        for r in up where r.node.isLeader {
            let t = r.node.currentTerm
            if let other = leaderOfTerm[t], other != r.id {
                violations.append("election safety: nodes \(other) and \(r.id) both leader in term \(t)")
            } else {
                leaderOfTerm[t] = r.id
            }
        }
        // Log matching: equal (index, term) ⇒ identical term-prefix on any pair.
        for a in 0..<replicas.count {
            for b in (a + 1)..<replicas.count {
                checkLogMatch(replicas[a], replicas[b])
            }
        }
        // State-machine safety: two nodes that have applied the same number of
        // entries must be in byte-identical state (deterministic apply).
        for a in 0..<replicas.count {
            for b in (a + 1)..<replicas.count {
                let sa = replicas[a].sm, sb = replicas[b].sm
                if sa.lastAppliedIndex == sb.lastAppliedIndex && sa.digest() != sb.digest() {
                    violations.append("state-machine safety: nodes \(replicas[a].id)/\(replicas[b].id) diverge at applied index \(sa.lastAppliedIndex)")
                }
            }
        }
    }

    private func checkLogMatch(_ a: Replica, _ b: Replica) {
        // Build index→term over each node's in-memory log.
        func terms(_ r: Replica) -> [LogIndex: Term] {
            var m: [LogIndex: Term] = [:]
            for e in r.node.auditEntries { m[e.index] = e.term }
            return m
        }
        let ta = terms(a), tb = terms(b)
        let common = ta.keys.filter { tb[$0] != nil }.sorted()
        var highestAgree: LogIndex? = nil
        for i in common where ta[i] == tb[i] { highestAgree = i }
        guard let top = highestAgree else { return }
        for i in common where i <= top {
            if ta[i] != tb[i] {
                violations.append("log matching: nodes \(a.id)/\(b.id) differ at index \(i) below an agreeing index \(top)")
            }
        }
    }

    private func kind(_ m: RaftMessage) -> String {
        switch m {
        case .requestVote:        return "RV"
        case .requestVoteResp:    return "RVR"
        case .appendEntries:      return "AE"
        case .appendEntriesResp:  return "AER"
        case .installSnapshot:    return "IS"
        case .installSnapshotResp: return "ISR"
        }
    }
}
