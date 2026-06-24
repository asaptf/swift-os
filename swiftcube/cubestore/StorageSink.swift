// SPDX-License-Identifier: Apache-2.0
// StorageSink.swift — durability seams, Foundation-free.
//
// Two protocols isolate the core from the medium: AppendLog (the write-ahead
// log) and SnapshotStore (full-keyspace checkpoints). The core only ever hands
// across already-framed byte blobs — record framing, CRCs and the magic header
// live in the codecs (WALCodec / SnapshotCodec), so a sink is a dumb byte
// medium. The store is generic over both protocols (no existentials), which
// keeps it specializable under a later Embedded-Swift build.
//
// SC0 ships one implementation, the host POSIX-file sink (kept outside the core
// in host/PosixFileSink.swift). The swift-os datafs implementation is a later
// milestone; this is the only seam it needs to satisfy.

/// The write-ahead log: an append-only byte stream with honest durability and
/// sequential read-back for recovery.
protocol AppendLog: AnyObject {
    /// Append one already-framed record blob to the end of the log.
    func append(_ bytes: Bytes)
    /// Flush all appended bytes to stable storage (honest fsync/fdatasync).
    func sync()
    /// All bytes currently in the log, oldest first, for sequential recovery.
    func readAll() -> Bytes
    /// Truncate the log to empty. Used after a snapshot captures every record.
    func reset()
}

/// Full-keyspace checkpoints, tagged by the revision they capture.
protocol SnapshotStore: AnyObject {
    /// Persist a snapshot blob taken at `revision`.
    func put(_ bytes: Bytes, atRevision revision: Revision)
    /// The most recent snapshot, or nil if none exists.
    func latest() -> (revision: Revision, bytes: Bytes)?
}
