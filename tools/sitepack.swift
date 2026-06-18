// SPDX-License-Identifier: Apache-2.0
// sitepack.swift — host tool that packs a static site directory into a signed
// "SWSITE" bundle for reflash-free updates (SU-B), and verifies one.
//
// Bundle file = [64-byte Ed25519 signature over body][body]. The signature is
// the trust anchor: /bin/swupdate on the box verifies it against the baked
// site-signing public key before unpacking. The body additionally carries a
// SHA-256 over its payload region (entries+strings+blobs) as a cheap integrity
// cross-check (the signature already covers the whole body).
//
//   body layout (little-endian, matches userland/swupdate.swift):
//     off 0  magic "SWSITE01"            (8 bytes)
//     off 8  version u32  (= 1)
//     off 12 entryCount u32
//     off 16 stringsOff u32              (absolute offset within body)
//     off 20 stringsLen u32
//     off 24 blobsOff u32
//     off 28 blobsLen u32
//     off 32 payloadSha256               (32 bytes; SHA-256 of body[64..])
//     off 64 entries[entryCount]         (24 bytes each)
//              nameOff u32 (rel. to stringsOff), nameLen u32,
//              blobOff u32 (rel. to blobsOff),    blobLen u32,
//              type u32 (0=file, 1=dir),           mode u32
//     stringsOff: concatenated relative path names (e.g. "sub/note.txt")
//     blobsOff:   concatenated file contents
//
// Entries are emitted in pre-order (a directory precedes everything under it) so
// the unpacker can mkdir then write without splitting paths.

import Foundation

private let headerSize = 64
private let entrySize = 24
private let sigSize = 64
private let magic = Array("SWSITE01".utf8)
private let formatVersion: UInt32 = 1

private func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("sitepack: \(msg)\n".utf8))
    exit(1)
}

private struct Entry {
    let name: String      // relative path, '/'-separated
    let isDir: Bool
    let data: Data        // empty for dirs
}

private func appendLE32(_ d: inout Data, _ v: UInt32) {
    d.append(UInt8(v & 0xff))
    d.append(UInt8((v >> 8) & 0xff))
    d.append(UInt8((v >> 16) & 0xff))
    d.append(UInt8((v >> 24) & 0xff))
}

private func sha256Data(_ d: Data) -> Data {
    var out = [UInt8](repeating: 0, count: 32)
    out.withUnsafeMutableBytes { ob in
        if d.isEmpty {
            var dummy: UInt8 = 0
            sha256(&dummy, 0, ob.baseAddress!)
        } else {
            d.withUnsafeBytes { db in
                sha256(db.baseAddress!, d.count, ob.baseAddress!)
            }
        }
    }
    return Data(out)
}

// Pre-order walk: append a directory entry, then recurse into it; files inline.
private func collect(_ baseURL: URL, _ rel: String, _ out: inout [Entry]) {
    let dirPath = rel.isEmpty ? baseURL.path : baseURL.appendingPathComponent(rel).path
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dirPath) else {
        fail("cannot read directory \(dirPath)")
    }
    for name in names.sorted() {
        if name.hasPrefix(".") { continue }   // skip dotfiles (.DS_Store etc.)
        let childRel = rel.isEmpty ? name : rel + "/" + name
        let childURL = baseURL.appendingPathComponent(childRel)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: childURL.path, isDirectory: &isDir)
        if isDir.boolValue {
            out.append(Entry(name: childRel, isDir: true, data: Data()))
            collect(baseURL, childRel, &out)
        } else {
            guard let data = try? Data(contentsOf: childURL) else { fail("cannot read \(childURL.path)") }
            out.append(Entry(name: childRel, isDir: false, data: data))
        }
    }
}

private func buildBody(_ entries: [Entry]) -> Data {
    // String table + per-entry name offsets.
    var strings = Data()
    var nameOffsets = [UInt32]()
    for e in entries {
        nameOffsets.append(UInt32(strings.count))
        strings.append(contentsOf: Array(e.name.utf8))
    }
    // Blob region + per-entry blob offsets.
    var blobs = Data()
    var blobOffsets = [UInt32]()
    for e in entries {
        if e.isDir { blobOffsets.append(0) } else {
            blobOffsets.append(UInt32(blobs.count))
            blobs.append(e.data)
        }
    }

    let entriesSize = entries.count * entrySize
    let stringsOff = UInt32(headerSize + entriesSize)
    let blobsOff = stringsOff + UInt32(strings.count)

    var entriesData = Data()
    for (i, e) in entries.enumerated() {
        appendLE32(&entriesData, nameOffsets[i])
        appendLE32(&entriesData, UInt32(e.name.utf8.count))
        appendLE32(&entriesData, e.isDir ? 0 : blobOffsets[i])
        appendLE32(&entriesData, e.isDir ? 0 : UInt32(e.data.count))
        appendLE32(&entriesData, e.isDir ? 1 : 0)
        appendLE32(&entriesData, e.isDir ? 0o755 : 0o644)
    }

    var payload = Data()
    payload.append(entriesData)
    payload.append(strings)
    payload.append(blobs)
    let sha = sha256Data(payload)

    var header = Data()
    header.append(contentsOf: magic)
    appendLE32(&header, formatVersion)
    appendLE32(&header, UInt32(entries.count))
    appendLE32(&header, stringsOff)
    appendLE32(&header, UInt32(strings.count))
    appendLE32(&header, blobsOff)
    appendLE32(&header, UInt32(blobs.count))
    header.append(sha)   // 32 bytes -> header is exactly 64

    var body = Data()
    body.append(header)
    body.append(payload)
    return body
}

private func signBody(_ body: Data, seed: Data) -> Data {
    guard seed.count == 32 else { fail("seed must be 32 bytes, got \(seed.count)") }
    var sig = [UInt8](repeating: 0, count: sigSize)
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

private func value(after flag: String, in args: [String]) -> String {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else {
        fail("missing value for \(flag)")
    }
    return args[i + 1]
}

private func doCreate(_ args: [String]) {
    guard args.count >= 4 else { fail("usage: sitepack create <site-dir> <out.swsite> --seed <seed>") }
    let siteDir = args[2]
    let outPath = args[3]
    let seedPath = value(after: "--seed", in: args)
    guard let seed = try? Data(contentsOf: URL(fileURLWithPath: seedPath)) else {
        fail("cannot read seed \(seedPath)")
    }
    var entries = [Entry]()
    collect(URL(fileURLWithPath: siteDir), "", &entries)
    if entries.isEmpty { fail("site directory \(siteDir) is empty") }
    let body = buildBody(entries)
    let bundle = signBody(body, seed: seed)
    do {
        try bundle.write(to: URL(fileURLWithPath: outPath), options: .atomic)
    } catch {
        fail("cannot write \(outPath): \(error)")
    }
    let files = entries.filter { !$0.isDir }.count
    let dirs = entries.count - files
    print("sitepack: wrote \(outPath) (\(files) files, \(dirs) dirs, \(bundle.count) bytes)")
}

private func readLE32(_ d: Data, _ off: Int) -> UInt32 {
    UInt32(d[d.startIndex + off]) | (UInt32(d[d.startIndex + off + 1]) << 8)
        | (UInt32(d[d.startIndex + off + 2]) << 16) | (UInt32(d[d.startIndex + off + 3]) << 24)
}

private func doVerify(_ args: [String]) {
    guard args.count >= 3 else { fail("usage: sitepack verify <bundle.swsite> --pubkey <pub>") }
    let bundlePath = args[2]
    let pubPath = value(after: "--pubkey", in: args)
    guard let bundle = try? Data(contentsOf: URL(fileURLWithPath: bundlePath)) else {
        fail("cannot read bundle \(bundlePath)")
    }
    guard let pub = try? Data(contentsOf: URL(fileURLWithPath: pubPath)), pub.count == 32 else {
        fail("cannot read 32-byte pubkey \(pubPath)")
    }
    guard bundle.count > sigSize + headerSize else { fail("bundle too small") }
    let body = bundle.subdata(in: (bundle.startIndex + sigSize)..<bundle.endIndex)
    let sigOK = bundle.withUnsafeBytes { bb -> Bool in
        body.withUnsafeBytes { yb in
            pub.withUnsafeBytes { pb in
                ed25519Verify(message: yb.baseAddress!, body.count,
                              signature: bb.baseAddress!, publicKey: pb.baseAddress!)
            }
        }
    }
    guard Array(body.prefix(8)) == magic else { fail("bad magic") }
    let payload = body.subdata(in: (body.startIndex + headerSize)..<body.endIndex)
    let shaStored = Data(body.subdata(in: (body.startIndex + 32)..<(body.startIndex + 64)))
    let shaOK = sha256Data(payload) == shaStored
    print("signature: \(sigOK ? "OK" : "INVALID"), payload-sha256: \(shaOK ? "OK" : "INVALID")")
    exit(sigOK && shaOK ? 0 : 2)
}

@main
struct SitePack {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            fail("usage: sitepack create <site-dir> <out.swsite> --seed <seed> | verify <bundle> --pubkey <pub>")
        }
        switch args[1] {
        case "create": doCreate(args)
        case "verify": doVerify(args)
        default: fail("unknown command \(args[1])")
        }
    }
}
