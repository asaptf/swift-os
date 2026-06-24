// SPDX-License-Identifier: Apache-2.0
// syspack.swift — host tool that packs a kernel image + signed base image into a
// signed "SWSYS" system-update bundle for reflash-free OS updates (OS-2), and
// verifies / inspects one.
//
// The on-disk format (the trust anchor: Ed25519 signature over the body, plus a
// monotonic systemVersion) lives in the shared, I/O-free userland/lib/sysbundle.swift
// so the host packer and the on-box verifier (userland/swupdate.swift, OS-4) can
// never drift. This file owns only the host-side concerns: reading files, building
// the body, signing it (ed25519Sign), and the CLI.
//
//   bundle = [64-byte Ed25519 signature over body][body]   (see sysbundle.swift)

import Foundation

private func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("syspack: \(msg)\n".utf8))
    exit(1)
}

private func appendLE32(_ d: inout Data, _ v: UInt32) {
    d.append(UInt8(v & 0xff)); d.append(UInt8((v >> 8) & 0xff))
    d.append(UInt8((v >> 16) & 0xff)); d.append(UInt8((v >> 24) & 0xff))
}
private func appendLE64(_ d: inout Data, _ v: UInt64) {
    appendLE32(&d, UInt32(v & 0xffff_ffff)); appendLE32(&d, UInt32((v >> 32) & 0xffff_ffff))
}

private func sha256Data(_ d: Data) -> Data {
    var out = [UInt8](repeating: 0, count: 32)
    out.withUnsafeMutableBytes { ob in
        if d.isEmpty {
            var dummy: UInt8 = 0
            sha256(&dummy, 0, ob.baseAddress!)
        } else {
            d.withUnsafeBytes { db in sha256(db.baseAddress!, d.count, ob.baseAddress!) }
        }
    }
    return Data(out)
}

private func value(after flag: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

// Build a v4 SWOSKERN manifest (232 bytes) over the padded kernel slot image: an
// INDEPENDENT Ed25519 signature per slot over "SWOSKSLT"||u32 index||u64 size||
// sha256 (52 bytes), signed with the image-signing seed. Mirrors tools/kernelboot.swift
// and boot/efi/loader.c verify_slot_sig; the on-box installer (kernel/fs/esp.swift)
// re-verifies the sliced per-slot entry against image_trust_root before trusting it.
// Both slot entries cover the SAME padded image, so `swupdate os` can install into
// whichever slot is inactive using that slot's entry.
private func buildKernelManifest(paddedKernel: Data, seed: Data) -> Data {
    let sha = sha256Data(paddedKernel)
    let size = UInt64(paddedKernel.count)
    func slotSig(_ index: UInt32) -> Data {
        var msg = Data()
        msg.append(contentsOf: Array("SWOSKSLT".utf8))
        appendLE32(&msg, index)
        appendLE64(&msg, size)
        msg.append(sha)
        precondition(msg.count == 52, "per-slot message must be 52 bytes")
        var sig = [UInt8](repeating: 0, count: 64)
        sig.withUnsafeMutableBytes { gb in
            msg.withUnsafeBytes { mb in
                seed.withUnsafeBytes { sb in
                    ed25519Sign(message: mb.baseAddress!, 52, seed: sb.baseAddress!, signature: gb.baseAddress!)
                }
            }
        }
        return Data(sig)
    }
    var m = Data()
    m.append(contentsOf: Array("SWOSKERN".utf8))  // 0
    appendLE32(&m, 4)                              // 8  version (v4 per-slot)
    appendLE32(&m, 0)                              // 12 active   (default; kernel-state overrides)
    appendLE32(&m, 1)                              // 16 fallback
    appendLE32(&m, 1)                              // 20 generation
    appendLE64(&m, size)                           // 24  slotA size
    m.append(sha)                                  // 32  slotA sha256
    m.append(slotSig(0))                           // 64  slotA sig
    appendLE64(&m, size)                           // 128 slotB size
    m.append(sha)                                  // 136 slotB sha256
    m.append(slotSig(1))                           // 168 slotB sig
    precondition(m.count == 232, "v4 manifest must be 232 bytes")
    return m
}

// Build the SWSYS v2 body (header + padded kernel || base || kernel manifest).
// Mirrors sysbundle.swift offsets.
private func buildBody(kernel paddedKernel: Data, base: Data, manifest: Data, version: UInt64) -> Data {
    let headerSize = 80
    let kernelOff = headerSize
    let baseOff = kernelOff + paddedKernel.count
    let kmOff = baseOff + base.count

    var payload = Data()
    payload.append(paddedKernel)
    payload.append(base)
    payload.append(manifest)
    let sha = sha256Data(payload)

    var header = Data()
    header.append(contentsOf: Array("SWSYS001".utf8))   // off 0  (8 bytes)
    appendLE32(&header, 2)                               // off 8  formatVersion (v2)
    appendLE32(&header, 0)                               // off 12 flags (full)
    appendLE64(&header, version)                         // off 16 systemVersion
    appendLE32(&header, UInt32(kernelOff))               // off 24
    appendLE32(&header, UInt32(paddedKernel.count))      // off 28
    appendLE32(&header, UInt32(baseOff))                 // off 32
    appendLE32(&header, UInt32(base.count))              // off 36
    appendLE32(&header, UInt32(kmOff))                   // off 40
    appendLE32(&header, UInt32(manifest.count))          // off 44
    header.append(sha)                                   // off 48 (32 bytes) -> header is 80
    precondition(header.count == headerSize, "header must be \(headerSize) bytes")

    var body = Data()
    body.append(header)
    body.append(payload)
    return body
}

private func signBody(_ body: Data, seed: Data) -> Data {
    guard seed.count == 32 else { fail("seed must be 32 bytes, got \(seed.count)") }
    var sig = [UInt8](repeating: 0, count: 64)
    sig.withUnsafeMutableBytes { gb in
        body.withUnsafeBytes { bb in
            seed.withUnsafeBytes { sb in
                ed25519Sign(message: bb.baseAddress!, body.count,
                            seed: sb.baseAddress!, signature: gb.baseAddress!)
            }
        }
    }
    var out = Data(sig)
    out.append(body)
    return out
}

private func doCreate(_ args: [String]) {
    // syspack create <kernel.bin> <base.img> <out.swsys> --version N --seed <seed> [--slot-bytes N]
    guard args.count >= 5 else {
        fail("usage: syspack create <kernel.bin> <base.img> <out.swsys> --version N --seed <seed> [--slot-bytes N]")
    }
    let kernelPath = args[2], basePath = args[3], outPath = args[4]
    guard let vStr = value(after: "--version", in: args), let version = UInt64(vStr) else {
        fail("missing/invalid --version N (monotonic, > 0)")
    }
    if version == 0 { fail("--version must be > 0 (0 is the anti-rollback floor)") }
    guard let seedPath = value(after: "--seed", in: args) else { fail("missing --seed <seed>") }
    // The ESP kernel slot is a fixed size; the carried image is the kernel padded
    // to it (must match KERNEL_SLOT_BYTES so the on-box install hash matches).
    let slotBytes = Int(UInt64(value(after: "--slot-bytes", in: args) ?? "4194304") ?? 4194304)
    if slotBytes <= 0 { fail("--slot-bytes must be > 0") }
    guard let kernel = try? Data(contentsOf: URL(fileURLWithPath: kernelPath)), !kernel.isEmpty else {
        fail("cannot read kernel \(kernelPath)")
    }
    guard let base = try? Data(contentsOf: URL(fileURLWithPath: basePath)), !base.isEmpty else {
        fail("cannot read base image \(basePath)")
    }
    guard let seed = try? Data(contentsOf: URL(fileURLWithPath: seedPath)) else {
        fail("cannot read seed \(seedPath)")
    }
    if kernel.count > slotBytes { fail("kernel \(kernel.count) B exceeds the \(slotBytes) B slot") }
    var paddedKernel = kernel
    if paddedKernel.count < slotBytes {
        paddedKernel.append(Data(repeating: 0, count: slotBytes - paddedKernel.count))
    }
    let manifest = buildKernelManifest(paddedKernel: paddedKernel, seed: seed)
    let body = buildBody(kernel: paddedKernel, base: base, manifest: manifest, version: version)
    let bundle = signBody(body, seed: seed)
    do { try bundle.write(to: URL(fileURLWithPath: outPath), options: .atomic) }
    catch { fail("cannot write \(outPath): \(error)") }
    print("syspack: wrote \(outPath) (version \(version), kernel \(paddedKernel.count) B padded from \(kernel.count) B, base \(base.count) B, manifest \(manifest.count) B, total \(bundle.count) B)")
}

private func describe(_ r: SysBundleVerify) -> (Int32, String) {
    switch r {
    case .ok(let h): return (0, "OK (version \(h.systemVersion), kernel \(h.kernelLen) B, base \(h.baseLen) B, manifest \(h.kmanifestLen) B)")
    case .badSize: return (2, "INVALID: too small")
    case .badSignature: return (2, "INVALID: signature")
    case .badMagic: return (2, "INVALID: magic")
    case .badFormatVersion: return (2, "INVALID: format version")
    case .badLayout: return (2, "INVALID: layout out of bounds")
    case .badPayloadSha: return (2, "INVALID: payload sha256")
    case .tooOld: return (2, "REJECTED: version below the anti-rollback floor")
    }
}

private func doVerify(_ args: [String]) {
    // syspack verify <bundle.swsys> --pubkey <pub> [--min-version N]
    guard args.count >= 3 else { fail("usage: syspack verify <bundle.swsys> --pubkey <pub> [--min-version N]") }
    let bundlePath = args[2]
    guard let pubPath = value(after: "--pubkey", in: args) else { fail("missing --pubkey <pub>") }
    let minVersion = UInt64(value(after: "--min-version", in: args) ?? "0") ?? 0
    guard let bundle = try? Data(contentsOf: URL(fileURLWithPath: bundlePath)) else {
        fail("cannot read bundle \(bundlePath)")
    }
    guard let pub = try? Data(contentsOf: URL(fileURLWithPath: pubPath)), pub.count == 32 else {
        fail("cannot read 32-byte pubkey \(pubPath)")
    }
    let r = bundle.withUnsafeBytes { bb in
        pub.withUnsafeBytes { pb in
            verifySysBundle(bb.baseAddress!, bundle.count, publicKey: pb.baseAddress!, minVersion: minVersion)
        }
    }
    let (code, msg) = describe(r)
    print("syspack: \(msg)")
    exit(code)
}

@main
struct SysPack {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            fail("usage: syspack create <kernel.bin> <base.img> <out.swsys> --version N --seed <seed> | verify <bundle> --pubkey <pub> [--min-version N]")
        }
        switch args[1] {
        case "create": doCreate(args)
        case "verify": doVerify(args)
        default: fail("unknown command \(args[1])")
        }
    }
}
