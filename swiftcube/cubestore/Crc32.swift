// SPDX-License-Identifier: Apache-2.0
// Crc32.swift — IEEE 802.3 CRC-32 over byte slices (cubestore WAL/snapshot).
//
// Reflected, polynomial 0xEDB88320, init/xorout 0xFFFFFFFF. Bitwise (no lookup
// table → no static storage), which keeps the core freestanding and friendly to
// a later Embedded-Swift build. Canonical check: cubeCrc32("123456789".utf8) ==
// 0xCBF43926. This is the same algorithm the swosboot manifest uses, kept as a
// separate cubestore symbol so the core has no kernel dependency.

/// CRC-32/ISO-HDLC over a contiguous byte buffer.
@inline(__always)
func cubeCrc32<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in bytes {
        crc ^= UInt32(byte)
        var bit = 0
        while bit < 8 {
            let mask = UInt32(0) &- (crc & 1) // 0xFFFFFFFF if low bit set, else 0
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
            bit += 1
        }
    }
    return ~crc
}
