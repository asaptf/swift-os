// SPDX-License-Identifier: Apache-2.0
// Model.swift — cubestore public data model (etcd-lite), Foundation-free.
//
// Keys and values are byte strings; the keyspace is ordered lexicographically on
// key bytes. A global monotonic Revision (UInt64) starts at 0 and is bumped by
// exactly 1 per committed, non-empty write batch. Everything here is a value
// type with no I/O — the same definitions compile under Embedded Swift.

/// Monotonic logical clock of the store. Starts at 0; each committed non-empty
/// batch increments it by exactly 1.
typealias Revision = UInt64

/// Byte string used for both keys and values.
typealias Bytes = [UInt8]

/// A live key/value pair plus its MVCC bookkeeping.
struct Entry: Equatable {
    var key: Bytes
    var value: Bytes
    /// Revision at which this key's current "life" was created (last put after
    /// the key was absent or tombstoned).
    var createRevision: Revision
    /// Revision of the most recent write to this key.
    var modRevision: Revision
    /// Number of writes since create (1 at create, +1 per in-place update).
    var version: UInt64
}

/// A single mutation inside a batch. A batch is applied atomically under one
/// revision; if a key appears more than once in a batch, the last op wins.
enum Op: Equatable {
    case put(key: Bytes, value: Bytes)
    case delete(key: Bytes)

    var key: Bytes {
        switch self {
        case .put(let k, _): return k
        case .delete(let k): return k
        }
    }
}

/// A precondition for `compareAndApply`. Conditions test a key's modRevision or
/// its existence; the batch commits iff every condition holds. This is the
/// primitive leases and leader-election are built on (SC1+).
enum Cond: Equatable {
    case keyExists(key: Bytes)
    case keyAbsent(key: Bytes)
    case modRevisionEquals(key: Bytes, Revision)
    case modRevisionLess(key: Bytes, Revision)
    case modRevisionGreater(key: Bytes, Revision)
}

/// Outcome of `compareAndApply`. On success `revision` is the new (bumped)
/// revision; on failure it is the unchanged current revision.
struct CASResult: Equatable {
    var committed: Bool
    var revision: Revision
}

/// A change delivered to a watcher, strictly in revision order.
enum Event: Equatable {
    case put(key: Bytes, value: Bytes, modRevision: Revision)
    case delete(key: Bytes, modRevision: Revision)

    var modRevision: Revision {
        switch self {
        case .put(_, _, let r): return r
        case .delete(_, let r): return r
        }
    }
    var key: Bytes {
        switch self {
        case .put(let k, _, _): return k
        case .delete(let k, _): return k
        }
    }
}

/// Errors surfaced by the core.
enum CubeError: Error, Equatable {
    /// A read or watch referenced a revision at or below the compaction point;
    /// the caller must re-`range` at the current revision and re-watch.
    case compacted(Revision)
    /// A WAL/snapshot blob failed to decode (bad magic, truncation, bad CRC).
    case corrupt(String)
}

// MARK: - Lexicographic byte-string ordering

/// Three-way lexicographic comparison of two byte strings: negative if a < b,
/// zero if equal, positive if a > b. Shorter is smaller when one is a prefix.
@inline(__always)
func compareBytes(_ a: Bytes, _ b: Bytes) -> Int {
    let n = min(a.count, b.count)
    var i = 0
    while i < n {
        if a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
        i += 1
    }
    if a.count == b.count { return 0 }
    return a.count < b.count ? -1 : 1
}

/// The exclusive upper bound of the half-open range that covers every key with
/// the given prefix, or nil when the prefix is all-0xFF (range is open-ended).
/// Increments the last non-0xFF byte and drops the trailing 0xFF tail.
func prefixEnd(_ prefix: Bytes) -> Bytes? {
    var end = prefix
    var i = end.count - 1
    while i >= 0 {
        if end[i] != 0xFF {
            end[i] += 1
            end.removeLast(end.count - (i + 1))
            return end
        }
        i -= 1
    }
    return nil // all 0xFF (or empty) → no upper bound
}
