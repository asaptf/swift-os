// SPDX-License-Identifier: Apache-2.0
// swpkg.swift - host-only swift-os package artifact tool (P1).

import Foundation

private let pkgMagic = Array("SWPKG001".utf8)
private let pkgVersion: UInt32 = 1
private let pkgHeaderSize: UInt32 = 128

private struct Header {
    let manifestOffset: UInt64
    let manifestSize: UInt64
    let payloadOffset: UInt64
    let payloadSize: UInt64
    let manifestHash: [UInt8]
    let payloadHash: [UInt8]
    let signatureOffset: UInt64
    let signatureSize: UInt64
}

private enum ToolError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("swpkg: \(message)\n".utf8))
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

private func shaHex(_ data: Data) -> String {
    shaBytes(data).map { String(format: "%02x", $0) }.joined()
}

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

private func json(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ToolError.message("manifest is not a JSON object")
    }
    return object
}

private func canon(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func str(_ object: [String: Any], _ key: String) -> String? {
    object[key] as? String
}

private func num(_ object: [String: Any], _ key: String) -> Int? {
    if let n = object[key] as? NSNumber { return n.intValue }
    if let n = object[key] as? Int { return n }
    return nil
}

private func validate(_ manifest: [String: Any]) throws {
    guard num(manifest, "format") ?? 1 == 1 else { throw ToolError.message("manifest format must be 1") }
    guard !(str(manifest, "name") ?? "").isEmpty else { throw ToolError.message("manifest name is empty") }
    guard !(str(manifest, "version") ?? "").isEmpty else { throw ToolError.message("manifest version is empty") }
    guard str(manifest, "arch") ?? "aarch64" == "aarch64" else { throw ToolError.message("manifest arch must be aarch64") }
    guard str(manifest, "target") ?? "swift-os" == "swift-os" else { throw ToolError.message("manifest target must be swift-os") }
    let abi = manifest["abi"] as? [String: Any] ?? [:]
    guard str(abi, "os") ?? "swos-0" == "swos-0" else { throw ToolError.message("abi.os must be swos-0") }
    guard str(abi, "linkage") ?? "static" == "static" else { throw ToolError.message("abi.linkage must be static") }
}

private func normalizedManifest(input: Data, image: PackedFSImage) throws -> [String: Any] {
    var manifest = try json(input)
    try validate(manifest)
    let name = str(manifest, "name") ?? ""
    manifest["format"] = num(manifest, "format") ?? 1
    manifest["revision"] = num(manifest, "revision") ?? 1
    manifest["arch"] = str(manifest, "arch") ?? "aarch64"
    manifest["target"] = str(manifest, "target") ?? "swift-os"
    manifest["license"] = manifest["license"] as? [String] ?? []
    manifest["depends"] = manifest["depends"] as? [[String: Any]] ?? []
    manifest["provides"] = manifest["provides"] as? [String] ?? [name]
    manifest["conflicts"] = manifest["conflicts"] as? [String] ?? []
    manifest["abi"] = manifest["abi"] as? [String: Any] ?? [
        "os": "swos-0", "syscall": 1, "libc": "newlib-4.6-swos", "linkage": "static",
    ]
    manifest["capabilities"] = manifest["capabilities"] as? [String: Any] ?? ["default": [], "services": []]
    manifest["files"] = image.entries.filter { $0.kind == swosPackedKindFile }.map {
        [
            "path": "/" + $0.path,
            "mode": String(format: "%04o", $0.mode),
            "sha256": shaHex($0.data),
            "size": $0.data.count,
        ] as [String: Any]
    }.sorted { ($0["path"] as! String) < ($1["path"] as! String) }
    return manifest
}

private func encodeHeader(_ h: Header) -> Data {
    var out = Data()
    out.append(contentsOf: pkgMagic)
    appendLE32(&out, pkgVersion)
    appendLE32(&out, pkgHeaderSize)
    appendLE64(&out, h.manifestOffset)
    appendLE64(&out, h.manifestSize)
    appendLE64(&out, h.payloadOffset)
    appendLE64(&out, h.payloadSize)
    out.append(contentsOf: h.manifestHash)
    out.append(contentsOf: h.payloadHash)
    appendLE64(&out, h.signatureOffset)
    appendLE64(&out, h.signatureSize)
    return out
}

private func decodeHeader(_ data: Data) throws -> Header {
    guard data.count >= Int(pkgHeaderSize) else { throw ToolError.message("package shorter than header") }
    guard Array(data[0..<8]) == pkgMagic else { throw ToolError.message("bad package magic") }
    guard try readLE32(data, 8) == pkgVersion, try readLE32(data, 12) == pkgHeaderSize else {
        throw ToolError.message("bad package header")
    }
    return Header(manifestOffset: try readLE64(data, 16),
                  manifestSize: try readLE64(data, 24),
                  payloadOffset: try readLE64(data, 32),
                  payloadSize: try readLE64(data, 40),
                  manifestHash: Array(data[48..<80]),
                  payloadHash: Array(data[80..<112]),
                  signatureOffset: try readLE64(data, 112),
                  signatureSize: try readLE64(data, 120))
}

private func checkedRange(offset: UInt64, size: UInt64, count: Int, label: String) throws -> Range<Int> {
    let (end, overflow) = offset.addingReportingOverflow(size)
    guard !overflow, offset <= UInt64(Int.max), end <= UInt64(Int.max) else {
        throw ToolError.message("\(label) out of bounds")
    }
    let start = Int(offset)
    let finish = Int(end)
    guard start <= finish, finish <= count else { throw ToolError.message("\(label) out of bounds") }
    return start..<finish
}

private func makePackage(manifestURL: URL, rootURL: URL) throws -> Data {
    let image = try buildPackedFS(root: rootURL,
                                  options: PackedFSBuildOptions(executablePathPrefixes: ["usr/bin/", "usr/sbin/", "usr/libexec/"]))
    for entry in image.entries where entry.path != "usr" && !entry.path.hasPrefix("usr/") {
        throw ToolError.message("package paths must live under /usr: /\(entry.path)")
    }
    let manifestData = try canon(normalizedManifest(input: try Data(contentsOf: manifestURL), image: image))
    let payloadOffset = UInt64(pkgHeaderSize) + UInt64(manifestData.count)
    let h = Header(manifestOffset: UInt64(pkgHeaderSize),
                   manifestSize: UInt64(manifestData.count),
                   payloadOffset: payloadOffset,
                   payloadSize: UInt64(image.data.count),
                   manifestHash: shaBytes(manifestData),
                   payloadHash: shaBytes(image.data),
                   signatureOffset: 0,
                   signatureSize: 0)
    var out = encodeHeader(h)
    out.append(manifestData)
    out.append(image.data)
    return out
}

private func readPackage(_ url: URL) throws -> (Header, Data, Data, [String: Any]) {
    let data = try Data(contentsOf: url)
    let h = try decodeHeader(data)
    guard h.signatureOffset == 0, h.signatureSize == 0 else {
        throw ToolError.message("package signatures are reserved for a later milestone")
    }
    guard h.manifestOffset == UInt64(pkgHeaderSize), h.payloadOffset == h.manifestOffset + h.manifestSize else {
        throw ToolError.message("bad package section order")
    }
    let mr = try checkedRange(offset: h.manifestOffset, size: h.manifestSize, count: data.count, label: "manifest")
    let pr = try checkedRange(offset: h.payloadOffset, size: h.payloadSize, count: data.count, label: "payload")
    let manifest = Data(data[mr])
    let payload = Data(data[pr])
    guard shaBytes(manifest) == h.manifestHash else { throw ToolError.message("manifest SHA-256 mismatch") }
    guard shaBytes(payload) == h.payloadHash else { throw ToolError.message("payload SHA-256 mismatch") }
    return (h, manifest, payload, try json(manifest))
}

private func verifyPackage(_ url: URL) throws -> [String: Any] {
    let (_, _, payloadData, manifest) = try readPackage(url)
    try validate(manifest)
    let image = try parsePackedFS(payloadData)
    let payloadFiles = Dictionary(uniqueKeysWithValues: image.entries.filter { $0.kind == swosPackedKindFile }.map { ("/" + $0.path, $0) })
    guard let files = manifest["files"] as? [[String: Any]], files.count == payloadFiles.count else {
        throw ToolError.message("manifest file count does not match payload")
    }
    for file in files {
        guard let path = file["path"] as? String, path.hasPrefix("/") else {
            throw ToolError.message("manifest file path must be absolute")
        }
        guard let entry = payloadFiles[path] else { throw ToolError.message("payload missing \(path)") }
        guard file["mode"] as? String == String(format: "%04o", entry.mode) else { throw ToolError.message("\(path) mode mismatch") }
        let size = (file["size"] as? NSNumber)?.intValue ?? file["size"] as? Int
        guard size == entry.data.count else { throw ToolError.message("\(path) size mismatch") }
        guard file["sha256"] as? String == shaHex(entry.data) else { throw ToolError.message("\(path) SHA-256 mismatch") }
    }
    return manifest
}

private func writeAtomically(_ data: Data, to output: URL) throws {
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try data.write(to: output, options: .atomic)
}

private func value(after flag: String, in args: [String]) throws -> String {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else {
        throw ToolError.message("missing \(flag)")
    }
    return args[i + 1]
}

private func usage() -> String {
    """
    usage:
      swpkg create --manifest <manifest.json> --root <root-dir> --output <out.swpkg>
      swpkg inspect <package.swpkg>
      swpkg verify <package.swpkg>
      swpkg extract-payload <package.swpkg> <payload.img>
    """
}

@main
struct SWPackageTool {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else { fail(usage()) }
        do {
            switch args[1] {
            case "create":
                let package = try makePackage(manifestURL: URL(fileURLWithPath: try value(after: "--manifest", in: args)),
                                              rootURL: URL(fileURLWithPath: try value(after: "--root", in: args)))
                let output = URL(fileURLWithPath: try value(after: "--output", in: args))
                try writeAtomically(package, to: output)
                print("created \(output.path)")
            case "inspect":
                guard args.count == 3 else { throw ToolError.message(usage()) }
                let (h, _, _, manifest) = try readPackage(URL(fileURLWithPath: args[2]))
                print("name: \(str(manifest, "name") ?? "")")
                print("version: \(str(manifest, "version") ?? "")")
                print("revision: \(num(manifest, "revision") ?? 0)")
                print("arch: \(str(manifest, "arch") ?? "")")
                print("target: \(str(manifest, "target") ?? "")")
                print("manifest_sha256: \(hex(h.manifestHash))")
                print("payload_sha256: \(hex(h.payloadHash))")
                print("files:")
                for file in (manifest["files"] as? [[String: Any]] ?? []).sorted(by: { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }) {
                    print("  \(file["path"] ?? "") \(file["mode"] ?? "") \(file["size"] ?? "") \(file["sha256"] ?? "")")
                }
            case "verify":
                guard args.count == 3 else { throw ToolError.message(usage()) }
                let manifest = try verifyPackage(URL(fileURLWithPath: args[2]))
                print("OK: \(str(manifest, "name") ?? "")-\(str(manifest, "version") ?? "")_\(num(manifest, "revision") ?? 0)")
            case "extract-payload":
                guard args.count == 4 else { throw ToolError.message(usage()) }
                let input = URL(fileURLWithPath: args[2])
                let manifest = try verifyPackage(input)
                let (_, _, payload, _) = try readPackage(input)
                let output = URL(fileURLWithPath: args[3])
                try writeAtomically(payload, to: output)
                print("extracted payload for \(str(manifest, "name") ?? "") to \(output.path)")
            default:
                throw ToolError.message(usage())
            }
        } catch {
            fail("\(error)")
        }
    }
}
