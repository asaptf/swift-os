// SPDX-License-Identifier: Apache-2.0
// updatestore_test.swift — host unit test for the SWOSBOOT manifest core
// (kernel/fs/swosboot.swift), the shared parser the kernel and the host
// updatestore tool both use.
//
// Run by `make test`. Covers:
//   1. CRC32 against the canonical IEEE check value (external reference).
//   2. Round-trip: a hand-built manifest parses back to the same fields.
//   3. Rejection: corrupt CRC / magic / version / bad slot index all fail.

import Foundation

private func putLE32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
    b[o] = UInt8(v & 0xFF); b[o + 1] = UInt8((v >> 8) & 0xFF)
    b[o + 2] = UInt8((v >> 16) & 0xFF); b[o + 3] = UInt8((v >> 24) & 0xFF)
}
private func putLE64(_ b: inout [UInt8], _ o: Int, _ v: UInt64) {
    putLE32(&b, o, UInt32(v & 0xFFFF_FFFF)); putLE32(&b, o + 4, UInt32((v >> 32) & 0xFFFF_FFFF))
}

// Build a valid 512-byte manifest with two slots; CRC computed last.
private func makeManifest(active: Int, fallback: Int, sequence: UInt32 = 1) -> [UInt8] {
    var m = [UInt8](repeating: 0, count: SwosbootFormat.manifestSize)
    for (i, c) in Array("SWOSBOOT".utf8).enumerated() { m[i] = c }
    putLE32(&m, 8, SwosbootFormat.version)
    putLE32(&m, 16, UInt32(SwosbootFormat.slotCount))
    putLE32(&m, 20, UInt32(active))
    putLE32(&m, 24, UInt32(fallback))
    putLE32(&m, 28, sequence)
    let o0 = SwosbootFormat.slotTableOffset
    putLE32(&m, o0, 1); putLE64(&m, o0 + 8, 8); putLE64(&m, o0 + 16, 100); putLE32(&m, o0 + 24, 1)
    let o1 = o0 + SwosbootFormat.slotEntrySize
    putLE32(&m, o1, 1); putLE64(&m, o1 + 8, 108); putLE64(&m, o1 + 16, 100); putLE32(&m, o1 + 24, 2)
    let crc = m.withUnsafeBytes { swosbootCrc32($0.baseAddress!, SwosbootFormat.crcOffset) }
    putLE32(&m, SwosbootFormat.crcOffset, crc)
    return m
}

private func recrc(_ m: inout [UInt8]) {
    let crc = m.withUnsafeBytes { swosbootCrc32($0.baseAddress!, SwosbootFormat.crcOffset) }
    putLE32(&m, SwosbootFormat.crcOffset, crc)
}

private func parse(_ m: [UInt8]) -> SwosbootManifest? {
    m.withUnsafeBytes { parseSwosbootManifest($0.baseAddress!, m.count) }
}

@main
struct UpdateStoreTest {
    static var failures = 0
    static func check(_ cond: Bool, _ msg: String) {
        if !cond { print("FAIL: \(msg)"); failures += 1 }
    }

    static func main() {
        // 1. CRC32 canonical check value: crc32("123456789") == 0xCBF43926.
        let v = Array("123456789".utf8)
        let crc = v.withUnsafeBytes { swosbootCrc32($0.baseAddress!, v.count) }
        check(crc == 0xCBF4_3926, "CRC32 check value: got 0x\(String(crc, radix: 16)), want 0xcbf43926")

        // 2. Round-trip parse.
        if let p = parse(makeManifest(active: 1, fallback: 0)) {
            check(p.version == 1, "version")
            check(p.activeSlot == 1, "active slot")
            check(p.fallbackSlot == 0, "fallback slot")
            check(p.sequence == 1, "sequence")
            check(p.slot(0).present && p.slot(1).present, "both slots present")
            check(p.slot(0).baseLBA == 8 && p.slot(1).baseLBA == 108, "slot LBAs")
            check(p.slotByteOffset(1) == 108 * 512, "slot 1 byte offset")
            check(p.slot(0).generation == 1 && p.slot(1).generation == 2, "generations")
            check(p.slot(0).state == SwosbootFormat.stateUntried, "default state untried")
        } else {
            check(false, "valid manifest should parse")
        }

        // 3a. Corrupt CRC (flip a byte without recomputing) -> reject.
        var a = makeManifest(active: 0, fallback: 1); a[28] ^= 0xFF
        check(parse(a) == nil, "CRC mismatch must be rejected")

        // 3b. Corrupt magic -> reject.
        var b = makeManifest(active: 0, fallback: 1); b[0] = 0x00
        check(parse(b) == nil, "bad magic must be rejected")

        // 3c. Wrong version -> reject (CRC recomputed so only version is at fault).
        var c = makeManifest(active: 0, fallback: 1); putLE32(&c, 8, 99); recrc(&c)
        check(parse(c) == nil, "unknown version must be rejected")

        // 3d. Out-of-range active slot -> reject (CRC recomputed).
        var d = makeManifest(active: 0, fallback: 1); putLE32(&d, 20, 5); recrc(&d)
        check(parse(d) == nil, "out-of-range active slot must be rejected")

        // 3e. Too-short buffer -> reject.
        let short = [UInt8](repeating: 0, count: 64)
        check(parse(short) == nil, "short buffer must be rejected")

        // 4. Serialize -> parse round-trip is identity (U1b write-back path).
        let s0 = SwosbootSlot(present: true, state: SwosbootFormat.stateConfirmed,
                              baseLBA: 8, lengthSectors: 100, generation: 1, attemptCount: 2)
        let s1 = SwosbootSlot(present: true, state: SwosbootFormat.stateUntried,
                              baseLBA: 108, lengthSectors: 100, generation: 2, attemptCount: 0)
        let m = SwosbootManifest(version: 1, activeSlot: 1, fallbackSlot: 0,
                                 sequence: 7, slot0: s0, slot1: s1)
        var sbuf = [UInt8](repeating: 0xAA, count: SwosbootFormat.manifestSize) // non-zero fill
        sbuf.withUnsafeMutableBytes { serializeSwosbootManifest(m, into: $0.baseAddress!) }
        if let p = parse(sbuf) {
            check(p.activeSlot == 1 && p.fallbackSlot == 0 && p.sequence == 7, "round-trip header")
            check(p.slot(0).state == SwosbootFormat.stateConfirmed && p.slot(0).attemptCount == 2,
                  "round-trip slot0 state/attempts")
            check(p.slot(1).baseLBA == 108 && p.slot(1).generation == 2, "round-trip slot1")
        } else {
            check(false, "serialized manifest should parse")
        }

        if failures == 0 {
            print("PASS: SWOSBOOT manifest core (CRC32 check value, round-trip, corruption rejection)")
        } else {
            print("FAILED: \(failures) check(s)")
            exit(1)
        }
    }
}
