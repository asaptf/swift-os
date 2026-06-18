// SPDX-License-Identifier: Apache-2.0
// swosboot.swift — the SWOSBOOT boot manifest: an I/O-free parser for the
// two-slot A/B update store (U1a).
//
// This is the read side of the A/B update story. A persistent, writable
// virtio-blk "update store" disk carries two slots, each holding a full signed
// SWOSBASE-v3 base-image, plus a small boot manifest that says which slot is
// active and which is the known-good fallback. At boot the kernel reads the
// manifest, mounts the active slot's image (verifying its Ed25519 signature via
// the existing I8 path), and falls back to the fallback slot if the active
// image fails to verify.
//
// Trust boundary (deliberate): the manifest is CRC32-protected, NOT signed. The
// kernel holds only the *public* image-signing key, so it cannot sign the
// boot-state it will write at runtime (U1b). That is sound because the manifest
// is not a trust anchor — it only *selects among* self-authenticating signed
// images. A store-disk attacker can at worst point "active" at the other
// (still-signed) slot or induce a boot loop: an availability/DoS concern, never
// a code-integrity bypass (a forged image still fails Ed25519 at mount). This
// matches the trust posture the base-image disk already has.
//
// This file is I/O-free and holds no mutable global state, so it compiles into
// both the kernel (Embedded Swift) and the host tools/tests unchanged. The
// kernel-only I/O glue (reading the sectors, setting the driver's slot offset,
// the verified-fallback retry) lives in kernel/fs/updatestore.swift; the host
// store builder is tools/updatestore.swift.

/// On-disk format constants for the SWOSBOOT manifest. The manifest is exactly
/// one 512-byte sector, stored in two copies (LBA 0 and LBA 1) so a future
/// in-place rewrite (U1b) is torn-write safe: the reader picks the valid copy
/// with the highest sequence number.
///
/// All integers are little-endian. Layout:
/// ```
///   0   u8[8]  magic = "SWOSBOOT"
///   8   u32    version = 1
///   12  u32    flags (reserved, 0)
///   16  u32    slot_count (2)
///   20  u32    active_slot   (0 or 1)
///   24  u32    fallback_slot (0 or 1)
///   28  u32    sequence      (monotonic; higher wins among valid copies)
///   32  slot[0] (48 bytes)
///   80  slot[1] (48 bytes)
///   128 u64    min_system_version  (anti-rollback floor; OS-3) — see below
///   ... reserved zeros ...
///   508 u32    crc32 over bytes [0, 508)
/// ```
/// Slot entry (48 bytes):
/// ```
///   +0  u32   present (1/0)
///   +4  u32   state   (0 untried, 1 confirmed, 2 failed)   — boot-state, U1b
///   +8  u64   base_lba         (sector offset of the slot's SWOSBASE image)
///   +16 u64   length_sectors   (slot image length in sectors)
///   +24 u32   generation
///   +28 u32   attempt_count                                — boot-state, U1b
///   +32 u64   system_version   (monotonic OS version staged here; OS-3)
///   +40 u8[8] reserved
/// ```
/// OS-3 anti-rollback: `system_version` records the monotonic version of the OS
/// staged into each slot; `min_system_version` is the floor a freshly staged slot
/// must exceed. Both live in bytes that were reserved (and zero) in the original
/// layout, so format `version` stays 1 and a pre-OS-3 store still parses (its
/// floor and slot versions read back as 0). The CRC32 already covered these bytes.
enum SwosbootFormat {
    static let manifestSize = 512
    static let version: UInt32 = 1
    static let slotCount = 2
    static let slotTableOffset = 32
    static let slotEntrySize = 48
    static let slotSystemVersionOffset = 32 // u64 within a slot entry (OS-3)
    static let minSystemVersionOffset = 128 // u64 in the manifest, after the slots (OS-3)
    static let crcOffset = 508 // last 4 bytes of the sector

    // Slot boot-state values (U1b consumes these; U1a only reads/selects).
    static let stateUntried: UInt32 = 0
    static let stateConfirmed: UInt32 = 1
    static let stateFailed: UInt32 = 2
}

/// One A/B slot's manifest entry.
struct SwosbootSlot {
    var present: Bool
    var state: UInt32
    var baseLBA: UInt64
    var lengthSectors: UInt64
    var generation: UInt32
    var attemptCount: UInt32
    var systemVersion: UInt64   // OS-3: monotonic OS version staged in this slot
}

/// A parsed, CRC-validated SWOSBOOT manifest copy.
struct SwosbootManifest {
    var version: UInt32
    var activeSlot: Int
    var fallbackSlot: Int
    var sequence: UInt32
    var slot0: SwosbootSlot
    var slot1: SwosbootSlot
    var minSystemVersion: UInt64   // OS-3: anti-rollback floor for newly staged slots

    func slot(_ i: Int) -> SwosbootSlot { i == 0 ? slot0 : slot1 }

    /// Byte offset of a slot's SWOSBASE image on the store disk.
    func slotByteOffset(_ i: Int) -> UInt64 { slot(i).baseLBA &* 512 }
}

// Little-endian byte readers (the manifest buffer is byte-aligned, so we never
// assume natural alignment — mirrors the kernel's vfs.swift le32/le64 style and
// keeps this safe under +strict-align).
@inline(__always) private func sbLoad8(_ p: UnsafeRawPointer, _ o: Int) -> UInt8 {
    p.loadUnaligned(fromByteOffset: o, as: UInt8.self)
}
@inline(__always) private func sbLoad32(_ p: UnsafeRawPointer, _ o: Int) -> UInt32 {
    UInt32(sbLoad8(p, o)) | (UInt32(sbLoad8(p, o + 1)) << 8)
        | (UInt32(sbLoad8(p, o + 2)) << 16) | (UInt32(sbLoad8(p, o + 3)) << 24)
}
@inline(__always) private func sbLoad64(_ p: UnsafeRawPointer, _ o: Int) -> UInt64 {
    UInt64(sbLoad32(p, o)) | (UInt64(sbLoad32(p, o + 4)) << 32)
}

/// IEEE 802.3 CRC-32 (reflected, polynomial 0xEDB88320, init/xorout 0xFFFFFFFF).
/// Bitwise (no lookup table → no static storage, safe on the boot bump heap);
/// 512 bytes is trivial. Canonical check value: crc32("123456789") == 0xCBF43926.
func swosbootCrc32(_ buf: UnsafeRawPointer, _ len: Int) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    var i = 0
    while i < len {
        crc ^= UInt32(sbLoad8(buf, i))
        var bit = 0
        while bit < 8 {
            let mask = UInt32(0) &- (crc & 1) // 0xFFFFFFFF if low bit set, else 0
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
            bit += 1
        }
        i += 1
    }
    return ~crc
}

private func readSwosbootSlot(_ p: UnsafeRawPointer, _ o: Int) -> SwosbootSlot {
    SwosbootSlot(present: sbLoad32(p, o + 0) != 0,
                 state: sbLoad32(p, o + 4),
                 baseLBA: sbLoad64(p, o + 8),
                 lengthSectors: sbLoad64(p, o + 16),
                 generation: sbLoad32(p, o + 24),
                 attemptCount: sbLoad32(p, o + 28),
                 systemVersion: sbLoad64(p, o + SwosbootFormat.slotSystemVersionOffset))
}

/// Parse and validate a single 512-byte manifest copy. Returns nil unless the
/// magic, version, slot count, slot indices, and CRC32 all check out — so a
/// blank, truncated, or corrupted copy is rejected without trusting any field.
func parseSwosbootManifest(_ buf: UnsafeRawPointer, _ len: Int) -> SwosbootManifest? {
    if len < SwosbootFormat.manifestSize { return nil }

    let magic: StaticString = "SWOSBOOT"
    var magicOK = true
    magic.withUTF8Buffer { m in
        var i = 0
        while i < 8 {
            if sbLoad8(buf, i) != m[i] { magicOK = false }
            i += 1
        }
    }
    if !magicOK { return nil }

    let version = sbLoad32(buf, 8)
    if version != SwosbootFormat.version { return nil }

    // CRC over everything before the trailing checksum word.
    let stored = sbLoad32(buf, SwosbootFormat.crcOffset)
    if swosbootCrc32(buf, SwosbootFormat.crcOffset) != stored { return nil }

    if Int(sbLoad32(buf, 16)) != SwosbootFormat.slotCount { return nil }
    let active = Int(sbLoad32(buf, 20))
    let fallback = Int(sbLoad32(buf, 24))
    if active < 0 || active >= SwosbootFormat.slotCount { return nil }
    if fallback < 0 || fallback >= SwosbootFormat.slotCount { return nil }

    let base = SwosbootFormat.slotTableOffset
    let stride = SwosbootFormat.slotEntrySize
    return SwosbootManifest(version: version,
                            activeSlot: active,
                            fallbackSlot: fallback,
                            sequence: sbLoad32(buf, 28),
                            slot0: readSwosbootSlot(buf, base),
                            slot1: readSwosbootSlot(buf, base + stride),
                            minSystemVersion: sbLoad64(buf, SwosbootFormat.minSystemVersionOffset))
}

// Little-endian byte writers (mirror the readers; byte-wise for +strict-align).
@inline(__always) private func sbStore8(_ p: UnsafeMutableRawPointer, _ o: Int, _ v: UInt8) {
    p.storeBytes(of: v, toByteOffset: o, as: UInt8.self)
}
@inline(__always) private func sbStore32(_ p: UnsafeMutableRawPointer, _ o: Int, _ v: UInt32) {
    sbStore8(p, o, UInt8(v & 0xFF)); sbStore8(p, o + 1, UInt8((v >> 8) & 0xFF))
    sbStore8(p, o + 2, UInt8((v >> 16) & 0xFF)); sbStore8(p, o + 3, UInt8((v >> 24) & 0xFF))
}
@inline(__always) private func sbStore64(_ p: UnsafeMutableRawPointer, _ o: Int, _ v: UInt64) {
    sbStore32(p, o, UInt32(v & 0xFFFF_FFFF)); sbStore32(p, o + 4, UInt32((v >> 32) & 0xFFFF_FFFF))
}

private func writeSwosbootSlot(_ p: UnsafeMutableRawPointer, _ o: Int, _ s: SwosbootSlot) {
    sbStore32(p, o + 0, s.present ? 1 : 0)
    sbStore32(p, o + 4, s.state)
    sbStore64(p, o + 8, s.baseLBA)
    sbStore64(p, o + 16, s.lengthSectors)
    sbStore32(p, o + 24, s.generation)
    sbStore32(p, o + 28, s.attemptCount)
    sbStore64(p, o + SwosbootFormat.slotSystemVersionOffset, s.systemVersion)
}

/// Serialize a manifest into a 512-byte sector buffer (with a fresh CRC32). The
/// exact inverse of parseSwosbootManifest, so parse(serialize(m)) == m. The
/// buffer must be at least SwosbootFormat.manifestSize bytes.
func serializeSwosbootManifest(_ m: SwosbootManifest, into buf: UnsafeMutableRawPointer) {
    var i = 0
    while i < SwosbootFormat.manifestSize { sbStore8(buf, i, 0); i += 1 }

    let magic: StaticString = "SWOSBOOT"
    magic.withUTF8Buffer { mm in
        var j = 0
        while j < 8 { sbStore8(buf, j, mm[j]); j += 1 }
    }
    sbStore32(buf, 8, m.version)
    sbStore32(buf, 16, UInt32(SwosbootFormat.slotCount))
    sbStore32(buf, 20, UInt32(m.activeSlot))
    sbStore32(buf, 24, UInt32(m.fallbackSlot))
    sbStore32(buf, 28, m.sequence)
    let base = SwosbootFormat.slotTableOffset
    writeSwosbootSlot(buf, base, m.slot0)
    writeSwosbootSlot(buf, base + SwosbootFormat.slotEntrySize, m.slot1)
    sbStore64(buf, SwosbootFormat.minSystemVersionOffset, m.minSystemVersion)
    let crc = swosbootCrc32(UnsafeRawPointer(buf), SwosbootFormat.crcOffset)
    sbStore32(buf, SwosbootFormat.crcOffset, crc)
}
