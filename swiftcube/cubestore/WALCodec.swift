// SPDX-License-Identifier: Apache-2.0
// WALCodec.swift — write-ahead-log record framing, Foundation-free.
//
// The log is a versioned magic header followed by one length-prefixed record per
// committed batch. Each record is {revision, ops, crc32}; the CRC covers the
// record body so a torn or short trailing record is detected and discarded on
// recovery (honest fsync + app-level recovery, no FS journaling — see CLAUDE.md).
//
// Stream layout (little-endian):
//   header   : "CUBEWAL" 0x01                      (8 bytes, once at log start)
//   record*  : u32 bodyLen | body[bodyLen] | u32 crc32(body)
//   body     : u64 revision | u32 opCount | op*
//   op       : u8 kind(0=put,1=delete) | u32 keyLen | key | [u32 valLen | val]
//
// No JSON or text anywhere in the format.

/// One decoded committed batch.
struct WALRecord {
    var revision: Revision
    var ops: [Op]
}

/// Result of scanning a whole-log byte stream: the intact records plus the byte
/// offset just past the last good one. `consumed < input.count` means a torn
/// tail was found and discarded; recovery truncates the log to `consumed`.
struct WALScan {
    var records: [WALRecord]
    var consumed: Int
}

enum WALCodec {
    /// 8-byte versioned magic written once at the head of the log.
    static let header: Bytes = [0x43, 0x55, 0x42, 0x45, 0x57, 0x41, 0x4C, 0x01] // "CUBEWAL\x01"

    /// Frame one record (length prefix + body + CRC). Does not include the
    /// header; the store prepends `header` before the first record of a log.
    static func encodeRecord(revision: Revision, ops: [Op]) -> Bytes {
        var body = ByteWriter()
        body.u64(revision)
        body.u32(UInt32(ops.count))
        for op in ops {
            switch op {
            case .put(let key, let value):
                body.u8(0); body.blob(key); body.blob(value)
            case .delete(let key):
                body.u8(1); body.blob(key)
            }
        }
        var frame = ByteWriter()
        frame.u32(UInt32(body.bytes.count))
        frame.raw(body.bytes)
        frame.u32(cubeCrc32(body.bytes))
        return frame.bytes
    }

    /// Scan every intact record from a whole-log byte stream, in order, stopping
    /// at the first torn/partial/bad-CRC record (which is discarded). A log that
    /// does not begin with the header yields no records and consumed == 0.
    /// `consumed` marks the last good byte boundary for torn-tail truncation.
    static func decodeAll(_ bytes: Bytes) -> WALScan {
        var reader = ByteReader(bytes)
        guard reader.expect(header) else { return WALScan(records: [], consumed: 0) }
        var out: [WALRecord] = []
        var consumed = reader.offset                              // header is good
        while true {
            guard let bodyLen = reader.u32() else { break }       // no/partial length
            guard let body = reader.take(Int(bodyLen)) else { break } // partial body → torn
            guard let crc = reader.u32() else { break }           // partial crc → torn
            if cubeCrc32(body) != crc { break }                   // bad crc → torn
            guard let rec = decodeBody(body) else { break }       // unparsable → stop
            out.append(rec)
            consumed = reader.offset
        }
        return WALScan(records: out, consumed: consumed)
    }

    private static func decodeBody(_ body: Bytes) -> WALRecord? {
        var r = ByteReader(body)
        guard let rev = r.u64(), let opCount = r.u32() else { return nil }
        var ops: [Op] = []
        ops.reserveCapacity(Int(opCount))
        var i: UInt32 = 0
        while i < opCount {
            guard let kind = r.u8(), let key = r.blob() else { return nil }
            switch kind {
            case 0:
                guard let val = r.blob() else { return nil }
                ops.append(.put(key: key, value: val))
            case 1:
                ops.append(.delete(key: key))
            default:
                return nil
            }
            i += 1
        }
        return WALRecord(revision: rev, ops: ops)
    }
}
