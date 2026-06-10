// SPDX-License-Identifier: Apache-2.0
// pkg.swift - tiny target-side package manager bootstrap.

private let oRdOnly: Int32 = 0
private let swpkgHeaderSize = 128
private let manifestMax = 16384

private func cString(_ p: UnsafeMutablePointer<CChar>) -> String {
    var bytes: [UInt8] = []
    var i = 0
    while p[i] != 0 {
        bytes.append(UInt8(bitPattern: p[i]))
        i += 1
    }
    return String(decoding: bytes, as: UTF8.self)
}

private func put(_ s: StaticString) {
    swiftos_puts(UnsafeRawPointer(s.utf8Start).assumingMemoryBound(to: CChar.self))
}

private func putString(_ s: String) {
    var bytes = Array(s.utf8)
    bytes.append(0)
    bytes.withUnsafeBufferPointer { bp in
        swiftos_puts(UnsafeRawPointer(bp.baseAddress!).assumingMemoryBound(to: CChar.self))
    }
}

private func le32(_ b: [UInt8], _ off: Int) -> UInt32 {
    UInt32(b[off]) | (UInt32(b[off + 1]) << 8) |
    (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24)
}

private func le64(_ b: [UInt8], _ off: Int) -> UInt {
    var v: UInt = 0
    var i = 7
    while i >= 0 {
        v = (v << 8) | UInt(b[off + i])
        i -= 1
    }
    return v
}

private func readExact(_ fd: Int32, _ buf: inout [UInt8], _ count: Int) -> Bool {
    var done = 0
    while done < count {
        let r = buf.withUnsafeMutableBytes { raw in
            swiftos_read(Int32(fd), raw.baseAddress!.advanced(by: done), UInt(count - done))
        }
        if r <= 0 { return false }
        done += Int(r)
    }
    return true
}

private func findBytes(_ haystack: [UInt8], _ needle: [UInt8]) -> Int {
    if needle.isEmpty || needle.count > haystack.count { return -1 }
    var i = 0
    while i + needle.count <= haystack.count {
        var ok = true
        var j = 0
        while j < needle.count {
            if haystack[i + j] != needle[j] { ok = false; break }
            j += 1
        }
        if ok { return i }
        i += 1
    }
    return -1
}

private func jsonString(_ manifest: [UInt8], _ key: StaticString) -> String? {
    var needle: [UInt8] = [0x22] // "
    key.withUTF8Buffer { kb in
        var i = 0
        while i < kb.count { needle.append(kb[i]); i += 1 }
    }
    needle.append(0x22) // "
    needle.append(0x3A) // :
    needle.append(0x22) // "
    let start = findBytes(manifest, needle)
    if start < 0 { return nil }
    var i = start + needle.count
    var out: [UInt8] = []
    while i < manifest.count && manifest[i] != 0x22 {
        out.append(manifest[i])
        i += 1
    }
    if i >= manifest.count || out.isEmpty { return nil }
    return String(decoding: out, as: UTF8.self)
}

private func jsonUInt(_ manifest: [UInt8], _ key: StaticString) -> UInt? {
    var needle: [UInt8] = [0x22]
    key.withUTF8Buffer { kb in
        var i = 0
        while i < kb.count { needle.append(kb[i]); i += 1 }
    }
    needle.append(0x22)
    needle.append(0x3A)
    let start = findBytes(manifest, needle)
    if start < 0 { return nil }
    var i = start + needle.count
    var value: UInt = 0
    var any = false
    while i < manifest.count && manifest[i] >= 0x30 && manifest[i] <= 0x39 {
        value = value * 10 + UInt(manifest[i] - 0x30)
        any = true
        i += 1
    }
    return any ? value : nil
}

private func parsePackageMetadata(_ fd: Int32) -> (String, String)? {
    var header = [UInt8](repeating: 0, count: swpkgHeaderSize)
    if !readExact(fd, &header, swpkgHeaderSize) { return nil }
    let magic = Array("SWPKG001".utf8)
    var i = 0
    while i < magic.count {
        if header[i] != magic[i] { return nil }
        i += 1
    }
    if le32(header, 8) != 1 || le32(header, 12) != UInt32(swpkgHeaderSize) { return nil }
    let manifestOffset = le64(header, 16)
    let manifestSize = le64(header, 24)
    let payloadOffset = le64(header, 32)
    let signatureOffset = le64(header, 112)
    let signatureSize = le64(header, 120)
    if manifestOffset != UInt(swpkgHeaderSize) { return nil }
    if payloadOffset != manifestOffset + manifestSize { return nil }
    if signatureOffset != 0 || signatureSize != 0 { return nil }
    if manifestSize == 0 || manifestSize > UInt(manifestMax) { return nil }

    var manifest = [UInt8](repeating: 0, count: Int(manifestSize))
    if !readExact(fd, &manifest, Int(manifestSize)) { return nil }
    guard let name = jsonString(manifest, "name"),
          let version = jsonString(manifest, "version") else { return nil }
    let revision = jsonUInt(manifest, "revision") ?? 1
    let versionRevision = "\(version)_\(revision)"
    if name.utf8.count > 31 || versionRevision.utf8.count > 15 { return nil }
    return (name, versionRevision)
}

private func install(_ path: String) -> Int32 {
    var cpath = Array(path.utf8CString)
    let fd = cpath.withUnsafeMutableBufferPointer { bp in
        swiftos_open(bp.baseAddress!, oRdOnly)
    }
    if fd < 0 {
        put("pkg: cannot open package\n")
        return 1
    }
    guard let (name, versionRevision) = parsePackageMetadata(fd) else {
        _ = swiftos_close(fd)
        put("pkg: invalid package\n")
        return 1
    }
    var cname = Array(name.utf8CString)
    var cver = Array(versionRevision.utf8CString)
    let rc = cname.withUnsafeMutableBufferPointer { nbp in
        cver.withUnsafeMutableBufferPointer { vbp in
            swiftos_pkg_install(fd, nbp.baseAddress!, vbp.baseAddress!)
        }
    }
    _ = swiftos_close(fd)
    if rc != 0 {
        put("pkg: install failed\n")
        return 1
    }
    put("pkg: installed ")
    putString(name)
    put("-")
    putString(versionRevision)
    put("\n")
    return 0
}

private func list() -> Int32 {
    var any = false
    var index: Int32 = 0
    while index < 16 {
        var buf = [CChar](repeating: 0, count: 80)
        let rc = buf.withUnsafeMutableBufferPointer { bp in
            swiftos_pkg_info(Int32(index), bp.baseAddress!, UInt(bp.count))
        }
        if rc < 0 { break }
        any = true
        buf.withUnsafeBufferPointer { bp in
            swiftos_puts(bp.baseAddress!)
        }
        put("\n")
        index += 1
    }
    if !any { put("no packages installed\n") }
    return 0
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp
    guard let argv = argv, argc >= 2, let cmdp = argv[1] else {
        put("usage: pkg install FILE | pkg list\n")
        return 1
    }
    let cmd = cString(cmdp)
    if cmd == "list" {
        return list()
    }
    if cmd == "install" {
        guard argc >= 3, let pathp = argv[2] else {
            put("usage: pkg install FILE\n")
            return 1
        }
        return install(cString(pathp))
    }
    put("usage: pkg install FILE | pkg list\n")
    return 1
}
