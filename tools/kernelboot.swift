// SPDX-License-Identifier: Apache-2.0
// kernelboot.swift — build a SWOSKERN kernel A/B boot manifest for the ESP (U1g-2).
//
// The UEFI loader (boot/efi/loader.c) reads this file from
// \EFI\swift-os\kernel-boot to choose which kernel slot to load (kernelA.bin /
// kernelB.bin), falling back to the other slot if the active one is missing.
//
// Layout (little-endian), 24 bytes:
//   0  u8[8] "SWOSKERN"
//   8  u32   version = 1
//   12 u32   active   (0 = slot A, 1 = slot B)
//   16 u32   fallback (0/1)
//   20 u32   generation
//
// Host-authored at image build for now (no CRC); a CRC + double-buffering, as in
// the SWOSBOOT base-image store, will come once the OS writes it at runtime.
//
// Usage: kernelboot <out> <active:A|B> [generation]

import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("kernelboot: \(message)\n".utf8))
    exit(1)
}

private func le32(_ v: UInt32) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
}

let args = CommandLine.arguments
guard args.count == 3 || args.count == 4 else {
    fail("usage: kernelboot <out> <active:A|B> [generation]")
}
let outPath = args[1]
let activeArg = args[2].uppercased()
guard activeArg == "A" || activeArg == "B" else { fail("active must be A or B") }
let active: UInt32 = activeArg == "A" ? 0 : 1
let fallback: UInt32 = 1 - active
let generation: UInt32 = args.count == 4 ? (UInt32(args[3]) ?? 1) : 1

var bytes = [UInt8]()
bytes.append(contentsOf: Array("SWOSKERN".utf8)) // 0
bytes.append(contentsOf: le32(1))                // 8: version
bytes.append(contentsOf: le32(active))           // 12
bytes.append(contentsOf: le32(fallback))         // 16
bytes.append(contentsOf: le32(generation))       // 20

do {
    try Data(bytes).write(to: URL(fileURLWithPath: outPath))
} catch {
    fail("\(error)")
}
print("kernelboot: wrote \(bytes.count) bytes, active slot \(activeArg) (gen \(generation))")
