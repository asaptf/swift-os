// SPDX-License-Identifier: Apache-2.0
// RamStore.swift — in-memory cubestore durability sinks for SC2.
//
// SC2's acceptance is about nodes appearing/expiring and agents authenticating —
// not crash recovery (that is SC8's datafs PV tier). The controller therefore
// runs its cubestore over a RAM-backed write-ahead log + snapshot store: durable
// for the life of the process, replayable on in-process reopen, and identical in
// behavior to the host POSIX sink for everything SC2 exercises. The datafs-backed
// sink lands with persistence in a later milestone. Foundation-free.

/// An in-memory append log that retains bytes (so reopen-from-log recovery works).
final class RamLog: AppendLog {
    private var data: Bytes = []
    func append(_ bytes: Bytes) { data.append(contentsOf: bytes) }
    func sync() {}
    func readAll() -> Bytes { data }
    func reset() { data.removeAll(keepingCapacity: true) }
}

/// An in-memory snapshot store keeping the latest blob.
final class RamSnapshot: SnapshotStore {
    private var best: (rev: Revision, bytes: Bytes)? = nil
    func put(_ bytes: Bytes, atRevision revision: Revision) {
        if best == nil || revision >= best!.rev { best = (revision, bytes) }
    }
    func latest() -> (revision: Revision, bytes: Bytes)? {
        guard let b = best else { return nil }
        return (b.rev, b.bytes)
    }
}

/// Open a fresh RAM-backed cubestore (the controller's embedded store for SC2).
func openRamCubeStore() -> CubeStore<RamLog, RamSnapshot> {
    try! CubeStore.open(log: RamLog(), snapshot: RamSnapshot())
}
