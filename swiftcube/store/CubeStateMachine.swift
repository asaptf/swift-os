// SPDX-License-Identifier: Apache-2.0
// CubeStateMachine.swift — cubestore as the Raft replicated state machine.
//
// SC1b. This is the glue that makes the SC0 cubestore the deterministic state
// machine driven by the committed Raft log. Each committed `.normal` entry is a
// `WriteRequest` (a compare-and-apply); applying it advances the cubestore MVCC
// revision by exactly 1 when it commits. `.noop` entries (the leader's
// commit-advance) are ignored, so they never bump the revision. Because every
// node applies the same committed sequence in the same order, every node reaches
// the same state and the same CAS verdict.
//
// "One log, not two": cubestore here runs over a **discard** log and an in-memory
// snapshot — its own SC0 WAL is retired. Durability is the Raft log
// (`SinkRaftStorage`); a Raft snapshot (log compaction / InstallSnapshot) is a
// cubestore snapshot at the applied revision, produced by `snapshot()` and
// reloaded by `restore(...)`.

/// A WAL sink that discards everything — cubestore needs no second log here.
final class DiscardLog: AppendLog {
    func append(_ bytes: Bytes) {}
    func sync() {}
    func readAll() -> Bytes { [] }
    func reset() {}
}

/// An in-memory snapshot store: keeps the latest blob, used to ferry cubestore's
/// snapshot bytes in and out of the state machine.
final class RamSnapshotStore: SnapshotStore {
    private var best: (rev: Revision, bytes: Bytes)? = nil
    func put(_ bytes: Bytes, atRevision revision: Revision) {
        if best == nil || revision >= best!.rev { best = (revision, bytes) }
    }
    func latest() -> (revision: Revision, bytes: Bytes)? {
        guard let b = best else { return nil }
        return (b.rev, b.bytes)
    }
}

final class CubeStateMachine: RaftStateMachine {
    private var store: CubeStore<DiscardLog, RamSnapshotStore>
    private var snap = RamSnapshotStore()
    private(set) var lastAppliedIndex: LogIndex = 0
    /// Per-index CAS outcome, so the node that proposed a write can report the
    /// single agreed verdict to its client once the entry applies.
    private(set) var results: [LogIndex: CASResult] = [:]

    init() {
        store = try! CubeStore.open(log: DiscardLog(), snapshot: snap)
    }

    // MARK: RaftStateMachine

    @discardableResult
    func apply(_ entry: RaftEntry) -> Bool {
        guard entry.index > lastAppliedIndex else { return false }   // idempotent
        lastAppliedIndex = entry.index
        guard entry.kind == .normal else { return true }             // .noop: no state change
        let req = WriteRequestCodec.decode(entry.data) ?? WriteRequest(ops: [])
        results[entry.index] = store.compareAndApply(conditions: req.conditions, req.ops)
        return true
    }

    func snapshot() -> Bytes {
        store.snapshot()                       // encodes the live keyspace into `snap`
        return snap.latest()?.bytes ?? []
    }

    func restore(fromIndex: LogIndex, _ data: Bytes) {
        let fresh = RamSnapshotStore()
        if !data.isEmpty { fresh.put(data, atRevision: 0) }
        store = try! CubeStore.open(log: DiscardLog(), snapshot: fresh)
        snap = fresh
        lastAppliedIndex = fromIndex
        results.removeAll()
    }

    /// Non-mutating content fingerprint: the revision plus every live entry in key
    /// order. Two nodes at the same applied index must produce identical digests.
    func digest() -> Bytes {
        var w = ByteWriter()
        w.u64(store.revision)
        let entries = store.range([], nil)
        w.u32(UInt32(entries.count))
        for e in entries {
            w.blob(e.key); w.blob(e.value)
            w.u64(e.createRevision); w.u64(e.modRevision); w.u64(e.version)
        }
        return w.bytes
    }

    // MARK: read API (served from applied state)

    var revision: Revision { store.revision }
    func get(_ key: Bytes) -> Entry? { store.get(key) }
    func range(_ start: Bytes, _ end: Bytes?) -> [Entry] { store.range(start, end) }
    func casResult(at index: LogIndex) -> CASResult? { results[index] }
}
