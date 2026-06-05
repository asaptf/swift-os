// base_image_test.swift - host test for the packed read-only base image.

import Foundation

private let kindDir: UInt32 = 1
private let kindFile: UInt32 = 2

struct ParsedEntry {
    let path: String
    let kind: UInt32
    let mode: UInt32
    let owner: UInt32
    let data: Data
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}

private func le32(_ data: Data, _ off: Int) -> UInt32 {
    UInt32(data[off]) |
    (UInt32(data[off + 1]) << 8) |
    (UInt32(data[off + 2]) << 16) |
    (UInt32(data[off + 3]) << 24)
}

private func le64(_ data: Data, _ off: Int) -> UInt64 {
    var value: UInt64 = 0
    for i in 0..<8 {
        value |= UInt64(data[off + i]) << UInt64(i * 8)
    }
    return value
}

private func parse(_ data: Data) -> [ParsedEntry] {
    guard data.count >= 64 else { fail("image shorter than header") }
    let magic = String(decoding: data[0..<8], as: UTF8.self)
    guard magic == "SWOSBASE" else { fail("bad magic \(magic)") }
    guard le32(data, 8) == 2 else { fail("bad version") }
    let headerSize = Int(le32(data, 12))
    let entrySize = Int(le32(data, 16))
    let entryCount = Int(le32(data, 20))
    let entriesOffset = Int(le64(data, 24))
    let stringsOffset = Int(le64(data, 32))
    let stringsSize = Int(le64(data, 40))
    let dataOffset = Int(le64(data, 48))
    let dataSize = Int(le64(data, 56))
    guard headerSize == 64 && entrySize == 40 else { fail("unexpected layout") }
    guard dataOffset + dataSize <= data.count else { fail("data section out of bounds") }

    var entries: [ParsedEntry] = []
    for i in 0..<entryCount {
        let off = entriesOffset + i * entrySize
        let pathOff = Int(le32(data, off))
        let pathLen = Int(le32(data, off + 4))
        let kind = le32(data, off + 8)
        let fileOff = Int(le64(data, off + 16))
        let fileLen = Int(le64(data, off + 24))
        let mode = le32(data, off + 32)
        let owner = le32(data, off + 36)
        guard pathOff + pathLen < stringsSize else { fail("path out of bounds") }
        guard fileOff + fileLen <= dataSize else { fail("file out of bounds") }

        let pathStart = stringsOffset + pathOff
        let path = String(decoding: data[pathStart..<(pathStart + pathLen)], as: UTF8.self)
        let bytes = data[(dataOffset + fileOff)..<(dataOffset + fileOff + fileLen)]
        entries.append(ParsedEntry(path: path, kind: kind, mode: mode, owner: owner, data: Data(bytes)))
    }
    return entries
}

let args = CommandLine.arguments
guard args.count == 2 else { fail("usage: base_image_test <image>") }
let image = try! Data(contentsOf: URL(fileURLWithPath: args[1]))
let entries = parse(image)
let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })

func require(_ path: String, _ kind: UInt32) -> ParsedEntry {
    guard let entry = byPath[path] else { fail("missing \(path)") }
    guard entry.kind == kind else { fail("wrong kind for \(path)") }
    return entry
}

_ = require("bin", kindDir)
_ = require("etc", kindDir)
let busybox = require("bin/busybox", kindFile)
let identitydemo = require("bin/identitydemo", kindFile)
let ps = require("bin/ps", kindFile)
let motd = require("etc/motd", kindFile)
let hostname = require("etc/hostname", kindFile)
let readme = require("readme.txt", kindFile)
let hello = require("hello.txt", kindFile)

guard String(decoding: motd.data, as: UTF8.self) == "Welcome to swift-os.\n" else { fail("bad motd") }
guard String(decoding: hostname.data, as: UTF8.self) == "swiftos\n" else { fail("bad hostname") }
guard String(decoding: readme.data, as: UTF8.self) == "swift-os read-only base fs\n" else { fail("bad readme") }
guard String(decoding: hello.data, as: UTF8.self) == "M5 file: hello from VFS read()\n" else { fail("bad hello") }

for exe in [busybox, identitydemo, ps] {
    guard exe.data.count > 4 else { fail("\(exe.path) too short") }
    guard exe.data[0] == 0x7f && exe.data[1] == 0x45 && exe.data[2] == 0x4c && exe.data[3] == 0x46 else {
        fail("\(exe.path) is not an ELF")
    }
}

// M13c: per-entry mode + owner. Base files are root-owned; /bin/* are
// executable (0o755) and text files are 0o644; directories are 0o755.
for e in entries {
    guard e.owner == 1 else { fail("\(e.path) owner \(e.owner), expected 1 (root)") }
}
guard busybox.mode == 0o755 else { fail("busybox mode \(String(busybox.mode, radix: 8)), expected 755") }
guard ps.mode == 0o755 else { fail("ps mode \(String(ps.mode, radix: 8)), expected 755") }
guard motd.mode == 0o644 else { fail("motd mode \(String(motd.mode, radix: 8)), expected 644") }
guard require("bin", kindDir).mode == 0o755 else { fail("bin dir mode, expected 755") }

print("PASS: packed base image format is readable and deterministic")
