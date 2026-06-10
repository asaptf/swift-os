// SPDX-License-Identifier: Apache-2.0
// kernelboot.swift — build a SWOSKERN kernel A/B boot manifest for the ESP.
//
// The UEFI loader (boot/efi/loader.c) reads this file from
// \EFI\swift-os\kernel-boot to choose which kernel slot to load (kernelA.bin /
// kernelB.bin), falling back to the other slot if the active one is missing OR
// fails its SHA-256 (U1g-3a).
//
// Layout (little-endian):
//   0   u8[8] "SWOSKERN"
//   8   u32   version = 3          (v2 = per-slot SHA-256; v3 = + Ed25519 sig)
//   12  u32   active   (0 = slot A, 1 = slot B)
//   16  u32   fallback (0/1)
//   20  u32   generation
//   24  u64   slotA_size           32  u8[32] slotA_sha256
//   64  u64   slotB_size           72  u8[32] slotB_sha256   (104-byte body)
//   104 u8[64] Ed25519 signature over bytes [0,104)          (168 bytes total)
//
// The signature uses the image-signing key (the same root the kernel embeds);
// the loader verifies it against its compiled-in copy before trusting the slot
// selection. Host-authored at image build for now (no CRC / double-buffering —
// added when the OS writes it at runtime).
//
// Usage: kernelboot <out> <active:A|B> <kernelA-file> <kernelB-file> <signing-seed> [generation]

import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("kernelboot: \(message)\n".utf8))
    exit(1)
}

private func le32(_ v: UInt32) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
}
private func le64(_ v: UInt64) -> [UInt8] {
    (0..<8).map { UInt8((v >> ($0 * 8)) & 0xFF) }
}

private func sha256Of(_ data: Data) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 32)
    data.withUnsafeBytes { raw in
        out.withUnsafeMutableBytes { o in
            sha256(raw.baseAddress!, data.count, o.baseAddress!)
        }
    }
    return out
}

@main
struct KernelBootTool {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 6 || args.count == 7 else {
            fail("usage: kernelboot <out> <active:A|B> <kernelA-file> <kernelB-file> <signing-seed> [generation]")
        }
        let outPath = args[1]
        let activeArg = args[2].uppercased()
        guard activeArg == "A" || activeArg == "B" else { fail("active must be A or B") }
        let active: UInt32 = activeArg == "A" ? 0 : 1
        let fallback: UInt32 = 1 - active
        let generation: UInt32 = args.count == 7 ? (UInt32(args[6]) ?? 1) : 1

        guard let ka = FileManager.default.contents(atPath: args[3]) else { fail("cannot read \(args[3])") }
        guard let kb = FileManager.default.contents(atPath: args[4]) else { fail("cannot read \(args[4])") }
        guard let seed = FileManager.default.contents(atPath: args[5]), seed.count == 32 else {
            fail("signing seed \(args[5]) must be 32 bytes")
        }
        let hashA = sha256Of(ka)
        let hashB = sha256Of(kb)

        var body = [UInt8]()
        body.append(contentsOf: Array("SWOSKERN".utf8)) // 0
        body.append(contentsOf: le32(3))                // 8: version
        body.append(contentsOf: le32(active))           // 12
        body.append(contentsOf: le32(fallback))         // 16
        body.append(contentsOf: le32(generation))       // 20
        body.append(contentsOf: le64(UInt64(ka.count))) // 24: slotA_size
        body.append(contentsOf: hashA)                  // 32: slotA_sha256
        body.append(contentsOf: le64(UInt64(kb.count))) // 64: slotB_size
        body.append(contentsOf: hashB)                  // 72: slotB_sha256
        precondition(body.count == 104)

        // Ed25519 signature over the 104-byte body, image-signing key.
        var sig = [UInt8](repeating: 0, count: 64)
        body.withUnsafeBytes { msg in
            seed.withUnsafeBytes { sk in
                sig.withUnsafeMutableBytes { out in
                    ed25519Sign(message: msg.baseAddress!, 104, seed: sk.baseAddress!,
                                signature: out.baseAddress!)
                }
            }
        }

        var bytes = body
        bytes.append(contentsOf: sig)                   // 104: signature

        do {
            try Data(bytes).write(to: URL(fileURLWithPath: outPath))
        } catch {
            fail("\(error)")
        }
        let hexA = hashA.prefix(4).map { String(format: "%02x", $0) }.joined()
        print("kernelboot: wrote \(bytes.count) bytes (signed v3), active slot \(activeArg) "
            + "(gen \(generation)), slotA \(ka.count)B sha256 \(hexA).., slotB \(kb.count)B")
    }
}
