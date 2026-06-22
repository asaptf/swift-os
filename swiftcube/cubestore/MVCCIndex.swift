// SPDX-License-Identifier: Apache-2.0
// MVCCIndex.swift — ordered, multi-version key index, Foundation-free.
//
// The keyspace is a sorted array of per-key version chains; each chain holds the
// retained history needed for MVCC reads (`atRevision`), watch replay, and
// compaction. A binary search keeps point lookups O(log n) and range scans walk
// a contiguous slice in key order — the prefix-scan / watch-a-prefix paths the
// reconcilers lean on. No Dictionary is used (ordering is intrinsic and the
// structure stays Embedded-friendly).

/// One historical version of a key. A tombstone (`value == nil`) records a
/// delete; its createRevision/version are 0.
struct KeyVersion {
    var modRevision: Revision
    var createRevision: Revision
    var version: UInt64
    var value: Bytes?            // nil = tombstone
    var isTombstone: Bool { value == nil }
}

/// The full retained history of a single key, oldest → newest by modRevision.
struct KeyRecord {
    var key: Bytes
    var versions: [KeyVersion]   // ascending modRevision, non-empty
}

struct MVCCIndex {
    /// Sorted by key (lexicographic). Invariant: each record's `versions` is
    /// non-empty and ascending by modRevision.
    private(set) var records: [KeyRecord] = []

    // MARK: lookup

    /// Index of `key` in `records`, or the insertion point (negative-encoded as
    /// `~insertionIndex`) when absent. Standard lower-bound binary search.
    private func find(_ key: Bytes) -> Int {
        var lo = 0, hi = records.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            let c = compareBytes(records[mid].key, key)
            if c == 0 { return mid }
            if c < 0 { lo = mid + 1 } else { hi = mid }
        }
        return ~lo
    }

    /// The version of `key` visible at `revision` (nil ⇒ latest): the newest
    /// version whose modRevision ≤ revision. Returns nil when the key is absent
    /// at that revision or the visible version is a tombstone.
    func get(_ key: Bytes, atRevision revision: Revision?) -> Entry? {
        let idx = find(key)
        if idx < 0 { return nil }
        let chain = records[idx].versions
        // Walk newest → oldest for the first version at or below `revision`.
        var i = chain.count - 1
        while i >= 0 {
            let v = chain[i]
            if revision == nil || v.modRevision <= revision! {
                if v.isTombstone { return nil }
                return Entry(key: key, value: v.value!,
                             createRevision: v.createRevision,
                             modRevision: v.modRevision, version: v.version)
            }
            i -= 1
        }
        return nil
    }

    /// Live entries in the half-open key range [start, end) at `revision`
    /// (end nil ⇒ open upper bound), in key order. Tombstoned keys are omitted.
    func range(_ start: Bytes, _ end: Bytes?, atRevision revision: Revision?) -> [Entry] {
        var out: [Entry] = []
        var i = lowerBound(start)
        while i < records.count {
            let key = records[i].key
            if let end = end, compareBytes(key, end) >= 0 { break }
            if let e = get(key, atRevision: revision) { out.append(e) }
            i += 1
        }
        return out
    }

    /// First record index whose key is ≥ `key` (range scan start).
    private func lowerBound(_ key: Bytes) -> Int {
        let idx = find(key)
        return idx < 0 ? ~idx : idx
    }

    // MARK: mutation

    /// Apply one op at `revision`, append a version, and return the resulting
    /// event. The caller guarantees at most one op per key per revision.
    mutating func apply(_ op: Op, at revision: Revision) -> Event {
        switch op {
        case .put(let key, let value):
            return put(key, value, at: revision)
        case .delete(let key):
            return delete(key, at: revision)
        }
    }

    private mutating func put(_ key: Bytes, _ value: Bytes, at revision: Revision) -> Event {
        let idx = find(key)
        if idx < 0 {
            // New key.
            let v = KeyVersion(modRevision: revision, createRevision: revision,
                               version: 1, value: value)
            records.insert(KeyRecord(key: key, versions: [v]), at: ~idx)
        } else {
            let last = records[idx].versions[records[idx].versions.count - 1]
            let v: KeyVersion
            if last.isTombstone {
                // Revive: a fresh life, createRevision resets.
                v = KeyVersion(modRevision: revision, createRevision: revision,
                               version: 1, value: value)
            } else {
                v = KeyVersion(modRevision: revision, createRevision: last.createRevision,
                               version: last.version + 1, value: value)
            }
            records[idx].versions.append(v)
        }
        return .put(key: key, value: value, modRevision: revision)
    }

    private mutating func delete(_ key: Bytes, at revision: Revision) -> Event {
        let idx = find(key)
        if idx >= 0 {
            let last = records[idx].versions[records[idx].versions.count - 1]
            if !last.isTombstone {
                let v = KeyVersion(modRevision: revision, createRevision: 0,
                                   version: 0, value: nil)
                records[idx].versions.append(v)
            }
        }
        return .delete(key: key, modRevision: revision)
    }

    // MARK: snapshot / replay seeding

    /// Replace the whole index with a single current version per key (used when
    /// loading a snapshot). Records must be supplied in key order.
    mutating func loadCurrent(_ entries: [Entry]) {
        records = entries.map { e in
            KeyRecord(key: e.key, versions: [KeyVersion(
                modRevision: e.modRevision, createRevision: e.createRevision,
                version: e.version, value: e.value)])
        }
    }

    /// Every live key's current entry, in key order (snapshot payload source).
    func currentEntries() -> [Entry] {
        var out: [Entry] = []
        for rec in records {
            let last = rec.versions[rec.versions.count - 1]
            if !last.isTombstone {
                out.append(Entry(key: rec.key, value: last.value!,
                                 createRevision: last.createRevision,
                                 modRevision: last.modRevision, version: last.version))
            }
        }
        return out
    }

    // MARK: compaction

    /// Drop version history with modRevision ≤ `rev`, keeping each key's current
    /// value so reads stay correct. A key whose newest retained version is a
    /// tombstone at/below `rev` (with no later writes) is removed entirely.
    mutating func compact(upTo rev: Revision) {
        var kept: [KeyRecord] = []
        kept.reserveCapacity(records.count)
        for var rec in records {
            var newer = rec.versions.filter { $0.modRevision > rev }
            // The newest version at or below `rev` is the baseline reads in the
            // gap (rev, firstNewer) resolve to. Keep it only if it is live; a
            // tombstone baseline can be dropped (absence reads as deleted).
            if let base = rec.versions.last(where: { $0.modRevision <= rev }), !base.isTombstone {
                newer.insert(base, at: 0)
            }
            if !newer.isEmpty {
                rec.versions = newer
                kept.append(rec)
            }
        }
        records = kept
    }
}
