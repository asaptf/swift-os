// basepack.swift - build the swift-os packed read-only base image.
//
// Format v1 is intentionally tiny and kernel-friendly:
//   64-byte little-endian header
//   fixed 40-byte entries, sorted by path
//   NUL-terminated UTF-8 path string table
//   concatenated file data
//
// Directories and regular files are enough for the M11 packed base filesystem.

import Foundation

private let magic = Array("SWOSBASE".utf8)
private let version: UInt32 = 2   // v2 (M13c): per-entry mode + owner are meaningful
private let headerSize: UInt32 = 64
private let entrySize: UInt32 = 40
private let kindDir: UInt32 = 1
private let kindFile: UInt32 = 2

private struct Entry {
    let path: String
    let kind: UInt32
    let mode: UInt32   // permission bits (e.g. 0o755 / 0o644)
    let owner: UInt32  // owning principal id (1 = root)
    let data: Data
}

// Every base-image file is owned by the root principal. Non-root ownership is
// demonstrated at runtime by tmpfs files, which the kernel stamps with the
// creating principal (see kernel/vfs/vfs.swift createTmpNode).
private let rootOwner: UInt32 = 1

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("basepack: \(message)\n".utf8))
    exit(1)
}

private func appendLE32(_ out: inout Data, _ value: UInt32) {
    var v = value.littleEndian
    withUnsafeBytes(of: &v) { out.append(contentsOf: $0) }
}

private func appendLE64(_ out: inout Data, _ value: UInt64) {
    var v = value.littleEndian
    withUnsafeBytes(of: &v) { out.append(contentsOf: $0) }
}

private func relativePath(_ root: URL, _ url: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    var rel = String(path.dropFirst(rootPath.count))
    while rel.first == "/" { rel.removeFirst() }
    return rel
}

private func collectEntries(root: URL) -> [Entry] {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
        fail("input root is not a directory: \(root.path)")
    }

    guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                                        options: [.skipsHiddenFiles]) else {
        fail("cannot enumerate \(root.path)")
    }

    var entries: [Entry] = []
    for case let url as URL in enumerator {
        let rel = relativePath(root, url)
        if rel.isEmpty { continue }

        let values = try! url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values.isDirectory == true {
            entries.append(Entry(path: rel, kind: kindDir, mode: 0o755, owner: rootOwner, data: Data()))
        } else if values.isRegularFile == true {
            let data = try! Data(contentsOf: url)
            // `/bin/*` are programs (rwxr-xr-x); everything else is rw-r--r--.
            // Keyed on the path rather than the host execute bit, which cp/git
            // do not reliably preserve for the staged ELFs.
            let isExec = rel.hasPrefix("bin/")
            entries.append(Entry(path: rel, kind: kindFile, mode: isExec ? 0o755 : 0o644,
                                 owner: rootOwner, data: data))
        }
    }

    return entries.sorted { a, b in
        if a.path == b.path { return a.kind < b.kind }
        return a.path < b.path
    }
}

private func pack(root: URL, output: URL) {
    let entries = collectEntries(root: root)
    if entries.isEmpty { fail("input root has no entries") }

    var strings = Data()
    var pathOffsets: [UInt32] = []
    for entry in entries {
        guard let pathData = entry.path.data(using: .utf8) else { fail("non-UTF8 path: \(entry.path)") }
        if pathData.count > UInt32.max { fail("path too long: \(entry.path)") }
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

    let entriesOffset = UInt64(headerSize)
    let stringsOffset = entriesOffset + UInt64(entries.count) * UInt64(entrySize)
    let dataOffset = stringsOffset + UInt64(strings.count)

    var out = Data()
    out.append(contentsOf: magic)
    appendLE32(&out, version)
    appendLE32(&out, headerSize)
    appendLE32(&out, entrySize)
    appendLE32(&out, UInt32(entries.count))
    appendLE64(&out, entriesOffset)
    appendLE64(&out, stringsOffset)
    appendLE64(&out, UInt64(strings.count))
    appendLE64(&out, dataOffset)
    appendLE64(&out, UInt64(payload.count))
    precondition(out.count == Int(headerSize))

    for (i, entry) in entries.enumerated() {
        let pathLen = UInt32(entry.path.utf8.count)
        appendLE32(&out, pathOffsets[i])
        appendLE32(&out, pathLen)
        appendLE32(&out, entry.kind)
        appendLE32(&out, 0)
        appendLE64(&out, dataOffsets[i])
        appendLE64(&out, UInt64(entry.data.count))
        appendLE32(&out, entry.mode)
        appendLE32(&out, entry.owner)
    }
    out.append(strings)
    out.append(payload)

    do {
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try out.write(to: output, options: .atomic)
    } catch {
        fail("write failed: \(error)")
    }

    print("basepack: wrote \(entries.count) entries to \(output.path)")
}

let args = CommandLine.arguments
guard args.count == 3 else {
    fail("usage: basepack <root-dir> <output-image>")
}

pack(root: URL(fileURLWithPath: args[1]), output: URL(fileURLWithPath: args[2]))
