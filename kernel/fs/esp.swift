// SPDX-License-Identifier: Apache-2.0
// esp.swift — kernel read access to the EFI System Partition on the GPT boot disk.
//
// U1g-4a (read side): the UEFI loader reads the kernel A/B manifest + slot images
// from the ESP (\EFI\swift-os) on the firmware-boot disk. For the OS to stage a
// new kernel at runtime it must reach that same disk. The boot disk is attached
// on virtio-mmio (so both AAVMF and the kernel can drive it); virtio_blk picks it
// out by the "EFI PART" GPT header at LBA 1. This file parses the GPT to locate
// the ESP partition. FAT32 reading of the manifest, then writing, come next.
//
// No mutable global state here; reads go through the virtio_blk ESP detour
// (virtioBlkSelectEsp / virtioBlkReselectServed), serial on the single CPU.

// ESP partition type GUID C12A7328-F81F-11D2-BA4B-00A0C93EC93B, in GPT's
// mixed-endian on-disk form (first three fields little-endian).
private let espTypeGuid: InlineArray<16, UInt8> = [
    0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11,
    0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B,
]

@inline(__always) private func espLd32(_ p: UnsafeRawPointer, _ o: Int) -> UInt32 {
    UInt32(p.load(fromByteOffset: o, as: UInt8.self))
        | (UInt32(p.load(fromByteOffset: o + 1, as: UInt8.self)) << 8)
        | (UInt32(p.load(fromByteOffset: o + 2, as: UInt8.self)) << 16)
        | (UInt32(p.load(fromByteOffset: o + 3, as: UInt8.self)) << 24)
}
@inline(__always) private func espLd64(_ p: UnsafeRawPointer, _ o: Int) -> UInt64 {
    UInt64(espLd32(p, o)) | (UInt64(espLd32(p, o + 4)) << 32)
}

// Locate the ESP partition on the currently-selected ESP/GPT disk. Returns
// (firstLBA, sectorCount) or nil. The GPT header is at LBA 1; partition entries
// start at the header's partition-entry LBA.
private func espFindPartition() -> (UInt64, UInt64)? {
    var buf = InlineArray<512, UInt8>(repeating: 0)
    var entryLBA: UInt64 = 0
    var numEntries: UInt32 = 0
    var entrySize: UInt32 = 0
    var headerOK = false
    withUnsafeMutableBytes(of: &buf) { raw in
        let p = raw.baseAddress!
        if virtioBlkRead(1, p) != 0 { return }
        let magic: StaticString = "EFI PART"
        var ok = true
        magic.withUTF8Buffer { m in
            var i = 0
            while i < 8 { if p.load(fromByteOffset: i, as: UInt8.self) != m[i] { ok = false }; i += 1 }
        }
        if !ok { return }
        entryLBA = espLd64(UnsafeRawPointer(p), 72)
        numEntries = espLd32(UnsafeRawPointer(p), 80)
        entrySize = espLd32(UnsafeRawPointer(p), 84)
        headerOK = true
    }
    if !headerOK || entrySize < 128 || entrySize > 512 || numEntries == 0 || numEntries > 256 {
        return nil
    }

    // Walk the partition entries, one 512-byte sector at a time.
    let perSector = 512 / Int(entrySize)
    var result: (UInt64, UInt64)? = nil
    var scanned: UInt32 = 0
    var sector = entryLBA
    while scanned < numEntries && result == nil {
        withUnsafeMutableBytes(of: &buf) { raw in
            let p = raw.baseAddress!
            if virtioBlkRead(sector, p) != 0 { scanned = numEntries; return }
            var e = 0
            while e < perSector && scanned < numEntries {
                let off = e * Int(entrySize)
                var matches = true
                var k = 0
                while k < 16 {
                    if p.load(fromByteOffset: off + k, as: UInt8.self) != espTypeGuid[k] { matches = false }
                    k += 1
                }
                if matches {
                    let firstLBA = espLd64(UnsafeRawPointer(p), off + 32)
                    let lastLBA = espLd64(UnsafeRawPointer(p), off + 40)
                    if lastLBA >= firstLBA {
                        result = (firstLBA, lastLBA - firstLBA + 1)
                    }
                }
                e += 1
                scanned += 1
            }
        }
        sector += 1
    }
    return result
}

/// U1g-4a: at boot, if a GPT/ESP boot disk is attached on virtio-mmio, locate the
/// ESP partition and report it. A no-op when no such disk is present (e.g. the
/// `-kernel` path, where the kernel is loaded directly). Leaves the base/store
/// disk re-selected so subsequent base reads are unaffected.
func espProbe() {
    if !virtioBlkHasEsp() { return }
    let cap = virtioBlkSelectEsp()
    var found: (UInt64, UInt64)? = nil
    if cap != 0 { found = espFindPartition() }
    virtioBlkReselectServed()

    if let (lba, n) = found {
        uartPuts("kernel-store: ESP partition found at LBA ")
        uartPutUInt(lba)
        uartPuts(", ")
        uartPutUInt(n)
        uartPuts(" sectors (GPT boot disk reachable)\n")
    } else {
        uartPuts("kernel-store: GPT boot disk present but no ESP partition found\n")
    }
}
