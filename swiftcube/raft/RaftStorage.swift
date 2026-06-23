// SPDX-License-Identifier: Apache-2.0
// RaftStorage.swift — durable Raft state over cubestore's SC0 sinks.
//
// Raft requires three things to survive a crash: the current term, the vote
// granted this term (votedFor), and the replicated log. SC1 persists all three
// through the *same* SC0 seams cubestore uses — `AppendLog` for the log + hard
// state and `SnapshotStore` for compacted snapshots — which is the "one log, not
// two" reconciliation in the milestone: the committed Raft log replaces SC0's
// standalone cubestore WAL. A Raft snapshot is a state-machine snapshot at the
// applied index; lagging followers receive it via InstallSnapshot.
//
// The store is generic over both sinks (no existentials), so it specializes under
// a later Embedded-Swift build exactly like `CubeStore<Log, Snap>`.
//
// WAL stream layout (little-endian), reusing the SC0 record framing:
//   header   : "CUBERFT" 0x01                       (8 bytes, once at log start)
//   record*  : u32 bodyLen | body | u32 crc32(body)
//   body kinds (first byte):
//     0 hardState : u64 term | u8 hasVote | u64 votedFor
//     1 entry     : u64 index | u64 term | u8 kind | blob data
//     2 truncate  : u64 fromIndex          (drop entries with index ≥ fromIndex)
// Snapshot blob (in the SnapshotStore):
//   "CUBERSN" 0x01 | u64 lastIncludedIndex | u64 lastIncludedTerm | blob smData
//   | u32 crc32(payload)

/// WAL record framing for the Raft log (mirrors `WALCodec`, distinct magic).
enum RaftLogCodec {
    static let header: Bytes = [0x43, 0x55, 0x42, 0x45, 0x52, 0x46, 0x54, 0x01] // "CUBERFT\x01"

    enum Record {
        case hardState(term: Term, votedFor: NodeId?)
        case entry(RaftEntry)
        case truncate(from: LogIndex)
    }

    static func encode(_ rec: Record) -> Bytes {
        var body = ByteWriter()
        switch rec {
        case .hardState(let term, let votedFor):
            body.u8(0)
            body.u64(term)
            body.u8(votedFor == nil ? 0 : 1)
            body.u64(votedFor == nil ? 0 : UInt64(bitPattern: Int64(votedFor!)))
        case .entry(let e):
            body.u8(1)
            body.u64(e.index)
            body.u64(e.term)
            body.u8(e.kind.rawValue)
            body.blob(e.data)
        case .truncate(let from):
            body.u8(2)
            body.u64(from)
        }
        var frame = ByteWriter()
        frame.u32(UInt32(body.bytes.count))
        frame.raw(body.bytes)
        frame.u32(cubeCrc32(body.bytes))
        return frame.bytes
    }

    /// Scan every intact record, stopping at the first torn/bad-CRC record. A log
    /// not beginning with the header yields nothing.
    static func decodeAll(_ bytes: Bytes) -> [Record] {
        var r = ByteReader(bytes)
        guard r.expect(header) else { return [] }
        var out: [Record] = []
        while true {
            guard let bodyLen = r.u32() else { break }
            guard let body = r.take(Int(bodyLen)) else { break }
            guard let crc = r.u32(), cubeCrc32(body) == crc else { break }
            guard let rec = decodeBody(body) else { break }
            out.append(rec)
        }
        return out
    }

    private static func decodeBody(_ body: Bytes) -> Record? {
        var r = ByteReader(body)
        guard let kind = r.u8() else { return nil }
        switch kind {
        case 0:
            guard let term = r.u64(), let hasVote = r.u8(), let voted = r.u64() else { return nil }
            return .hardState(term: term, votedFor: hasVote == 0 ? nil : NodeId(Int64(bitPattern: voted)))
        case 1:
            guard let index = r.u64(), let term = r.u64(), let k = r.u8(),
                  let kind = EntryKind(rawValue: k), let data = r.blob() else { return nil }
            return .entry(RaftEntry(term: term, index: index, kind: kind, data: data))
        case 2:
            guard let from = r.u64() else { return nil }
            return .truncate(from: from)
        default:
            return nil
        }
    }
}

/// Snapshot framing for the Raft/cubestore unified snapshot.
enum RaftSnapshotCodec {
    static let header: Bytes = [0x43, 0x55, 0x42, 0x45, 0x52, 0x53, 0x4E, 0x01] // "CUBERSN\x01"

    static func encode(lastIncludedIndex: LogIndex, lastIncludedTerm: Term, data: Bytes) -> Bytes {
        var payload = ByteWriter()
        payload.u64(lastIncludedIndex)
        payload.u64(lastIncludedTerm)
        payload.blob(data)
        var out = ByteWriter()
        out.raw(header)
        out.raw(payload.bytes)
        out.u32(cubeCrc32(payload.bytes))
        return out.bytes
    }

    static func decode(_ bytes: Bytes) -> (index: LogIndex, term: Term, data: Bytes)? {
        var r = ByteReader(bytes)
        guard r.expect(header) else { return nil }
        let start = r.offset
        guard let index = r.u64(), let term = r.u64(), let data = r.blob() else { return nil }
        let end = r.offset
        guard let crc = r.u32(), cubeCrc32(Array(bytes[start ..< end])) == crc else { return nil }
        return (index, term, data)
    }
}

/// Durable Raft state: hard state + the log (after the latest snapshot) + the
/// state-machine snapshot blob. The in-memory copy is the working set; every
/// mutation is written through to the sinks and fsync'd, so a restart over the
/// same sinks recovers identical state (no double-vote within a term).
final class SinkRaftStorage<Log: AppendLog, Snap: SnapshotStore> {
    private let log: Log
    private let snap: Snap
    private var logHasHeader = false

    private(set) var currentTerm: Term = 0
    private(set) var votedFor: NodeId? = nil

    /// Index/term of the last entry covered by the snapshot (0 ⇒ no snapshot).
    private(set) var lastIncludedIndex: LogIndex = 0
    private(set) var lastIncludedTerm: Term = 0
    /// Opaque state-machine snapshot at `lastIncludedIndex` (sent in InstallSnapshot).
    private(set) var snapshotData: Bytes = []

    /// Log entries after the snapshot, contiguous and ascending; the entry at
    /// position k has index `lastIncludedIndex + 1 + k`.
    private var entries: [RaftEntry] = []

    private init(log: Log, snapshot: Snap) {
        self.log = log
        self.snap = snapshot
    }

    // MARK: open / recover

    /// Recover durable state: load the latest snapshot, then replay WAL records
    /// (hard-state updates, entry appends, truncations) in order. A torn trailing
    /// record is ignored by the codec scan; the recovered log is otherwise exact.
    static func open(log: Log, snapshot: Snap) -> SinkRaftStorage {
        let s = SinkRaftStorage(log: log, snapshot: snapshot)
        if let latest = snapshot.latest(), let snap = RaftSnapshotCodec.decode(latest.bytes) {
            s.lastIncludedIndex = snap.index
            s.lastIncludedTerm = snap.term
            s.snapshotData = snap.data
        }
        let raw = log.readAll()
        // The header is present iff the log already begins with the magic; future
        // appends then extend a clean log without re-prepending it.
        s.logHasHeader = raw.count >= RaftLogCodec.header.count
            && Array(raw.prefix(RaftLogCodec.header.count)) == RaftLogCodec.header
        let records = RaftLogCodec.decodeAll(raw)
        for rec in records {
            switch rec {
            case .hardState(let term, let votedFor):
                s.currentTerm = term
                s.votedFor = votedFor
            case .entry(let e):
                if e.index <= s.lastIncludedIndex { continue }      // covered by snapshot
                if e.index == s.lastIndex + 1 {
                    s.entries.append(e)
                } else if e.index <= s.lastIndex {
                    // Re-append after a truncate: overwrite the tail in place.
                    let k = Int(e.index - s.lastIncludedIndex - 1)
                    s.entries.removeLast(s.entries.count - k)
                    s.entries.append(e)
                }
            case .truncate(let from):
                if from <= s.lastIndex {
                    let keep = from > s.lastIncludedIndex ? Int(from - s.lastIncludedIndex - 1) : 0
                    s.entries.removeLast(s.entries.count - keep)
                }
            }
        }
        return s
    }

    // MARK: queries

    var lastIndex: LogIndex { lastIncludedIndex + UInt64(entries.count) }

    var lastTerm: Term {
        entries.isEmpty ? lastIncludedTerm : entries[entries.count - 1].term
    }

    var hasSnapshot: Bool { lastIncludedIndex > 0 }

    /// The in-memory log entries after the snapshot (for the simulator's safety
    /// audits — log-matching, leader-completeness).
    var auditEntries: [RaftEntry] { entries }

    /// Term of the entry at `index`, or nil if it is below the snapshot floor
    /// (other than the snapshot boundary itself) or beyond the log end.
    func term(at index: LogIndex) -> Term? {
        if index == 0 { return 0 }
        if index == lastIncludedIndex { return lastIncludedTerm }
        if index > lastIncludedIndex && index <= lastIndex {
            return entries[Int(index - lastIncludedIndex - 1)].term
        }
        return nil
    }

    func entry(at index: LogIndex) -> RaftEntry? {
        guard index > lastIncludedIndex && index <= lastIndex else { return nil }
        return entries[Int(index - lastIncludedIndex - 1)]
    }

    /// Entries in the inclusive index range [lo, hi] that are present in the log.
    func slice(from lo: LogIndex, to hi: LogIndex) -> [RaftEntry] {
        guard lo <= hi else { return [] }
        let start = max(lo, lastIncludedIndex + 1)
        guard start <= hi, start <= lastIndex else { return [] }
        let end = min(hi, lastIndex)
        var out: [RaftEntry] = []
        var i = start
        while i <= end { out.append(entries[Int(i - lastIncludedIndex - 1)]); i += 1 }
        return out
    }

    // MARK: mutations (write-through + fsync)

    func saveHardState(term: Term, votedFor: NodeId?) {
        currentTerm = term
        self.votedFor = votedFor
        appendRecord(.hardState(term: term, votedFor: votedFor))
        log.sync()
    }

    /// Append entries that extend the log contiguously from `lastIndex + 1`.
    func append(_ es: [RaftEntry]) {
        guard !es.isEmpty else { return }
        precondition(es[0].index == lastIndex + 1, "raft: non-contiguous append")
        for e in es {
            entries.append(e)
            appendRecord(.entry(e))
        }
        log.sync()
    }

    /// Drop entries with index ≥ `index` (a conflicting suffix on a follower).
    func truncateSuffix(from index: LogIndex) {
        guard index <= lastIndex else { return }
        let keep = index > lastIncludedIndex ? Int(index - lastIncludedIndex - 1) : 0
        guard keep < entries.count else { return }
        entries.removeLast(entries.count - keep)
        appendRecord(.truncate(from: index))
        log.sync()
    }

    /// Local compaction: capture a state-machine snapshot at `throughIndex` (which
    /// must be ≤ lastIndex and already applied), drop the covered prefix, and
    /// rewrite the WAL so recovery starts from the snapshot + tail.
    func compact(throughIndex idx: LogIndex, snapshotData data: Bytes) {
        guard idx > lastIncludedIndex, idx <= lastIndex, let t = term(at: idx) else { return }
        let tail = slice(from: idx + 1, to: lastIndex)
        lastIncludedIndex = idx
        lastIncludedTerm = t
        snapshotData = data
        entries = tail
        rewriteLog()
    }

    /// Follower applies a leader's snapshot: adopt it, discard the in-memory log
    /// (the post-snapshot tail is refetched via AppendEntries), and rewrite the
    /// WAL. Returns false if the snapshot is not newer than what we already hold.
    @discardableResult
    func installSnapshot(lastIncludedIndex idx: LogIndex, lastIncludedTerm t: Term, data: Bytes) -> Bool {
        guard idx > lastIncludedIndex else { return false }
        lastIncludedIndex = idx
        lastIncludedTerm = t
        snapshotData = data
        entries = []
        rewriteLog()
        return true
    }

    func sync() { log.sync() }

    // MARK: log writing

    private func appendRecord(_ rec: RaftLogCodec.Record) {
        var blob: Bytes = []
        if !logHasHeader { blob = RaftLogCodec.header; logHasHeader = true }
        blob.append(contentsOf: RaftLogCodec.encode(rec))
        log.append(blob)
    }

    /// Persist the snapshot, then reset the WAL and restamp current hard state +
    /// the post-snapshot tail. Mirrors cubestore's `snapshot()` truncate pattern.
    private func rewriteLog() {
        snap.put(RaftSnapshotCodec.encode(lastIncludedIndex: lastIncludedIndex,
                                          lastIncludedTerm: lastIncludedTerm,
                                          data: snapshotData),
                 atRevision: lastIncludedIndex)
        log.reset()
        logHasHeader = false
        appendRecord(.hardState(term: currentTerm, votedFor: votedFor))
        for e in entries { appendRecord(.entry(e)) }
        log.sync()
    }
}
