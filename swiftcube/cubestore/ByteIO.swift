// SPDX-License-Identifier: Apache-2.0
// ByteIO.swift — little-endian byte (de)serialization, Foundation-free.
//
// Minimal append-only writer and bounds-checked reader used by the WAL and
// snapshot codecs. All multi-byte integers are little-endian. The reader never
// traps on a short buffer: every read returns nil past the end, which is exactly
// how recovery detects a torn trailing record.

struct ByteWriter {
    var bytes: Bytes = []

    mutating func u8(_ v: UInt8) { bytes.append(v) }

    mutating func u32(_ v: UInt32) {
        bytes.append(UInt8(v & 0xFF))
        bytes.append(UInt8((v >> 8) & 0xFF))
        bytes.append(UInt8((v >> 16) & 0xFF))
        bytes.append(UInt8((v >> 24) & 0xFF))
    }

    mutating func u64(_ v: UInt64) {
        var x = v
        var i = 0
        while i < 8 { bytes.append(UInt8(x & 0xFF)); x >>= 8; i += 1 }
    }

    /// Length-prefixed (u32) byte string.
    mutating func blob(_ b: Bytes) {
        u32(UInt32(b.count))
        bytes.append(contentsOf: b)
    }

    /// Raw bytes with no length prefix.
    mutating func raw(_ b: Bytes) { bytes.append(contentsOf: b) }
}

struct ByteReader {
    let bytes: Bytes
    var offset: Int = 0

    init(_ bytes: Bytes) { self.bytes = bytes }

    var remaining: Int { bytes.count - offset }

    mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        var v: UInt32 = 0
        var i = 0
        while i < 4 { v |= UInt32(bytes[offset + i]) << (8 * i); i += 1 }
        offset += 4
        return v
    }

    mutating func u64() -> UInt64? {
        guard remaining >= 8 else { return nil }
        var v: UInt64 = 0
        var i = 0
        while i < 8 { v |= UInt64(bytes[offset + i]) << (8 * i); i += 1 }
        offset += 8
        return v
    }

    /// Read `n` raw bytes; nil if fewer than `n` remain.
    mutating func take(_ n: Int) -> Bytes? {
        guard n >= 0, remaining >= n else { return nil }
        let slice = Array(bytes[offset ..< offset + n])
        offset += n
        return slice
    }

    /// Read a length-prefixed (u32) byte string.
    mutating func blob() -> Bytes? {
        guard let n = u32() else { return nil }
        return take(Int(n))
    }

    /// Match an exact byte sequence (e.g. a magic header); false if absent.
    mutating func expect(_ magic: Bytes) -> Bool {
        guard let got = take(magic.count) else { return false }
        return got == magic
    }
}
