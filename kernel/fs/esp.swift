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
@inline(__always) private func espLd16(_ p: UnsafeRawPointer, _ o: Int) -> UInt32 {
    UInt32(p.load(fromByteOffset: o, as: UInt8.self))
        | (UInt32(p.load(fromByteOffset: o + 1, as: UInt8.self)) << 8)
}
@inline(__always) private func espLd8(_ p: UnsafeRawPointer, _ o: Int) -> UInt32 {
    UInt32(p.load(fromByteOffset: o, as: UInt8.self))
}
// ASCII upper-case for case-insensitive name comparison.
@inline(__always) private func espUpper(_ c: UInt8) -> UInt8 {
    (c >= 0x61 && c <= 0x7a) ? c - 0x20 : c
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

// --- FAT32 (read) on the ESP partition (U1g-4b) -----------------------------
// Minimal read-only FAT32: BPB, cluster→LBA, FAT chain, and a directory walk
// that matches a path component against either the assembled long (LFN) name or
// the reconstructed 8.3 short name, case-insensitively. Enough to read the small
// kernel A/B manifest the loader writes under \EFI\swift-os; a writer is U1g-4c.

private struct Fat32Vol {
    var partLBA: UInt64        // absolute LBA of the partition (FAT region origin)
    var secPerClus: UInt32
    var rsvd: UInt32           // reserved sectors (FAT starts here)
    var numFATs: UInt32
    var fatSz: UInt32          // sectors per FAT
    var firstDataSec: UInt32   // partition-relative first data sector
    var rootClus: UInt32
}

// Parse the FAT32 BPB at the partition's first sector. Returns nil if it is not a
// 512-byte-sector FAT32 volume.
private func fatReadBPB(_ partLBA: UInt64) -> Fat32Vol? {
    var buf = InlineArray<512, UInt8>(repeating: 0)
    var vol: Fat32Vol? = nil
    withUnsafeMutableBytes(of: &buf) { raw in
        let p = raw.baseAddress!
        if virtioBlkRead(partLBA, p) != 0 { return }
        let bytesPerSec = espLd16(UnsafeRawPointer(p), 11)
        let secPerClus = espLd8(UnsafeRawPointer(p), 13)
        let rsvd = espLd16(UnsafeRawPointer(p), 14)
        let numFATs = espLd8(UnsafeRawPointer(p), 16)
        let fatSz = espLd32(UnsafeRawPointer(p), 36)
        let rootClus = espLd32(UnsafeRawPointer(p), 44)
        if bytesPerSec != 512 || secPerClus == 0 || fatSz == 0 || rootClus < 2 { return }
        vol = Fat32Vol(partLBA: partLBA, secPerClus: secPerClus, rsvd: rsvd,
                       numFATs: numFATs, fatSz: fatSz,
                       firstDataSec: rsvd + numFATs * fatSz, rootClus: rootClus)
    }
    return vol
}

private func fatClusterLBA(_ v: Fat32Vol, _ clus: UInt32) -> UInt64 {
    v.partLBA + UInt64(v.firstDataSec) + UInt64(clus - 2) * UInt64(v.secPerClus)
}

// FAT32 next-cluster lookup; returns >= 0x0FFFFFF8 at end-of-chain (or on error).
private func fatNext(_ v: Fat32Vol, _ clus: UInt32) -> UInt32 {
    let byteOff = UInt64(clus) * 4
    let sec = v.partLBA + UInt64(v.rsvd) + byteOff / 512
    let within = Int(byteOff % 512)
    var buf = InlineArray<512, UInt8>(repeating: 0)
    var next: UInt32 = 0x0FFFFFFF
    withUnsafeMutableBytes(of: &buf) { raw in
        let p = raw.baseAddress!
        if virtioBlkRead(sec, p) != 0 { return }
        next = espLd32(UnsafeRawPointer(p), within) & 0x0FFFFFFF
    }
    return next
}

// Case-insensitive compare of `n` bytes at `a` to the target bytes.
private func fatNameEq(_ a: UnsafeRawPointer, _ alen: Int, _ target: UnsafePointer<UInt8>, _ tlen: Int) -> Bool {
    if alen != tlen { return false }
    var i = 0
    while i < alen {
        if espUpper(a.load(fromByteOffset: i, as: UInt8.self)) != espUpper(target[i]) { return false }
        i += 1
    }
    return true
}

// Find a directory child named `target` (tlen bytes) under directory cluster
// `startClus`. Returns (firstCluster, size, isDir) or nil. Matches LFN or 8.3.
private func fatFindChild(_ v: Fat32Vol, _ startClus: UInt32,
                          _ target: UnsafePointer<UInt8>, _ tlen: Int)
    -> (UInt32, UInt32, Bool)? {
    var lfn = InlineArray<260, UInt8>(repeating: 0)
    var lfnEnd = 0
    var lfnHas = false
    var lfnAscii = true
    var result: (UInt32, UInt32, Bool)? = nil
    var done = false

    var clus = startClus
    while clus >= 2 && clus < 0x0FFFFFF8 && !done {
        var s: UInt32 = 0
        while s < v.secPerClus && !done {
            var buf = InlineArray<512, UInt8>(repeating: 0)
            withUnsafeMutableBytes(of: &buf) { raw in
                let p = raw.baseAddress!
                if virtioBlkRead(fatClusterLBA(v, clus) + UInt64(s), p) != 0 { done = true; return }
                var e = 0
                while e < 16 {
                    let off = e * 32
                    let b0 = p.load(fromByteOffset: off, as: UInt8.self)
                    if b0 == 0x00 { done = true; return }      // end of directory
                    let attr = p.load(fromByteOffset: off + 11, as: UInt8.self)
                    if b0 == 0xE5 { lfnHas = false; lfnAscii = true; e += 1; continue }
                    if (attr & 0x0F) == 0x0F {                 // LFN fragment
                        let seq = Int(b0 & 0x1F)
                        if seq >= 1 && seq <= 20 {
                            // Byte offsets of the 13 UTF-16 chars within an LFN entry.
                            let slots: InlineArray<13, Int> = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]
                            var j = 0
                            while j < 13 {
                                let lo = p.load(fromByteOffset: off + slots[j], as: UInt8.self)
                                let hi = p.load(fromByteOffset: off + slots[j] + 1, as: UInt8.self)
                                let gi = (seq - 1) * 13 + j
                                if lo == 0x00 && hi == 0x00 {
                                    if !lfnHas || gi < lfnEnd || lfnEnd == 0 { lfnEnd = gi }
                                } else if !(lo == 0xFF && hi == 0xFF) {
                                    if hi != 0 { lfnAscii = false }
                                    if gi < 260 { lfn[gi] = lo }
                                    if gi + 1 > lfnEnd { lfnEnd = gi + 1 }
                                }
                                j += 1
                            }
                            lfnHas = true
                        }
                        e += 1
                        continue
                    }
                    if (attr & 0x08) != 0 { lfnHas = false; lfnAscii = true; e += 1; continue } // volume label

                    // A real 8.3 entry. Match the assembled LFN first, else the 8.3 name.
                    var matched = false
                    if lfnHas && lfnAscii {
                        withUnsafeBytes(of: lfn) { lb in
                            if fatNameEq(lb.baseAddress!, lfnEnd, target, tlen) { matched = true }
                        }
                    }
                    if !matched {
                        // Reconstruct "NAME[.EXT]" from the 8.3 field (trim spaces).
                        var name = InlineArray<13, UInt8>(repeating: 0)
                        var nl = 0
                        var k = 0
                        while k < 8 {
                            let c = p.load(fromByteOffset: off + k, as: UInt8.self)
                            if c != 0x20 { name[nl] = c; nl += 1 }
                            k += 1
                        }
                        var extLen = 0
                        var ext = InlineArray<3, UInt8>(repeating: 0)
                        k = 0
                        while k < 3 {
                            let c = p.load(fromByteOffset: off + 8 + k, as: UInt8.self)
                            if c != 0x20 { ext[extLen] = c; extLen += 1 }
                            k += 1
                        }
                        if extLen > 0 { name[nl] = 0x2E; nl += 1; var x = 0; while x < extLen { name[nl] = ext[x]; nl += 1; x += 1 } }
                        withUnsafeBytes(of: name) { nb in
                            if fatNameEq(nb.baseAddress!, nl, target, tlen) { matched = true }
                        }
                    }
                    if matched {
                        let hi = espLd16(UnsafeRawPointer(p), off + 20)
                        let lo = espLd16(UnsafeRawPointer(p), off + 26)
                        let first = (hi << 16) | lo
                        let size = espLd32(UnsafeRawPointer(p), off + 28)
                        result = (first, size, (attr & 0x10) != 0)
                        done = true
                        return
                    }
                    lfnHas = false; lfnAscii = true; lfnEnd = 0
                    e += 1
                }
            }
            s += 1
        }
        if !done { clus = fatNext(v, clus) }
    }
    return result
}

// Read the SWOSKERN kernel manifest from \EFI\swift-os\kernel-boot on the ESP
// partition. Returns (active slot, generation) or nil. The manifest is small
// (168 bytes), so its first cluster's first sector holds it.
// Find a child by a StaticString name under a directory cluster.
private func fatFind(_ vol: Fat32Vol, _ dirClus: UInt32, _ s: StaticString) -> (UInt32, UInt32, Bool)? {
    var r: (UInt32, UInt32, Bool)? = nil
    s.withUTF8Buffer { b in r = fatFindChild(vol, dirClus, b.baseAddress!, b.count) }
    return r
}

private func fatReadKernelManifest(_ partLBA: UInt64) -> (Int, UInt32)? {
    guard let vol = fatReadBPB(partLBA) else { return nil }
    guard let efi = fatFind(vol, vol.rootClus, "EFI"), efi.2 else { return nil }
    guard let sw = fatFind(vol, efi.0, "swift-os"), sw.2 else { return nil }
    guard let mf = fatFind(vol, sw.0, "kernel-boot"), !mf.2, mf.1 >= 24 else { return nil }

    var out: (Int, UInt32)? = nil
    var buf = InlineArray<512, UInt8>(repeating: 0)
    withUnsafeMutableBytes(of: &buf) { raw in
        let p = raw.baseAddress!
        if virtioBlkRead(fatClusterLBA(vol, mf.0), p) != 0 { return }
        let magic: StaticString = "SWOSKERN"
        var ok = true
        magic.withUTF8Buffer { m in var i = 0; while i < 8 { if p.load(fromByteOffset: i, as: UInt8.self) != m[i] { ok = false }; i += 1 } }
        if !ok { return }
        let active = espLd32(UnsafeRawPointer(p), 12)
        let gen = espLd32(UnsafeRawPointer(p), 20)
        if active <= 1 { out = (Int(active), gen) }
    }
    return out
}

// --- FAT32 in-place copy (write) on the ESP (U1g-4c) ------------------------
// Copy `totalSectors` from the src file's cluster chain to the dst file's chain,
// sector by sector (both walked in lockstep). In-place: the files are the same
// size, so no cluster allocation / FAT / directory changes — only data sectors
// are overwritten. Returns false on any read/write error or a short chain.
private func fatCopyChain(_ vol: Fat32Vol, _ srcStart: UInt32, _ dstStart: UInt32, _ totalSectors: Int) -> Bool {
    var sc = srcStart, dc = dstStart
    var done = 0
    while done < totalSectors {
        if sc < 2 || sc >= 0x0FFFFFF8 || dc < 2 || dc >= 0x0FFFFFF8 { return false }
        var s: UInt32 = 0
        var ok = true
        while s < vol.secPerClus && done < totalSectors && ok {
            var buf = InlineArray<512, UInt8>(repeating: 0)
            withUnsafeMutableBytes(of: &buf) { raw in
                let p = raw.baseAddress!
                if virtioBlkRead(fatClusterLBA(vol, sc) + UInt64(s), p) != 0 { ok = false; return }
                if virtioBlkWriteSector(fatClusterLBA(vol, dc) + UInt64(s), UnsafeRawPointer(p)) != 0 { ok = false; return }
            }
            s += 1; done += 1
        }
        if !ok { return false }
        sc = fatNext(vol, sc); dc = fatNext(vol, dc)
    }
    return true
}

// Re-read both chains and confirm every sector matches (write-back verify).
private func fatVerifyChain(_ vol: Fat32Vol, _ srcStart: UInt32, _ dstStart: UInt32, _ totalSectors: Int) -> Bool {
    var sc = srcStart, dc = dstStart
    var done = 0
    while done < totalSectors {
        if sc < 2 || sc >= 0x0FFFFFF8 || dc < 2 || dc >= 0x0FFFFFF8 { return false }
        var s: UInt32 = 0
        var ok = true
        while s < vol.secPerClus && done < totalSectors && ok {
            var a = InlineArray<512, UInt8>(repeating: 0)
            var b = InlineArray<512, UInt8>(repeating: 0)
            withUnsafeMutableBytes(of: &a) { ra in
                withUnsafeMutableBytes(of: &b) { rb in
                    let pa = ra.baseAddress!, pb = rb.baseAddress!
                    if virtioBlkRead(fatClusterLBA(vol, sc) + UInt64(s), pa) != 0 { ok = false; return }
                    if virtioBlkRead(fatClusterLBA(vol, dc) + UInt64(s), pb) != 0 { ok = false; return }
                    var i = 0
                    while i < 512 {
                        if pa.load(fromByteOffset: i, as: UInt8.self) != pb.load(fromByteOffset: i, as: UInt8.self) { ok = false; break }
                        i += 1
                    }
                }
            }
            if !ok { return false }
            s += 1; done += 1
        }
        sc = fatNext(vol, sc); dc = fatNext(vol, dc)
    }
    return true
}

private func espStageInner() -> Int {
    guard let (partLBA, _) = espFindPartition() else { return -2 }
    guard let vol = fatReadBPB(partLBA) else { return -5 }
    guard let efi = fatFind(vol, vol.rootClus, "EFI"), efi.2 else { return -2 }
    guard let sw = fatFind(vol, efi.0, "swift-os"), sw.2 else { return -2 }
    guard let ka = fatFind(vol, sw.0, "kernelA.bin"), !ka.2 else { return -2 }
    guard let kb = fatFind(vol, sw.0, "kernelB.bin"), !kb.2 else { return -2 }
    guard let mf = fatFind(vol, sw.0, "kernel-boot"), !mf.2 else { return -2 }
    if ka.1 == 0 || ka.1 != kb.1 { return -22 } // in-place copy needs equal sizes

    // Active slot from the (signed) manifest decides src (active) and dst (inactive).
    var active = -1
    var buf = InlineArray<512, UInt8>(repeating: 0)
    withUnsafeMutableBytes(of: &buf) { raw in
        let p = raw.baseAddress!
        if virtioBlkRead(fatClusterLBA(vol, mf.0), p) != 0 { return }
        let magic: StaticString = "SWOSKERN"
        var ok = true
        magic.withUTF8Buffer { m in var i = 0; while i < 8 { if p.load(fromByteOffset: i, as: UInt8.self) != m[i] { ok = false }; i += 1 } }
        if ok { active = Int(espLd32(UnsafeRawPointer(p), 12)) }
    }
    if active != 0 && active != 1 { return -22 }

    let srcClus = active == 0 ? ka.0 : kb.0
    let dstClus = active == 0 ? kb.0 : ka.0
    let totalSectors = Int((ka.1 + 511) / 512)

    if !fatCopyChain(vol, srcClus, dstClus, totalSectors) { return -5 }
    if virtioBlkFlush() != 0 { return -5 }
    if !fatVerifyChain(vol, srcClus, dstClus, totalSectors) { return -5 }
    return 0
}

// Read a SWOSKERN manifest file's active slot from its first cluster's first
// sector. Returns 0/1, or nil if the magic is wrong or the slot is out of range.
private func fatReadManifestActive(_ vol: Fat32Vol, _ firstClus: UInt32) -> Int? {
    var active = -1
    var buf = InlineArray<512, UInt8>(repeating: 0)
    withUnsafeMutableBytes(of: &buf) { raw in
        let p = raw.baseAddress!
        if virtioBlkRead(fatClusterLBA(vol, firstClus), p) != 0 { return }
        let magic: StaticString = "SWOSKERN"
        var ok = true
        magic.withUTF8Buffer { m in var i = 0; while i < 8 { if p.load(fromByteOffset: i, as: UInt8.self) != m[i] { ok = false }; i += 1 } }
        if ok { active = Int(espLd32(UnsafeRawPointer(p), 12)) }
    }
    return (active == 0 || active == 1) ? active : nil
}

// U1g-4d: flip the active kernel slot by copying the pre-signed alternate
// manifest (\EFI\swift-os\kernel-boot-alt, which selects the OTHER slot and was
// signed offline at image build) over the live kernel-boot, in place. Returns the
// new active slot (0/1) on success, or a negative errno-style code. The OS never
// signs — it only courier-copies an already-signed manifest, so the loader's
// signature gate is preserved.
private func espActivateInner() -> Int {
    guard let (partLBA, _) = espFindPartition() else { return -2 }
    guard let vol = fatReadBPB(partLBA) else { return -5 }
    guard let efi = fatFind(vol, vol.rootClus, "EFI"), efi.2 else { return -2 }
    guard let sw = fatFind(vol, efi.0, "swift-os"), sw.2 else { return -2 }
    guard let cur = fatFind(vol, sw.0, "kernel-boot"), !cur.2 else { return -2 }
    guard let alt = fatFind(vol, sw.0, "kernel-boot-alt"), !alt.2 else { return -2 }
    guard let curA = fatReadManifestActive(vol, cur.0) else { return -22 }
    guard let altA = fatReadManifestActive(vol, alt.0) else { return -22 }
    if altA == curA { return -22 } // the alternate must select the other slot

    // Copy the alternate manifest's first sector over the live manifest's.
    var ok = false
    var buf = InlineArray<512, UInt8>(repeating: 0)
    withUnsafeMutableBytes(of: &buf) { raw in
        let p = raw.baseAddress!
        if virtioBlkRead(fatClusterLBA(vol, alt.0), p) != 0 { return }
        if virtioBlkWriteSector(fatClusterLBA(vol, cur.0), UnsafeRawPointer(p)) != 0 { return }
        ok = true
    }
    if !ok { return -5 }
    if virtioBlkFlush() != 0 { return -5 }
    // Verify the live manifest now selects the alternate's slot.
    guard let newA = fatReadManifestActive(vol, cur.0), newA == altA else { return -5 }
    return newA
}

/// U1g-4d: activate the inactive kernel slot for the next boot by installing the
/// pre-signed alternate manifest. capConsole-gated. Returns 0 on success, or a
/// negative errno-style code. Invoked from EL0 via syscall 64 (/bin/swos-kactivate).
func espActivateOtherKernel() -> Int {
    if (processCurrentCaps() & capConsole) == 0 { return -1 } // EPERM
    if !virtioBlkHasEsp() { return -19 }
    if virtioBlkSelectEsp() == 0 { virtioBlkReselectServed(); return -19 }
    let r = espActivateInner()
    virtioBlkReselectServed()
    if r >= 0 {
        uartPuts("kernel-store: activated kernel slot ")
        uartPuts(r == 0 ? "A" : "B")
        uartPuts(" for next boot (signed manifest)\n")
        return 0
    }
    uartPuts("kernel-store: kernel activate failed rc ")
    uartPutUInt(UInt64(bitPattern: Int64(r)))
    uartPuts("\n")
    return r
}

/// U1g-4c: copy the ACTIVE kernel slot's image into the INACTIVE slot on the ESP,
/// in place (same-size files, no FAT/dir changes), and verify it. The write side
/// of runtime kernel staging — proves the kernel can rewrite the inactive slot
/// without touching the bootable one (a buggy write only spoils the inactive slot,
/// which the loader's hash check then rejects). capConsole-gated. Returns 0 or a
/// negative errno-style code. Invoked from EL0 via syscall 63 (/bin/swos-kstage).
func espStageActiveToInactive() -> Int {
    if (processCurrentCaps() & capConsole) == 0 { return -1 } // EPERM
    if !virtioBlkHasEsp() { return -19 }                      // ENODEV: no ESP/GPT disk
    if virtioBlkSelectEsp() == 0 { virtioBlkReselectServed(); return -19 }
    let rc = espStageInner()
    virtioBlkReselectServed()
    if rc == 0 {
        uartPuts("kernel-store: staged active slot image into inactive slot, verified (FAT32)\n")
    } else {
        uartPuts("kernel-store: stage to inactive slot failed rc ")
        uartPutUInt(UInt64(bitPattern: Int64(rc)))
        uartPuts("\n")
    }
    return rc
}

/// U1g-4a/4b: at boot, if a GPT/ESP boot disk is attached on virtio-mmio, locate
/// the ESP partition and read the kernel A/B manifest the loader uses. A no-op
/// when no such disk is present (e.g. the `-kernel` path). Leaves the base/store
/// disk re-selected so subsequent base reads are unaffected.
func espProbe() {
    if !virtioBlkHasEsp() { return }
    let cap = virtioBlkSelectEsp()
    var part: (UInt64, UInt64)? = nil
    var manifest: (Int, UInt32)? = nil
    if cap != 0 {
        part = espFindPartition()
        if let (lba, _) = part { manifest = fatReadKernelManifest(lba) }
    }
    virtioBlkReselectServed()

    guard let (lba, n) = part else {
        uartPuts("kernel-store: GPT boot disk present but no ESP partition found\n")
        return
    }
    uartPuts("kernel-store: ESP partition found at LBA ")
    uartPutUInt(lba)
    uartPuts(", ")
    uartPutUInt(n)
    uartPuts(" sectors\n")
    if let (active, gen) = manifest {
        uartPuts("kernel-store: ESP kernel A/B active slot ")
        uartPuts(active == 0 ? "A" : "B")
        uartPuts(" gen ")
        uartPutUInt(UInt64(gen))
        uartPuts(" (read from FAT32)\n")
    } else {
        uartPuts("kernel-store: ESP kernel-boot manifest not readable\n")
    }
}
