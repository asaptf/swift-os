// SPDX-License-Identifier: Apache-2.0
// CubeStore.swift — single-node MVCC KV store with watch + WAL/snapshot.
//
// SC0 of SwiftCube. The store is an ordered, multi-version key/value store: each
// committed batch is one atomic revision, durably logged to an AppendLog and
// periodically checkpointed to a SnapshotStore. Reads are MVCC (latest or as-of
// a revision); writes are batches or compare-and-apply transactions; watchers
// stream changes in strict revision order, replayable from any retained point.
//
// The core is synchronous and single-threaded by contract — concurrency is the
// caller's concern at SC0. It is generic over the durability seams (no
// existentials) and Foundation-free, so it can later compile under Embedded
// Swift for swift-os userland. The network wrap (SC2) and Raft wrap (SC1) sit
// outside this type; a watcher is fully described by {range, fromRevision},
// which is exactly what those layers need to resume a stream.

final class CubeStore<Log: AppendLog, Snap: SnapshotStore> {
    private var index = MVCCIndex()
    /// Highest committed revision. Starts at 0; +1 per committed non-empty batch.
    private(set) var revision: Revision = 0
    /// History floor: watching from below this yields `.compacted`. Raised by
    /// `compact(upTo:)` and by recovering from a snapshot.
    private(set) var compactedRevision: Revision = 0

    private let log: Log
    private let snap: Snap
    private var logHasHeader = false

    private var watchers: [Watcher] = []
    private var nextWatcherId = 1

    private init(log: Log, snapshot: Snap) {
        self.log = log
        self.snap = snapshot
    }

    // MARK: - Open / recover

    /// Open a store over the given sinks, recovering durable state: load the
    /// latest snapshot (if any), then replay WAL records with revision greater
    /// than it. A torn trailing record is detected, discarded, and the log is
    /// durably truncated to the last good boundary.
    static func open(log: Log, snapshot: Snap) throws -> CubeStore {
        let store = CubeStore(log: log, snapshot: snapshot)

        if let latest = snapshot.latest() {
            let data = try SnapshotCodec.decode(latest.bytes)
            store.index.loadCurrent(data.entries)
            store.revision = data.revision
            store.compactedRevision = data.compactedRevision
        }

        let raw = log.readAll()
        let scan = WALCodec.decodeAll(raw)
        for rec in scan.records where rec.revision > store.revision {
            for op in rec.ops { _ = store.index.apply(op, at: rec.revision) }
            store.revision = rec.revision
        }

        // Repair a torn tail (or a log that does not start with the header) so
        // future appends extend a clean log.
        if scan.consumed < raw.count {
            log.reset()
            if scan.consumed > 0 { log.append(Array(raw[0 ..< scan.consumed])) }
            log.sync()
        }
        store.logHasHeader = scan.consumed >= WALCodec.header.count
        return store
    }

    // MARK: - Reads

    /// MVCC point read: the entry at `revision` (nil ⇒ latest), or nil if the
    /// key is absent/tombstoned there.
    func get(_ key: Bytes, atRevision revision: Revision? = nil) -> Entry? {
        index.get(key, atRevision: revision)
    }

    /// Ordered entries in the half-open key range [start, end) at `revision`
    /// (end nil ⇒ open upper bound; revision nil ⇒ latest).
    func range(_ start: Bytes, _ end: Bytes?, atRevision revision: Revision? = nil) -> [Entry] {
        index.range(start, end, atRevision: revision)
    }

    /// Ordered entries whose key has the given prefix.
    func prefix(_ prefix: Bytes, atRevision revision: Revision? = nil) -> [Entry] {
        index.range(prefix, prefixEnd(prefix), atRevision: revision)
    }

    // MARK: - Writes

    /// Apply a batch atomically under one revision. Returns the new revision, or
    /// the unchanged current revision for an empty batch (a no-op, no bump).
    @discardableResult
    func apply(_ batch: [Op]) -> Revision {
        commit(batch)
    }

    /// Minimal transaction: commit `batch` iff every condition holds. On success
    /// `revision` is the new revision (unchanged if the batch was empty); on
    /// failure the store is untouched.
    @discardableResult
    func compareAndApply(conditions: [Cond], _ batch: [Op]) -> CASResult {
        for c in conditions where !evaluate(c) {
            return CASResult(committed: false, revision: revision)
        }
        return CASResult(committed: true, revision: commit(batch))
    }

    private func evaluate(_ cond: Cond) -> Bool {
        switch cond {
        case .keyExists(let k):            return index.get(k, atRevision: nil) != nil
        case .keyAbsent(let k):            return index.get(k, atRevision: nil) == nil
        case .modRevisionEquals(let k, let r):  return modRev(k) == r
        case .modRevisionLess(let k, let r):    return modRev(k) < r
        case .modRevisionGreater(let k, let r): return modRev(k) > r
        }
    }

    /// Current modRevision of a key; 0 if absent/tombstoned (etcd convention).
    private func modRev(_ key: Bytes) -> Revision {
        index.get(key, atRevision: nil)?.modRevision ?? 0
    }

    /// Shared commit path: collapse to one op per key (last wins, key order),
    /// durably log the record, mutate the index, then fan events out to watchers.
    private func commit(_ batch: [Op]) -> Revision {
        let ops = collapse(batch)
        if ops.isEmpty { return revision }          // empty batch → no bump
        let newRev = revision + 1
        appendRecord(revision: newRev, ops: ops)
        var events: [Event] = []
        events.reserveCapacity(ops.count)
        for op in ops { events.append(index.apply(op, at: newRev)) }
        revision = newRev
        broadcast(events)                            // already in key order
        return newRev
    }

    /// Reduce a batch to at most one op per key (last op wins), sorted by key.
    /// This enforces the "one version per key per revision" invariant the index
    /// and watch replay rely on.
    private func collapse(_ batch: [Op]) -> [Op] {
        var result: [Op] = []
        for op in batch {
            if let i = result.firstIndex(where: { compareBytes($0.key, op.key) == 0 }) {
                result[i] = op
            } else {
                result.append(op)
            }
        }
        result.sort { compareBytes($0.key, $1.key) < 0 }
        return result
    }

    private func appendRecord(revision: Revision, ops: [Op]) {
        var blob: Bytes = []
        if !logHasHeader { blob = WALCodec.header; logHasHeader = true }
        blob.append(contentsOf: WALCodec.encodeRecord(revision: revision, ops: ops))
        log.append(blob)
    }

    /// Flush the WAL to stable storage (honest fsync). Committed batches are
    /// appended eagerly; durability across a crash is established here.
    func sync() { log.sync() }

    // MARK: - Compaction

    /// Drop version history with modRevision ≤ `rev`; current values stay.
    /// Watching from at/below `rev` afterwards yields `.compacted`.
    func compact(upTo rev: Revision) {
        index.compact(upTo: rev)
        if rev > compactedRevision { compactedRevision = rev }
    }

    // MARK: - Snapshot

    /// Capture the full live keyspace at the current revision and truncate the
    /// WAL: every existing record is ≤ this revision and now covered by the
    /// snapshot, so subsequent recovery loads the snapshot and replays only the
    /// post-snapshot tail.
    func snapshot() {
        let data = SnapshotData(revision: revision,
                                compactedRevision: compactedRevision,
                                entries: index.currentEntries())
        snap.put(SnapshotCodec.encode(data), atRevision: revision)
        log.reset()
        logHasHeader = false
    }

    // MARK: - Watch

    /// Watch the half-open key range [start, end) from `fromRevision`: replay
    /// every matching event with modRevision > fromRevision from retained
    /// history (in revision order), then continue live with no gaps or dups.
    /// Throws `.compacted` if fromRevision precedes the compaction floor.
    @discardableResult
    func watchRange(_ start: Bytes, _ end: Bytes?, fromRevision: Revision,
                    _ callback: @escaping (Event) -> Void) throws -> WatchHandle {
        if fromRevision < compactedRevision { throw CubeError.compacted(compactedRevision) }
        let id = nextWatcherId
        nextWatcherId += 1
        let w = Watcher(id: id, start: start, end: end, fromRevision: fromRevision,
                        callback: callback)
        // Replay history, then register live. The core is single-threaded, so no
        // write can interleave between the two — hence no gap or duplicate at the
        // history→live boundary.
        for event in historyEvents(start: start, end: end, after: fromRevision) {
            w.deliver(event)
        }
        watchers.append(w)
        return WatchHandle { [weak self] in self?.removeWatcher(id) }
    }

    /// Watch every key sharing `prefix`.
    @discardableResult
    func watchPrefix(_ prefix: Bytes, fromRevision: Revision,
                     _ callback: @escaping (Event) -> Void) throws -> WatchHandle {
        try watchRange(prefix, prefixEnd(prefix), fromRevision: fromRevision, callback)
    }

    /// Retained events in [start, end) with modRevision > `after`, ordered by
    /// (revision, key) — the same order live delivery produces.
    private func historyEvents(start: Bytes, end: Bytes?, after: Revision) -> [Event] {
        var collected: [Event] = []
        for rec in index.records {
            if compareBytes(rec.key, start) < 0 { continue }
            if let end = end, compareBytes(rec.key, end) >= 0 { continue }
            for v in rec.versions where v.modRevision > after {
                if v.isTombstone {
                    collected.append(.delete(key: rec.key, modRevision: v.modRevision))
                } else {
                    collected.append(.put(key: rec.key, value: v.value!, modRevision: v.modRevision))
                }
            }
        }
        collected.sort { a, b in
            if a.modRevision != b.modRevision { return a.modRevision < b.modRevision }
            return compareBytes(a.key, b.key) < 0
        }
        return collected
    }

    private func broadcast(_ events: [Event]) {
        for event in events {
            for w in watchers where !w.cancelled && w.covers(event.key) {
                w.deliver(event)
            }
        }
    }

    private func removeWatcher(_ id: Int) {
        if let i = watchers.firstIndex(where: { $0.id == id }) {
            watchers[i].cancelled = true
            watchers.remove(at: i)
        }
    }
}
