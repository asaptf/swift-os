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

// Build the SWSYS body (header + kernel || base). Mirrors sysbundle.swift offsets.
private func buildBody(kernel: Data, base: Data, version: UInt64) -> Data {
    let headerSize = 72
    let kernelOff = headerSize
    let baseOff = kernelOff + kernel.count

    var payload = Data()
    payload.append(kernel)
    payload.append(base)
    let sha = sha256Data(payload)

    var header = Data()
    header.append(contentsOf: Array("SWSYS001".utf8))   // off 0  (8 bytes)
    appendLE32(&header, 1)                               // off 8  formatVersion
    appendLE32(&header, 0)                               // off 12 flags (full)
    appendLE64(&header, version)                         // off 16 systemVersion
    appendLE32(&header, UInt32(kernelOff))               // off 24
    appendLE32(&header, UInt32(kernel.count))            // off 28
    appendLE32(&header, UInt32(baseOff))                 // off 32
    appendLE32(&header, UInt32(base.count))              // off 36
    header.append(sha)                                   // off 40 (32 bytes) -> header is 72
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
    // syspack create <kernel.bin> <base.img> <out.swsys> --version N --seed <seed>
    guard args.count >= 5 else {
        fail("usage: syspack create <kernel.bin> <base.img> <out.swsys> --version N --seed <seed>")
    }
    let kernelPath = args[2], basePath = args[3], outPath = args[4]
    guard let vStr = value(after: "--version", in: args), let version = UInt64(vStr) else {
        fail("missing/invalid --version N (monotonic, > 0)")
    }
    if version == 0 { fail("--version must be > 0 (0 is the anti-rollback floor)") }
    guard let seedPath = value(after: "--seed", in: args) else { fail("missing --seed <seed>") }
    guard let kernel = try? Data(contentsOf: URL(fileURLWithPath: kernelPath)), !kernel.isEmpty else {
        fail("cannot read kernel \(kernelPath)")
    }
    guard let base = try? Data(contentsOf: URL(fileURLWithPath: basePath)), !base.isEmpty else {
        fail("cannot read base image \(basePath)")
    }
    guard let seed = try? Data(contentsOf: URL(fileURLWithPath: seedPath)) else {
        fail("cannot read seed \(seedPath)")
    }
    let body = buildBody(kernel: kernel, base: base, version: version)
    let bundle = signBody(body, seed: seed)
    do { try bundle.write(to: URL(fileURLWithPath: outPath), options: .atomic) }
    catch { fail("cannot write \(outPath): \(error)") }
    print("syspack: wrote \(outPath) (version \(version), kernel \(kernel.count) B, base \(base.count) B, total \(bundle.count) B)")
}

private func describe(_ r: SysBundleVerify) -> (Int32, String) {
    switch r {
    case .ok(let h): return (0, "OK (version \(h.systemVersion), kernel \(h.kernelLen) B, base \(h.baseLen) B)")
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
