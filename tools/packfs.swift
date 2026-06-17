// SPDX-License-Identifier: Apache-2.0
// packfs.swift - host helpers for swift-os packed read-only filesystem images.

import Foundation

let swosPackedMagic = Array("SWOSBASE".utf8)
let swosPackedVersion: UInt32 = 2
// I8: version 3 is the signed layout — each entry carries a 32-byte SHA-256 of
// its file data (zero for directories), and a 64-byte Ed25519 signature over
// [header | entries | strings] sits between the string table and the payload.
// swpkg payloads stay on version 2 (SWPKG_FORMAT.md); the base image is v3.
let swosPackedVersionSigned: UInt32 = 3
let swosPackedHeaderSize: UInt32 = 64
let swosPackedEntrySize: UInt32 = 40
let swosPackedEntrySizeSigned: UInt32 = 72
let swosPackedSignatureSize = 64
let swosPackedKindDir: UInt32 = 1
let swosPackedKindFile: UInt32 = 2
let swosPackedRootOwner: UInt32 = 1

struct PackedFSEntry {
    let path: String
    let kind: UInt32
    let mode: UInt32
    let owner: UInt32
    let data: Data
}

// Octal 4000 (Unix S_ISUID). A file packed with this bit is honored as
// setuid-on-exec by the kernel (only for read-only base-image files); see
// kernel/security/security.swift `modeSetuid`.
let swosPackedSetuidBit: UInt32 = 0o4000

struct PackedFSBuildOptions {
    var defaultOwner: UInt32 = swosPackedRootOwner
    var executablePathPrefixes: [String] = ["bin/", "sbin/", "usr/bin/", "usr/sbin/", "usr/local/bin/"]
    // Base-image binaries to mark setuid-root. `/bin/sudo` elevates the invoker
    // to the owner (root) on exec, then re-authenticates and applies the
    // /etc/swos/sudoers policy in userland.
    var setuidPaths: [String] = ["bin/sudo"]
}

struct PackedFSImage {
    let entries: [PackedFSEntry]
    let data: Data
}

func appendLE32(_ out: inout Data, _ value: UInt32) {
    var v = value.littleEndian
    withUnsafeBytes(of: &v) { out.append(contentsOf: $0) }
}

func appendLE64(_ out: inout Data, _ value: UInt64) {
    var v = value.littleEndian
    withUnsafeBytes(of: &v) { out.append(contentsOf: $0) }
}

func readLE32(_ data: Data, _ off: Int) throws -> UInt32 {
    guard off >= 0 && off + 4 <= data.count else { throw PackedFSError.truncated("u32") }
    return UInt32(data[off]) |
        (UInt32(data[off + 1]) << 8) |
        (UInt32(data[off + 2]) << 16) |
        (UInt32(data[off + 3]) << 24)
}

func readLE64(_ data: Data, _ off: Int) throws -> UInt64 {
    guard off >= 0 && off + 8 <= data.count else { throw PackedFSError.truncated("u64") }
    var value: UInt64 = 0
    for i in 0..<8 {
        value |= UInt64(data[off + i]) << UInt64(i * 8)
    }
    return value
}

enum PackedFSError: Error, CustomStringConvertible {
    case notDirectory(String)
    case cannotEnumerate(String)
    case emptyTree(String)
    case nonUTF8Path(String)
    case pathTooLong(String)
    case truncated(String)
    case badMagic(String)
    case badVersion(UInt32)
    case badLayout
    case outOfBounds(String)

    var description: String {
        switch self {
        case .notDirectory(let path): return "input root is not a directory: \(path)"
        case .cannotEnumerate(let path): return "cannot enumerate \(path)"
        case .emptyTree(let path): return "input root has no entries: \(path)"
        case .nonUTF8Path(let path): return "non-UTF8 path: \(path)"
        case .pathTooLong(let path): return "path too long: \(path)"
        case .truncated(let what): return "packed image shorter than \(what)"
        case .badMagic(let magic): return "bad packed image magic \(magic)"
        case .badVersion(let version): return "bad packed image version \(version)"
        case .badLayout: return "unexpected packed image layout"
        case .outOfBounds(let what): return "\(what) out of bounds"
        }
    }
}

private func relativePackedPath(_ root: URL, _ url: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    var rel = String(path.dropFirst(rootPath.count))
    while rel.first == "/" { rel.removeFirst() }
    return rel
}

func collectPackedFSEntries(root: URL, options: PackedFSBuildOptions = PackedFSBuildOptions()) throws -> [PackedFSEntry] {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
        throw PackedFSError.notDirectory(root.path)
    }

    guard let enumerator = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else {
        throw PackedFSError.cannotEnumerate(root.path)
    }

    var entries: [PackedFSEntry] = []
    for case let url as URL in enumerator {
        let rel = relativePackedPath(root, url)
        if rel.isEmpty { continue }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values.isDirectory == true {
            entries.append(PackedFSEntry(path: rel, kind: swosPackedKindDir,
                                         mode: 0o755, owner: options.defaultOwner, data: Data()))
        } else if values.isRegularFile == true {
            let data = try Data(contentsOf: url)
            let isExec = options.executablePathPrefixes.contains { rel.hasPrefix($0) }
            var mode: UInt32 = isExec ? 0o755 : 0o644
            if options.setuidPaths.contains(rel) { mode |= swosPackedSetuidBit }
            entries.append(PackedFSEntry(path: rel, kind: swosPackedKindFile,
                                         mode: mode,
                                         owner: options.defaultOwner, data: data))
        }
    }

    let sorted = entries.sorted {
        if $0.path == $1.path { return $0.kind < $1.kind }
        return $0.path < $1.path
    }
    if sorted.isEmpty { throw PackedFSError.emptyTree(root.path) }
    return sorted
}

func buildPackedFS(root: URL, options: PackedFSBuildOptions = PackedFSBuildOptions()) throws -> PackedFSImage {
    try buildPackedFS(entries: collectPackedFSEntries(root: root, options: options))
}

/// Build a packed image. With `hashEntry` and `sign` both supplied (closures,
/// so this shared file stays free of crypto dependencies — swpkg passes
/// neither and keeps emitting v2), the signed v3 layout is produced:
/// `hashEntry(data)` must return the 32-byte digest stored per entry, and
/// `sign(bytes)` the 64-byte signature over header|entries|strings.
func buildPackedFS(entries: [PackedFSEntry],
                   hashEntry: ((Data) -> Data)? = nil,
                   sign: ((Data) -> Data)? = nil) throws -> PackedFSImage {
    if entries.isEmpty { throw PackedFSError.emptyTree("<entries>") }
    let signed = hashEntry != nil && sign != nil
    let version = signed ? swosPackedVersionSigned : swosPackedVersion
    let entrySize = signed ? swosPackedEntrySizeSigned : swosPackedEntrySize

    var strings = Data()
    var pathOffsets: [UInt32] = []
    for entry in entries {
        guard let pathData = entry.path.data(using: .utf8) else { throw PackedFSError.nonUTF8Path(entry.path) }
        if pathData.count > UInt32.max { throw PackedFSError.pathTooLong(entry.path) }
        pathOffsets.append(UInt32(strings.count))
        strings.append(pathData)
        strings.append(0)
    }

    var payload = Data()
    var dataOffsets: [UInt64] = []
    for entry in entries {
        dataOffsets.append(UInt64(payload.count))
        payload.append(entry.data)
    }

    let entriesOffset = UInt64(swosPackedHeaderSize)
    let stringsOffset = entriesOffset + UInt64(entries.count) * UInt64(entrySize)
    let sigSize = signed ? UInt64(swosPackedSignatureSize) : 0
    let dataOffset = stringsOffset + UInt64(strings.count) + sigSize

    var out = Data()
    out.append(contentsOf: swosPackedMagic)
    appendLE32(&out, version)
    appendLE32(&out, swosPackedHeaderSize)
    appendLE32(&out, entrySize)
    appendLE32(&out, UInt32(entries.count))
    appendLE64(&out, entriesOffset)
    appendLE64(&out, stringsOffset)
    appendLE64(&out, UInt64(strings.count))
    appendLE64(&out, dataOffset)
    appendLE64(&out, UInt64(payload.count))
    precondition(out.count == Int(swosPackedHeaderSize))

    for (i, entry) in entries.enumerated() {
        appendLE32(&out, pathOffsets[i])
        appendLE32(&out, UInt32(entry.path.utf8.count))
        appendLE32(&out, entry.kind)
        appendLE32(&out, 0)
        appendLE64(&out, dataOffsets[i])
        appendLE64(&out, UInt64(entry.data.count))
        appendLE32(&out, entry.mode)
        appendLE32(&out, entry.owner)
        if signed {
            // 32-byte content digest; directories carry zeros.
            if entry.kind == swosPackedKindFile {
                let digest = hashEntry!(entry.data)
                precondition(digest.count == 32, "hashEntry must return 32 bytes")
                out.append(digest)
            } else {
                out.append(Data(repeating: 0, count: 32))
            }
        }
    }
    out.append(strings)
    if signed {
        let signature = sign!(out)   // covers header | entries | strings
        precondition(signature.count == swosPackedSignatureSize, "sign must return 64 bytes")
        out.append(signature)
    }
    out.append(payload)
    return PackedFSImage(entries: entries, data: out)
}

func parsePackedFS(_ data: Data) throws -> PackedFSImage {
    guard data.count >= Int(swosPackedHeaderSize) else { throw PackedFSError.truncated("header") }
    let magic = String(decoding: data[0..<8], as: UTF8.self)
    guard Array(data[0..<8]) == swosPackedMagic else { throw PackedFSError.badMagic(magic) }
    let version = try readLE32(data, 8)
    guard version == swosPackedVersion || version == swosPackedVersionSigned else {
        throw PackedFSError.badVersion(version)
    }
    let headerSize = Int(try readLE32(data, 12))
    let entrySize = Int(try readLE32(data, 16))
    let entryCount = Int(try readLE32(data, 20))
    let entriesOffset = Int(try readLE64(data, 24))
    let stringsOffset = Int(try readLE64(data, 32))
    let stringsSize = Int(try readLE64(data, 40))
    let dataOffset = Int(try readLE64(data, 48))
    let dataSize = Int(try readLE64(data, 56))
    let wantEntrySize = version == swosPackedVersionSigned
        ? Int(swosPackedEntrySizeSigned) : Int(swosPackedEntrySize)
    guard headerSize == Int(swosPackedHeaderSize), entrySize == wantEntrySize else {
        throw PackedFSError.badLayout
    }
    guard entriesOffset + entryCount * entrySize <= data.count else { throw PackedFSError.outOfBounds("entries") }
    guard stringsOffset + stringsSize <= data.count else { throw PackedFSError.outOfBounds("strings") }
    guard dataOffset + dataSize <= data.count else { throw PackedFSError.outOfBounds("data section") }

    var entries: [PackedFSEntry] = []
    for i in 0..<entryCount {
        let off = entriesOffset + i * entrySize
        let pathOff = Int(try readLE32(data, off))
        let pathLen = Int(try readLE32(data, off + 4))
        let kind = try readLE32(data, off + 8)
        let fileOff = Int(try readLE64(data, off + 16))
        let fileLen = Int(try readLE64(data, off + 24))
        let mode = try readLE32(data, off + 32)
        let owner = try readLE32(data, off + 36)
        guard pathOff + pathLen < stringsSize else { throw PackedFSError.outOfBounds("path") }
        guard fileOff + fileLen <= dataSize else { throw PackedFSError.outOfBounds("file") }
        let pathStart = stringsOffset + pathOff
        let path = String(decoding: data[pathStart..<(pathStart + pathLen)], as: UTF8.self)
        let bytes = data[(dataOffset + fileOff)..<(dataOffset + fileOff + fileLen)]
        entries.append(PackedFSEntry(path: path, kind: kind, mode: mode, owner: owner, data: Data(bytes)))
    }

    return PackedFSImage(entries: entries, data: data)
}
