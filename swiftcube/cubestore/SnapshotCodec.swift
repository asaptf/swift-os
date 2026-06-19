// SPDX-License-Identifier: Apache-2.0
// SnapshotCodec.swift — full-keyspace snapshot framing, Foundation-free.
//
// A snapshot captures every live key (current value + MVCC metadata) at one
// revision, plus the compaction floor, so recovery can start from it and replay
// only the WAL tail. A trailing CRC guards the whole payload.
//
// Layout (little-endian):
//   header            : "CUBESNP" 0x01                 (8 bytes)
//   payload:
//     u64 revision
//     u64 compactedRevision
//     u32 entryCount
//     entry* : u32 keyLen | key | u32 valLen | val | u64 create | u64 mod | u64 version
//   u32 crc32(payload)

struct SnapshotData {
    var revision: Revision
    var compactedRevision: Revision
    var entries: [Entry]   // key order, live only
}

enum SnapshotCodec {
    static let header: Bytes = [0x43, 0x55, 0x42, 0x45, 0x53, 0x4E, 0x50, 0x01] // "CUBESNP\x01"

    static func encode(_ snap: SnapshotData) -> Bytes {
        var payload = ByteWriter()
        payload.u64(snap.revision)
        payload.u64(snap.compactedRevision)
        payload.u32(UInt32(snap.entries.count))
        for e in snap.entries {
            payload.blob(e.key)
            payload.blob(e.value)
            payload.u64(e.createRevision)
            payload.u64(e.modRevision)
            payload.u64(e.version)
        }
        var out = ByteWriter()
        out.raw(header)
        out.raw(payload.bytes)
        out.u32(cubeCrc32(payload.bytes))
        return out.bytes
    }

    static func decode(_ bytes: Bytes) throws -> SnapshotData {
        var r = ByteReader(bytes)
        guard r.expect(header) else { throw CubeError.corrupt("snapshot: bad magic") }
        let payloadStart = r.offset
        guard let revision = r.u64(),
              let compacted = r.u64(),
              let count = r.u32() else { throw CubeError.corrupt("snapshot: short header") }
        var entries: [Entry] = []
        entries.reserveCapacity(Int(count))
        var i: UInt32 = 0
        while i < count {
            guard let key = r.blob(), let val = r.blob(),
                  let create = r.u64(), let mod = r.u64(), let version = r.u64()
            else { throw CubeError.corrupt("snapshot: short entry") }
            entries.append(Entry(key: key, value: val, createRevision: create,
                                 modRevision: mod, version: version))
            i += 1
        }
        let payloadEnd = r.offset
        guard let crc = r.u32() else { throw CubeError.corrupt("snapshot: missing crc") }
        let payload = Array(bytes[payloadStart ..< payloadEnd])
        guard cubeCrc32(payload) == crc else { throw CubeError.corrupt("snapshot: bad crc") }
        return SnapshotData(revision: revision, compactedRevision: compacted, entries: entries)
    }
}
