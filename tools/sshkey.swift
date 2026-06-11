// SPDX-License-Identifier: Apache-2.0
//
// sshkey.swift - host-side SSH key material helper for SwiftOS deploy proofs.

import Foundation

private enum SSHKeyError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sshkey: \(message)\n".utf8))
    exit(1)
}

private func value(after flag: String, in args: [String]) throws -> String {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else {
        throw SSHKeyError.message("missing \(flag)")
    }
    return args[i + 1]
}

private func optionalValue(after flag: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

private func hasFlag(_ flag: String, in args: [String]) -> Bool {
    args.contains(flag)
}

private func randomBytes(count: Int) throws -> [UInt8] {
    guard let fh = FileHandle(forReadingAtPath: "/dev/urandom") else {
        throw SSHKeyError.message("cannot open /dev/urandom")
    }
    defer {
        do { try fh.close() } catch {}
    }
    let data = fh.readData(ofLength: count)
    guard data.count == count else {
        throw SSHKeyError.message("short read from /dev/urandom")
    }
    return Array(data)
}

private func hexNibble(_ c: UInt8) -> UInt8? {
    if c >= 0x30 && c <= 0x39 { return c - 0x30 }
    if c >= 0x61 && c <= 0x66 { return c - 0x61 + 10 }
    if c >= 0x41 && c <= 0x46 { return c - 0x41 + 10 }
    return nil
}

private func isSeedSpace(_ c: UInt8) -> Bool {
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
}

private func decodeSeedHex(_ bytes: [UInt8]) throws -> [UInt8] {
    var out: [UInt8] = []
    var high: UInt8 = 0
    var haveHigh = false
    var i = 0
    while i < bytes.count {
        let c = bytes[i]
        if c == 0x23 {
            while i < bytes.count && bytes[i] != 0x0A { i += 1 }
            continue
        }
        if isSeedSpace(c) {
            i += 1
            continue
        }
        guard let n = hexNibble(c) else {
            throw SSHKeyError.message("seed contains non-hex data")
        }
        if haveHigh {
            out.append((high << 4) | n)
            haveHigh = false
        } else {
            high = n
            haveHigh = true
        }
        if out.count > 32 { throw SSHKeyError.message("seed is longer than 32 bytes") }
        i += 1
    }
    guard !haveHigh, out.count == 32 else {
        throw SSHKeyError.message("seed must decode to exactly 32 bytes")
    }
    return out
}

private func readSeed(args: [String]) throws -> [UInt8] {
    if let hex = optionalValue(after: "--seed-hex", in: args) {
        return try decodeSeedHex(Array(hex.utf8))
    }
    let path = try value(after: "--seed-file", in: args)
    guard let data = FileManager.default.contents(atPath: path) else {
        throw SSHKeyError.message("cannot read seed file \(path)")
    }
    return try decodeSeedHex(Array(data))
}

private func hexLine(_ bytes: [UInt8]) -> String {
    let table = Array("0123456789abcdef".utf8)
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count * 2 + 1)
    for b in bytes {
        out.append(table[Int(b >> 4)])
        out.append(table[Int(b & 0x0F)])
    }
    out.append(0x0A)
    return String(decoding: out, as: UTF8.self)
}

private func writeSeed(args: [String]) throws {
    let path = try value(after: "--out", in: args)
    let force = hasFlag("--force", in: args)
    let fm = FileManager.default
    if fm.fileExists(atPath: path) && !force {
        throw SSHKeyError.message("\(path) already exists; pass --force to replace it")
    }
    let url = URL(fileURLWithPath: path)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let line = hexLine(try randomBytes(count: 32))
    try Data(line.utf8).write(to: url, options: .atomic)
}

private func putU32BE(_ out: inout [UInt8], _ v: UInt32) {
    out.append(UInt8((v >> 24) & 0xFF))
    out.append(UInt8((v >> 16) & 0xFF))
    out.append(UInt8((v >> 8) & 0xFF))
    out.append(UInt8(v & 0xFF))
}

private func sshString(_ bytes: [UInt8], into out: inout [UInt8]) {
    putU32BE(&out, UInt32(bytes.count))
    out.append(contentsOf: bytes)
}

private func sshEd25519Blob(publicKey: [UInt8]) -> [UInt8] {
    var blob: [UInt8] = []
    sshString(Array("ssh-ed25519".utf8), into: &blob)
    sshString(publicKey, into: &blob)
    return blob
}

private let base64Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

private func base64(_ bytes: [UInt8]) -> String {
    var out: [UInt8] = []
    var i = 0
    while i < bytes.count {
        let b0 = bytes[i]
        let b1 = i + 1 < bytes.count ? bytes[i + 1] : 0
        let b2 = i + 2 < bytes.count ? bytes[i + 2] : 0
        out.append(base64Alphabet[Int(b0 >> 2)])
        out.append(base64Alphabet[Int(((b0 & 0x03) << 4) | (b1 >> 4))])
        out.append(i + 1 < bytes.count ? base64Alphabet[Int(((b1 & 0x0F) << 2) | (b2 >> 6))] : 0x3D)
        out.append(i + 2 < bytes.count ? base64Alphabet[Int(b2 & 0x3F)] : 0x3D)
        i += 3
    }
    return String(decoding: out, as: UTF8.self)
}

private func publicKey(fromSeed seed: [UInt8]) -> [UInt8] {
    var pub = [UInt8](repeating: 0, count: 32)
    seed.withUnsafeBytes { sb in
        pub.withUnsafeMutableBytes { pb in
            ed25519PublicKey(seed: sb.baseAddress!, publicKey: pb.baseAddress!)
        }
    }
    return pub
}

private func publicKeyLine(seed: [UInt8], comment: String?) -> String {
    let pub = publicKey(fromSeed: seed)
    let encoded = base64(sshEd25519Blob(publicKey: pub))
    if let comment, !comment.isEmpty {
        return "ssh-ed25519 \(encoded) \(comment)"
    }
    return "ssh-ed25519 \(encoded)"
}

private func usage() -> String {
    """
    usage:
      sshkey seed --out PATH [--force]
      sshkey pubkey --seed-file PATH [--comment TEXT]
      sshkey pubkey --seed-hex HEX [--comment TEXT]
      sshkey known-host --host HOST --seed-file PATH [--comment TEXT]
      sshkey known-host --host HOST --seed-hex HEX [--comment TEXT]
    """
}

@main
struct SSHKeyTool {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else { fail(usage()) }
        do {
            if args[1] == "seed" {
                try writeSeed(args: args)
                return
            }
            let seed = try readSeed(args: args)
            let comment = optionalValue(after: "--comment", in: args)
            switch args[1] {
            case "pubkey":
                print(publicKeyLine(seed: seed, comment: comment))
            case "known-host":
                let host = try value(after: "--host", in: args)
                print("\(host) \(publicKeyLine(seed: seed, comment: comment))")
            default:
                throw SSHKeyError.message("unknown subcommand \(args[1])")
            }
        } catch {
            fail(String(describing: error))
        }
    }
}
