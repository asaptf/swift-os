// SPDX-License-Identifier: Apache-2.0
// pkgstore.swift - host-side package-store image builder (P3 bootstrap).

import Foundation

private let pkgMagic = Array("SWPKG001".utf8)
private let pkgHeaderSize: UInt32 = 128
private let storeMagic = Array("SWPKGST1".utf8)
private let recordMagic = Array("SWPSREC1".utf8)
private let activationMagic = Array("SWPACT01".utf8)
private let storeVersion: UInt32 = 1
private let storeHeaderSize: UInt32 = 512
private let recordHeaderSize: UInt32 = 128
private let recordKindPayload: UInt32 = 1
private let recordKindActivation: UInt32 = 2
private let recordKindActivePointer: UInt32 = 3
private let sectorSize = 512

private struct PackageInput {
    let name: String
    let version: String
    let revision: Int
    let payload: Data
    let payloadHash: [UInt8]
}

private struct Record {
    let kind: UInt32
    let generation: UInt64
    let name: String
    let version: String
    let data: Data
    let dataHash: [UInt8]
}

private enum StoreError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("pkgstore: \(message)\n".utf8))
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

private func alignUp(_ n: Int, _ align: Int) -> Int {
    (n + align - 1) & ~(align - 1)
}

private func appendPaddedString(_ out: inout Data, _ value: String, _ count: Int) throws {
    let bytes = Array(value.utf8)
    if bytes.count > count {
        throw StoreError.message("field too long: \(value)")
    }
    out.append(contentsOf: bytes)
    out.append(contentsOf: repeatElement(UInt8(0), count: count - bytes.count))
}

private func paddedString(_ data: Data, _ range: Range<Int>) -> String {
    let bytes = Array(data[range]).prefix { $0 != 0 }
    return String(decoding: bytes, as: UTF8.self)
}

private func checkedRange(offset: UInt64, size: UInt64, count: Int, label: String) throws -> Range<Int> {
    let (end, overflow) = offset.addingReportingOverflow(size)
    if overflow || offset > UInt64(Int.max) || end > UInt64(Int.max) {
        throw StoreError.message("\(label) out of bounds")
    }
    let start = Int(offset)
    let finish = Int(end)
    if start > finish || finish > count {
        throw StoreError.message("\(label) out of bounds")
    }
    return start..<finish
}

private func json(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw StoreError.message("manifest is not a JSON object")
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

private func readPackage(_ path: String) throws -> PackageInput {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard data.count >= Int(pkgHeaderSize) else { throw StoreError.message("package shorter than header") }
    guard Array(data[0..<8]) == pkgMagic else { throw StoreError.message("bad package magic") }
    guard try readLE32(data, 8) == 1, try readLE32(data, 12) == pkgHeaderSize else {
        throw StoreError.message("bad package header")
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
        throw StoreError.message("package signatures are reserved")
    }
    guard manifestOffset == UInt64(pkgHeaderSize), payloadOffset == manifestOffset + manifestSize else {
        throw StoreError.message("bad package section order")
    }
    let mr = try checkedRange(offset: manifestOffset, size: manifestSize, count: data.count, label: "manifest")
    let pr = try checkedRange(offset: payloadOffset, size: payloadSize, count: data.count, label: "payload")
    let manifestData = Data(data[mr])
    let payload = Data(data[pr])
    guard shaBytes(manifestData) == manifestHash else { throw StoreError.message("manifest SHA-256 mismatch") }
    guard shaBytes(payload) == payloadHash else { throw StoreError.message("payload SHA-256 mismatch") }
    _ = try parsePackedFS(payload)
    let manifest = try json(manifestData)
    guard str(manifest, "target") ?? "swift-os" == "swift-os" else {
        throw StoreError.message("manifest target must be swift-os")
    }
    guard str(manifest, "arch") ?? "aarch64" == "aarch64" else {
        throw StoreError.message("manifest arch must be aarch64")
    }
    let abi = manifest["abi"] as? [String: Any] ?? [:]
    guard str(abi, "linkage") ?? "static" == "static" else {
        throw StoreError.message("abi.linkage must be static")
    }
    guard let name = str(manifest, "name"), !name.isEmpty else {
        throw StoreError.message("manifest name is empty")
    }
    guard let version = str(manifest, "version"), !version.isEmpty else {
        throw StoreError.message("manifest version is empty")
    }
    return PackageInput(name: name, version: version, revision: num(manifest, "revision") ?? 1,
                        payload: payload, payloadHash: payloadHash)
}

private func activationData(packages: [PackageInput]) throws -> Data {
    var out = Data()
    out.append(contentsOf: activationMagic)
    appendLE32(&out, storeVersion)
    appendLE32(&out, UInt32(packages.count))
    for pkg in packages {
        out.append(contentsOf: pkg.payloadHash)
        try appendPaddedString(&out, pkg.name, 32)
        try appendPaddedString(&out, "\(pkg.version)_\(pkg.revision)", 16)
    }
    return out
}

private func recordHeader(_ record: Record, dataOffset: UInt64) throws -> Data {
    var out = Data()
    out.append(contentsOf: recordMagic)
    appendLE32(&out, storeVersion)
    appendLE32(&out, recordHeaderSize)
    appendLE32(&out, record.kind)
    appendLE32(&out, 0)
    appendLE64(&out, record.generation)
    appendLE64(&out, dataOffset)
    appendLE64(&out, UInt64(record.data.count))
    out.append(contentsOf: record.dataHash)
    try appendPaddedString(&out, record.name, 32)
    try appendPaddedString(&out, record.version, 16)
    precondition(out.count == Int(recordHeaderSize))
    return out
}

private func makeStore(packages: [PackageInput], generation: UInt64) throws -> Data {
    guard !packages.isEmpty else { throw StoreError.message("at least one --package is required") }
    var records: [Record] = packages.map {
        Record(kind: recordKindPayload, generation: 0, name: $0.name,
               version: "\($0.version)_\($0.revision)", data: $0.payload,
               dataHash: $0.payloadHash)
    }
    let act = try activationData(packages: packages)
    records.append(Record(kind: recordKindActivation, generation: generation, name: "activation",
                          version: "\(generation)", data: act, dataHash: shaBytes(act)))
    records.append(Record(kind: recordKindActivePointer, generation: generation, name: "active",
                          version: "\(generation)", data: Data(), dataHash: shaBytes(Data())))

    var out = Data()
    out.append(contentsOf: storeMagic)
    appendLE32(&out, storeVersion)
    appendLE32(&out, storeHeaderSize)
    appendLE64(&out, UInt64(storeHeaderSize))
    out.append(contentsOf: repeatElement(UInt8(0), count: Int(storeHeaderSize) - out.count))

    for record in records {
        let dataOffset = UInt64(out.count + Int(recordHeaderSize))
        out.append(try recordHeader(record, dataOffset: dataOffset))
        out.append(record.data)
        let padded = alignUp(out.count, sectorSize)
        if padded > out.count {
            out.append(contentsOf: repeatElement(UInt8(0), count: padded - out.count))
        }
    }
    return out
}

private func inspectStore(_ path: String) throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard data.count >= Int(storeHeaderSize) else { throw StoreError.message("store shorter than header") }
    guard Array(data[0..<8]) == storeMagic else { throw StoreError.message("bad store magic") }
    guard try readLE32(data, 8) == storeVersion, try readLE32(data, 12) == storeHeaderSize else {
        throw StoreError.message("bad store header")
    }
    var off = Int(try readLE64(data, 16))
    var active: UInt64 = 0
    var payloads: [(String, String, String, Int)] = []
    var activations: [UInt64] = []
    while off + Int(recordHeaderSize) <= data.count {
        if Array(data[off..<(off + 8)]) != recordMagic { break }
        let kind = try readLE32(data, off + 16)
        let generation = try readLE64(data, off + 24)
        let dataOffset = Int(try readLE64(data, off + 32))
        let dataSize = Int(try readLE64(data, off + 40))
        let hash = Array(data[(off + 48)..<(off + 80)])
        let name = paddedString(data, (off + 80)..<(off + 112))
        let version = paddedString(data, (off + 112)..<(off + 128))
        switch kind {
        case recordKindPayload:
            payloads.append((name, version, hex(hash), dataSize))
        case recordKindActivation:
            activations.append(generation)
        case recordKindActivePointer:
            active = generation
        default:
            break
        }
        if dataOffset < off + Int(recordHeaderSize) || dataOffset + dataSize > data.count {
            throw StoreError.message("record data out of bounds")
        }
        off = alignUp(dataOffset + dataSize, sectorSize)
    }
    print("active_generation: \(active)")
    print("payloads:")
    for p in payloads {
        print("  \(p.0)-\(p.1) \(p.3) \(p.2)")
    }
    print("activations:")
    for generation in activations {
        print("  \(generation)")
    }
}

private func value(after flag: String, in args: [String]) throws -> String {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else {
        throw StoreError.message("missing \(flag)")
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
      pkgstore create --package <pkg.swpkg> [--package <pkg.swpkg> ...] --output <store.img> [--generation N]
      pkgstore inspect <store.img>
    """
}

@main
struct PackageStoreTool {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else { fail(usage()) }
        do {
            switch args[1] {
            case "create":
                let pkgs = try values(afterRepeated: "--package", in: args).map { try readPackage($0) }
                let output = URL(fileURLWithPath: try value(after: "--output", in: args))
                let generationText = (try? value(after: "--generation", in: args)) ?? "1"
                guard let generation = UInt64(generationText) else {
                    throw StoreError.message("bad --generation")
                }
                let store = try makeStore(packages: pkgs, generation: generation)
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try store.write(to: output, options: Data.WritingOptions.atomic)
                print("created \(output.path)")
            case "inspect":
                guard args.count == 3 else { throw StoreError.message(usage()) }
                try inspectStore(args[2])
            default:
                throw StoreError.message(usage())
            }
        } catch {
            fail("\(error)")
        }
    }
}
