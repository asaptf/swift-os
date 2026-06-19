// SPDX-License-Identifier: Apache-2.0
// updatestore.swift — build a SWOSBOOT A/B update-store disk image (U1a).
//
// Lays out a writable virtio-blk "update store" disk:
//
//   LBA 0     : SWOSBOOT manifest, copy 0
//   LBA 1     : SWOSBOOT manifest, copy 1 (identical; double-buffer slot for U1b)
//   LBA 2..7  : reserved (manifest region padded to 4 KiB)
//   LBA 8     : slot 0 image  (a full signed SWOSBASE-v3 base image)
//   LBA 8+|A| : slot 1 image
//
// Each slot holds a complete base image (the same artifact `basepack` produces),
// so the kernel mounts and verifies it through the unchanged I8 path; this tool
// neither signs nor hashes — slot authenticity rides on the image's own Ed25519
// signature. The manifest records which slot is active and which is the
// known-good fallback, plus a CRC32 the kernel checks before trusting it.
//
// Usage: updatestore <out.img> <active:A|B> <slot-A-image> <slot-B-image>
//
// The manifest format and CRC come from the shared kernel/fs/swosboot.swift, so
// the bytes this writes are exactly what the kernel parses.

import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("updatestore: \(message)\n".utf8))
    exit(1)
}

private let SECTOR = 512
private let MANIFEST_SECTORS = 8 // manifest region padded to 4 KiB; slots follow

private func sectors(_ byteCount: Int) -> Int { (byteCount + SECTOR - 1) / SECTOR }

private func putLE32(_ buf: inout [UInt8], _ off: Int, _ v: UInt32) {
    buf[off + 0] = UInt8(v & 0xFF)
    buf[off + 1] = UInt8((v >> 8) & 0xFF)
    buf[off + 2] = UInt8((v >> 16) & 0xFF)
    buf[off + 3] = UInt8((v >> 24) & 0xFF)
}

private func putLE64(_ buf: inout [UInt8], _ off: Int, _ v: UInt64) {
    putLE32(&buf, off, UInt32(v & 0xFFFF_FFFF))
    putLE32(&buf, off + 4, UInt32((v >> 32) & 0xFFFF_FFFF))
}

// Build the 512-byte manifest sector for two slots placed at the given LBAs.
private func buildManifest(active: Int, fallback: Int,
                           slot0LBA: UInt64, slot0Sectors: UInt64, slot0Gen: UInt32,
                           slot1LBA: UInt64, slot1Sectors: UInt64, slot1Gen: UInt32,
                           sequence: UInt32, minSystemVersion: UInt64 = 0,
                           slot0Version: UInt64 = 0, slot1Version: UInt64 = 0) -> [UInt8] {
    var m = [UInt8](repeating: 0, count: SwosbootFormat.manifestSize)
    let magic = Array("SWOSBOOT".utf8)
    for i in 0..<8 { m[i] = magic[i] }
    putLE32(&m, 8, SwosbootFormat.version)
    putLE32(&m, 12, 0) // flags
    putLE32(&m, 16, UInt32(SwosbootFormat.slotCount))
    putLE32(&m, 20, UInt32(active))
    putLE32(&m, 24, UInt32(fallback))
    putLE32(&m, 28, sequence)
    // OS-3: anti-rollback floor (default 0). Slot system_version fields stay 0;
    // the kernel records them when it stages a versioned image.
    putLE64(&m, SwosbootFormat.minSystemVersionOffset, minSystemVersion)

    func writeSlot(_ index: Int, lba: UInt64, len: UInt64, gen: UInt32, version: UInt64) {
        let o = SwosbootFormat.slotTableOffset + index * SwosbootFormat.slotEntrySize
        putLE32(&m, o + 0, 1)                              // present
        putLE32(&m, o + 4, SwosbootFormat.stateUntried)    // state (U1b)
        putLE64(&m, o + 8, lba)                            // base_lba
        putLE64(&m, o + 16, len)                           // length_sectors
        putLE32(&m, o + 24, gen)                           // generation
        putLE32(&m, o + 28, 0)                             // attempt_count (U1b)
        putLE64(&m, o + SwosbootFormat.slotSystemVersionOffset, version) // system_version (OS-3)
    }
    writeSlot(0, lba: slot0LBA, len: slot0Sectors, gen: slot0Gen, version: slot0Version)
    writeSlot(1, lba: slot1LBA, len: slot1Sectors, gen: slot1Gen, version: slot1Version)

    let crc = m.withUnsafeBytes { swosbootCrc32($0.baseAddress!, SwosbootFormat.crcOffset) }
    putLE32(&m, SwosbootFormat.crcOffset, crc)
    return m
}

@main
struct UpdateStoreTool {
    static func main() {
        let args = CommandLine.arguments
        let usageStr = "usage: updatestore <out.img> <active:A|B> <slot-A-image> <slot-B-image>"
            + " [--min-version N] [--slot-a-version N] [--slot-b-version N]"
        guard args.count >= 5 else { fail(usageStr) }
        // Optional `--flag N` pairs after the four positional args (OS-3/OS-5).
        var minSystemVersion: UInt64 = 0
        var slot0Version: UInt64 = 0
        var slot1Version: UInt64 = 0
        var i = 5
        while i < args.count {
            guard i + 1 < args.count, let v = UInt64(args[i + 1]) else { fail(usageStr) }
            switch args[i] {
            case "--min-version": minSystemVersion = v
            case "--slot-a-version": slot0Version = v
            case "--slot-b-version": slot1Version = v
            default: fail(usageStr)
            }
            i += 2
        }
        let outPath = args[1]
        let activeArg = args[2].uppercased()
        guard activeArg == "A" || activeArg == "B" else { fail("active must be A or B") }
        let active = activeArg == "A" ? 0 : 1
        let fallback = 1 - active

        guard let imgA = FileManager.default.contents(atPath: args[3]) else {
            fail("cannot read slot-A image \(args[3])")
        }
        guard let imgB = FileManager.default.contents(atPath: args[4]) else {
            fail("cannot read slot-B image \(args[4])")
        }

        let slot0LBA = UInt64(MANIFEST_SECTORS)
        let slot0Sectors = UInt64(sectors(imgA.count))
        let slot1LBA = slot0LBA + slot0Sectors
        let slot1Sectors = UInt64(sectors(imgB.count))

        // Generations: slot A is gen 1, slot B is gen 2 (B is the "newer" slot
        // in the demo so a switch to B exercises selection, then fallback to A).
        let manifest = buildManifest(active: active, fallback: fallback,
                                     slot0LBA: slot0LBA, slot0Sectors: slot0Sectors, slot0Gen: 1,
                                     slot1LBA: slot1LBA, slot1Sectors: slot1Sectors, slot1Gen: 2,
                                     sequence: 1, minSystemVersion: minSystemVersion,
                                     slot0Version: slot0Version, slot1Version: slot1Version)

        // Self-check: the bytes we wrote must parse back through the shared core.
        let parsed = manifest.withUnsafeBytes {
            parseSwosbootManifest($0.baseAddress!, SwosbootFormat.manifestSize)
        }
        guard let p = parsed, p.activeSlot == active, p.fallbackSlot == fallback else {
            fail("internal error: manifest failed self-parse")
        }

        var image = Data()
        manifest.withUnsafeBytes { image.append(contentsOf: $0) } // copy 0 @ LBA 0
        manifest.withUnsafeBytes { image.append(contentsOf: $0) } // copy 1 @ LBA 1
        // Pad the manifest region out to MANIFEST_SECTORS.
        image.append(Data(repeating: 0, count: (MANIFEST_SECTORS - 2) * SECTOR))
        // Slot 0 image, padded to a sector boundary.
        image.append(imgA)
        if imgA.count % SECTOR != 0 {
            image.append(Data(repeating: 0, count: SECTOR - imgA.count % SECTOR))
        }
        // Slot 1 image, padded to a sector boundary.
        image.append(imgB)
        if imgB.count % SECTOR != 0 {
            image.append(Data(repeating: 0, count: SECTOR - imgB.count % SECTOR))
        }

        do {
            let url = URL(fileURLWithPath: outPath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try image.write(to: url, options: .atomic)
        } catch {
            fail("\(error)")
        }
        print("updatestore: wrote \(image.count) bytes, active slot \(activeArg) "
            + "(slot0 @ LBA \(slot0LBA) \(slot0Sectors)s, slot1 @ LBA \(slot1LBA) \(slot1Sectors)s)")
    }
}
