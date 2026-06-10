// SPDX-License-Identifier: Apache-2.0
// pkgrepo.swift - static package repository builder for P5.

import Foundation

private let pkgMagic = Array("SWPKG001".utf8)
private let pkgHeaderSize: UInt32 = 128
private let signedHeaderSize = 64

private struct PackageEntry {
    let name: String
    let version: String
    let revision: Int
    let size: Int
    let sha256: String
    let url: String
}

private enum RepoError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("pkgrepo: \(message)\n".utf8))
    exit(1)
}

private func shaBytes(_ data: Data) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: sha256DigestLen)
    data.withUnsafeBytes { input in
        out.withUnsafeMutableBytes { output in
            let p = input.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!
            sha256(p, data.count, output.baseAddress!)
        }
    }
    return out
}

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

private func hexDecode(_ text: String) throws -> [UInt8] {
    let chars = Array(text.utf8)
    guard chars.count % 2 == 0 else { throw RepoError.message("hex string has odd length") }
    func nibble(_ c: UInt8) -> UInt8? {
        if c >= 0x30 && c <= 0x39 { return c - 0x30 }
        if c >= 0x61 && c <= 0x66 { return c - 0x61 + 10 }
        if c >= 0x41 && c <= 0x46 { return c - 0x41 + 10 }
        return nil
    }
    var out: [UInt8] = []
    var i = 0
    while i < chars.count {
        guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else {
            throw RepoError.message("hex string contains non-hex characters")
        }
        out.append((hi << 4) | lo)
        i += 2
    }
    return out
}

private func checkedRange(offset: UInt64, size: UInt64, count: Int, label: String) throws -> Range<Int> {
    let (end, overflow) = offset.addingReportingOverflow(size)
    if overflow || offset > UInt64(Int.max) || end > UInt64(Int.max) {
        throw RepoError.message("\(label) out of bounds")
    }
    let start = Int(offset)
    let finish = Int(end)
    if start > finish || finish > count {
        throw RepoError.message("\(label) out of bounds")
    }
    return start..<finish
}

private func json(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw RepoError.message("JSON is not an object")
    }
    return object
}

private func str(_ object: [String: Any], _ key: String) -> String? {
    object[key] as? String
}

private func num(_ object: [String: Any], _ key: String) -> Int? {
    if let n = object[key] as? NSNumber { return n.intValue }
    if let n = object[key] as? Int { return n }
    return nil
}

private func readPackage(_ path: String) throws -> (PackageEntry, Data) {
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    guard data.count >= Int(pkgHeaderSize) else { throw RepoError.message("package shorter than header") }
    guard Array(data[0..<8]) == pkgMagic else { throw RepoError.message("bad package magic") }
    guard try readLE32(data, 8) == 1, try readLE32(data, 12) == pkgHeaderSize else {
        throw RepoError.message("bad package header")
    }
    let manifestOffset = try readLE64(data, 16)
    let manifestSize = try readLE64(data, 24)
    let payloadOffset = try readLE64(data, 32)
    let payloadSize = try readLE64(data, 40)
    let manifestHash = Array(data[48..<80])
    let payloadHash = Array(data[80..<112])
    let signatureOffset = try readLE64(data, 112)
    let signatureSize = try readLE64(data, 120)
    guard signatureOffset == 0, signatureSize == 0 else {
        throw RepoError.message("package signatures are reserved")
    }
    guard manifestOffset == UInt64(pkgHeaderSize), payloadOffset == manifestOffset + manifestSize else {
        throw RepoError.message("bad package section order")
    }
    let mr = try checkedRange(offset: manifestOffset, size: manifestSize, count: data.count, label: "manifest")
    let pr = try checkedRange(offset: payloadOffset, size: payloadSize, count: data.count, label: "payload")
    let manifestData = Data(data[mr])
    let payload = Data(data[pr])
    guard shaBytes(manifestData) == manifestHash else { throw RepoError.message("manifest SHA-256 mismatch") }
    guard shaBytes(payload) == payloadHash else { throw RepoError.message("payload SHA-256 mismatch") }
    _ = try parsePackedFS(payload)

    let manifest = try json(manifestData)
    guard str(manifest, "arch") ?? "aarch64" == "aarch64" else {
        throw RepoError.message("manifest arch must be aarch64")
    }
    guard str(manifest, "target") ?? "swift-os" == "swift-os" else {
        throw RepoError.message("manifest target must be swift-os")
    }
    let abi = manifest["abi"] as? [String: Any] ?? [:]
    guard str(abi, "os") ?? "swos-0" == "swos-0" else {
        throw RepoError.message("abi.os must be swos-0")
    }
    guard str(abi, "linkage") ?? "static" == "static" else {
        throw RepoError.message("abi.linkage must be static")
    }
    guard let name = str(manifest, "name"), !name.isEmpty else {
        throw RepoError.message("manifest name is empty")
    }
    guard let version = str(manifest, "version"), !version.isEmpty else {
        throw RepoError.message("manifest version is empty")
    }
    let revision = num(manifest, "revision") ?? 1
    let digest = hex(shaBytes(data))
    let entry = PackageEntry(name: name, version: version, revision: revision,
                             size: data.count, sha256: digest,
                             url: "packages/\(digest).swpkg")
    return (entry, data)
}

private func catalogData(packages: [PackageEntry], generation: Int) throws -> Data {
    let packageObjects: [[String: Any]] = packages.sorted { $0.name < $1.name }.map {
        [
            "name": $0.name,
            "version": $0.version,
            "revision": $0.revision,
            "arch": "aarch64",
            "target": "swift-os",
            "abi": "swos-0",
            "linkage": "static",
            "sha256": $0.sha256,
            "size": $0.size,
            "url": $0.url,
            "depends": [],
        ] as [String: Any]
    }
    let object: [String: Any] = [
        "format": 1,
        "repository": "swift-os-current",
        "channel": "current",
        "generation": generation,
        "expires": 4_102_444_800, // 2100-01-01T00:00:00Z
        "root_key_id": "swos-test-root",
        "packages": packageObjects,
    ]
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
}

private func sign(_ data: Data, seed: [UInt8]) throws -> Data {
    guard seed.count == 32 else { throw RepoError.message("seed must be 32 bytes") }
    var sig = [UInt8](repeating: 0, count: signedHeaderSize)
    data.withUnsafeBytes { db in
        seed.withUnsafeBytes { sb in
            sig.withUnsafeMutableBytes { gb in
                ed25519Sign(message: db.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!,
                            data.count, seed: sb.baseAddress!, signature: gb.baseAddress!)
            }
        }
    }
    var out = Data(sig)
    out.append(data)
    return out
}

private func verifySignedCatalog(_ signed: Data, publicKey: Data) -> Bool {
    if signed.count <= signedHeaderSize || publicKey.count != 32 { return false }
    let sig = Data(signed[0..<signedHeaderSize])
    let body = Data(signed[signedHeaderSize..<signed.count])
    return sig.withUnsafeBytes { sb in
        body.withUnsafeBytes { bb in
            publicKey.withUnsafeBytes { pb in
                ed25519Verify(message: bb.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!,
                              body.count, signature: sb.baseAddress!, publicKey: pb.baseAddress!)
            }
        }
    }
}

private func value(after flag: String, in args: [String]) throws -> String {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else {
        throw RepoError.message("missing \(flag)")
    }
    return args[i + 1]
}

private func values(afterRepeated flag: String, in args: [String]) -> [String] {
    var out: [String] = []
    var i = 0
    while i < args.count {
        if args[i] == flag && i + 1 < args.count {
            out.append(args[i + 1])
            i += 2
        } else {
            i += 1
        }
    }
    return out
}

private func usage() -> String {
    """
    usage:
      pkgrepo pubkey --seed-hex HEX --output <pubkey>
      pkgrepo create --package <pkg.swpkg> [--package <pkg.swpkg> ...] --output <repo-dir> --seed-hex HEX [--generation N]
      pkgrepo verify --catalog-signed <catalog.signed> --pubkey <pubkey>
      pkgrepo inspect <catalog.signed>
    """
}

@main
struct PackageRepoTool {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else { fail(usage()) }
        do {
            switch args[1] {
            case "pubkey":
                let seed = try hexDecode(try value(after: "--seed-hex", in: args))
                guard seed.count == 32 else { throw RepoError.message("seed must be 32 bytes") }
                let output = URL(fileURLWithPath: try value(after: "--output", in: args))
                var pub = [UInt8](repeating: 0, count: 32)
                seed.withUnsafeBytes { sb in
                    pub.withUnsafeMutableBytes { pb in
                        ed25519PublicKey(seed: sb.baseAddress!, publicKey: pb.baseAddress!)
                    }
                }
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data(pub).write(to: output, options: .atomic)
                print("public_key: \(hex(pub))")

            case "create":
                let packagePaths = values(afterRepeated: "--package", in: args)
                if packagePaths.isEmpty { throw RepoError.message("at least one --package is required") }
                let output = URL(fileURLWithPath: try value(after: "--output", in: args), isDirectory: true)
                let seed = try hexDecode(try value(after: "--seed-hex", in: args))
                let generation = Int((try? value(after: "--generation", in: args)) ?? "1") ?? 1

                var packages: [PackageEntry] = []
                var blobs: [(String, Data)] = []
                for path in packagePaths {
                    let (entry, data) = try readPackage(path)
                    packages.append(entry)
                    blobs.append((entry.url, data))
                }
                if FileManager.default.fileExists(atPath: output.path) {
                    try FileManager.default.removeItem(at: output)
                }
                let channel = output.appendingPathComponent("aarch64/current", isDirectory: true)
                let packageDir = channel.appendingPathComponent("packages", isDirectory: true)
                try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)
                for (relative, data) in blobs {
                    try data.write(to: channel.appendingPathComponent(relative), options: .atomic)
                }
                let catalog = try catalogData(packages: packages, generation: generation)
                try catalog.write(to: channel.appendingPathComponent("catalog.json"), options: .atomic)
                try sign(catalog, seed: seed).write(to: channel.appendingPathComponent("catalog.signed"), options: .atomic)
                print("created \(channel.path)")

            case "verify":
                let catalog = try Data(contentsOf: URL(fileURLWithPath: try value(after: "--catalog-signed", in: args)))
                let pubkey = try Data(contentsOf: URL(fileURLWithPath: try value(after: "--pubkey", in: args)))
                let ok = verifySignedCatalog(catalog, publicKey: pubkey)
                print(ok ? "signature: OK" : "signature: INVALID")
                exit(ok ? 0 : 1)

            case "inspect":
                guard args.count == 3 else { throw RepoError.message(usage()) }
                let signed = try Data(contentsOf: URL(fileURLWithPath: args[2]))
                if signed.count <= signedHeaderSize { throw RepoError.message("signed catalog too short") }
                let body = Data(signed[signedHeaderSize..<signed.count])
                let object = try json(body)
                print("repository: \(str(object, "repository") ?? "?")")
                print("generation: \(num(object, "generation") ?? 0)")
                if let packages = object["packages"] as? [[String: Any]] {
                    print("packages:")
                    for pkg in packages {
                        let name = str(pkg, "name") ?? "?"
                        let version = str(pkg, "version") ?? "?"
                        let revision = num(pkg, "revision") ?? 0
                        print("  \(name)-\(version)_\(revision)")
                    }
                }

            default:
                throw RepoError.message(usage())
            }
        } catch {
            fail("\(error)")
        }
    }
}
