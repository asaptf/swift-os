// SPDX-License-Identifier: Apache-2.0
// kernelboot.swift — build a SWOSKERN kernel A/B boot manifest for the ESP.
//
// The UEFI loader (boot/efi/loader.c) reads this file from
// \EFI\swift-os\kernel-boot for trusted kernel-slot metadata (kernelA.bin /
// kernelB.bin sizes and hashes). The manifest's active slot is the default;
// mutable activation is stored in the loader-managed kernel-state file.
//
// Layout (little-endian):
//   0   u8[8] "SWOSKERN"
//   8   u32   version = 4          (v3 = one Ed25519 sig over both slots;
//                                   v4 = an INDEPENDENT Ed25519 sig PER slot)
//   12  u32   active   (0 = slot A, 1 = slot B)   — default; kernel-state overrides
//   16  u32   fallback (0/1)
//   20  u32   generation
//   24  u64   slotA_size    32  u8[32] slotA_sha256   64  u8[64] slotA_sig
//   128 u64   slotB_size   136  u8[32] slotB_sha256  168  u8[64] slotB_sig
//   232 bytes total
//
// OS-1c (Option A): each slot's signature is over a per-slot message
//   "SWOSKSLT" || u32 slot_index || u64 size || u8[32] sha256       (52 bytes)
// so a slot can be replaced independently — the box can install a new kernel into
// the inactive slot (writing that slot's host-signed entry from a SWSYS bundle)
// without re-signing, and the loader trusts each slot only if ITS signature is
// valid. The active/fallback/generation header is NOT signed: runtime selection
// lives in the (SHA-256-protected, self-managed) kernel-state, and flipping it can
// at worst boot the other still-signed slot or loop — a DoS, never a code-integrity
// bypass, matching the SWOSBOOT trust posture.
//
// The signature uses the image-signing key (the same root the kernel embeds);
// the loader verifies each slot against its compiled-in copy. Host-authored at
// image build for now.
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

        // Per-slot signed message: "SWOSKSLT" || u32 index || u64 size || sha256.
        // The loader reconstructs this identically before verifying the slot's sig.
        func slotSig(_ index: UInt32, _ size: Int, _ hash: [UInt8]) -> [UInt8] {
            var msg = [UInt8]()
            msg.append(contentsOf: Array("SWOSKSLT".utf8))
            msg.append(contentsOf: le32(index))
            msg.append(contentsOf: le64(UInt64(size)))
            msg.append(contentsOf: hash)
            precondition(msg.count == 52)
            var sig = [UInt8](repeating: 0, count: 64)
            msg.withUnsafeBytes { m in
                seed.withUnsafeBytes { sk in
                    sig.withUnsafeMutableBytes { out in
                        ed25519Sign(message: m.baseAddress!, 52, seed: sk.baseAddress!,
                                    signature: out.baseAddress!)
                    }
                }
            }
            return sig
        }
        let sigA = slotSig(0, ka.count, hashA)
        let sigB = slotSig(1, kb.count, hashB)

        var bytes = [UInt8]()
        bytes.append(contentsOf: Array("SWOSKERN".utf8))  // 0
        bytes.append(contentsOf: le32(4))                 // 8: version
        bytes.append(contentsOf: le32(active))            // 12
        bytes.append(contentsOf: le32(fallback))          // 16
        bytes.append(contentsOf: le32(generation))        // 20
        bytes.append(contentsOf: le64(UInt64(ka.count)))  // 24: slotA_size
        bytes.append(contentsOf: hashA)                   // 32: slotA_sha256
        bytes.append(contentsOf: sigA)                    // 64: slotA_sig
        bytes.append(contentsOf: le64(UInt64(kb.count)))  // 128: slotB_size
        bytes.append(contentsOf: hashB)                   // 136: slotB_sha256
        bytes.append(contentsOf: sigB)                    // 168: slotB_sig
        precondition(bytes.count == 232)

        do {
            try Data(bytes).write(to: URL(fileURLWithPath: outPath))
        } catch {
            fail("\(error)")
        }
        let hexA = hashA.prefix(4).map { String(format: "%02x", $0) }.joined()
        print("kernelboot: wrote \(bytes.count) bytes (signed v4, per-slot), active slot \(activeArg) "
            + "(gen \(generation)), slotA \(ka.count)B sha256 \(hexA).., slotB \(kb.count)B")
    }
}
