// SPDX-License-Identifier: Apache-2.0
// pkg.swift - tiny target-side package manager bootstrap.

private let oRdOnly: Int32 = 0
private let oWrOnly: Int32 = 1
private let oCreat: Int32 = 0x40
private let oTrunc: Int32 = 0x80
private let swpkgHeaderSize = 128
private let manifestMax = 16384
private let signedHeaderSize = 64
private let ioChunk = 4096
private let httpHeaderMax = 8192
private let catalogMax = 131072
private let repoURLMax = 512
private let trustRootPath = "/etc/pkg/repo-root.pub"
private let repoURLPath = "/tmp/pkg-repo-url"
private let catalogCachePath = "/tmp/pkg-catalog.signed"
private let packageCachePath = "/tmp/pkg-download.swpkg"

private struct HTTPURL {
    let ip: UInt32
    let port: UInt16
    let host: String
    let path: String
}

private struct CatalogPackage {
    let name: String
    let version: String
    let revision: UInt
    let sha256: String
    let size: UInt
    let url: String
}

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

private func putUInt(_ value: UInt) {
    var digits = [UInt8](repeating: 0, count: 20)
    var n = 0
    var v = value
    repeat {
        digits[n] = 0x30 + UInt8(v % 10)
        v /= 10
        n += 1
    } while v > 0
    while n > 0 {
        n -= 1
        swiftos_putc(digits[n])
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

private func writeAll(_ fd: Int32, _ ptr: UnsafeRawPointer, _ count: Int) -> Bool {
    var done = 0
    while done < count {
        let w = swiftos_write(fd, ptr.advanced(by: done), UInt(count - done))
        if w <= 0 { return false }
        done += Int(w)
    }
    return true
}

private func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    bytes.withUnsafeBytes { raw in
        writeAll(fd, raw.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!, bytes.count)
    }
}

private func findBytes(_ haystack: [UInt8], _ needle: [UInt8]) -> Int {
    findBytesFrom(haystack, needle, 0)
}

private func findBytesFrom(_ haystack: [UInt8], _ needle: [UInt8], _ start: Int) -> Int {
    if needle.isEmpty || needle.count > haystack.count { return -1 }
    if start < 0 || start >= haystack.count { return -1 }
    var i = start
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

private func containsBytes(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    if needle.isEmpty { return true }
    return findBytes(haystack, needle) >= 0
}

private func staticBytes(_ s: StaticString) -> [UInt8] {
    var out: [UInt8] = []
    s.withUTF8Buffer { bp in
        var i = 0
        while i < bp.count {
            out.append(bp[i])
            i += 1
        }
    }
    return out
}

private func parseIPv4Bytes(_ bytes: [UInt8], _ start: Int, _ end: Int) -> UInt32? {
    var octets = [UInt32](repeating: 0, count: 4)
    var idx = 0
    var cur: UInt32 = 0
    var digits = 0
    var i = start
    while i <= end {
        let ch: UInt8 = i < end ? bytes[i] : 0x2E
        if ch >= 0x30 && ch <= 0x39 {
            cur = cur * 10 + UInt32(ch - 0x30)
            if cur > 255 { return nil }
            digits += 1
        } else if ch == 0x2E {
            if digits == 0 || idx >= 4 { return nil }
            octets[idx] = cur
            idx += 1
            cur = 0
            digits = 0
        } else {
            return nil
        }
        i += 1
    }
    if idx != 4 { return nil }
    return (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]
}

private func parseURL(_ text: String) -> HTTPURL? {
    let bytes = Array(text.utf8)
    let prefix = staticBytes("http://")
    if bytes.count <= prefix.count { return nil }
    var i = 0
    while i < prefix.count {
        if bytes[i] != prefix[i] { return nil }
        i += 1
    }
    let hostStart = i
    while i < bytes.count && bytes[i] != 0x3A && bytes[i] != 0x2F { i += 1 }
    if i == hostStart { return nil }
    guard let ip = parseIPv4Bytes(bytes, hostStart, i) else { return nil }
    let host = String(decoding: bytes[hostStart..<i], as: UTF8.self)
    var port: UInt = 80
    if i < bytes.count && bytes[i] == 0x3A {
        i += 1
        let portStart = i
        port = 0
        while i < bytes.count && bytes[i] >= 0x30 && bytes[i] <= 0x39 {
            port = port * 10 + UInt(bytes[i] - 0x30)
            if port > 65535 { return nil }
            i += 1
        }
        if i == portStart { return nil }
    }
    if i < bytes.count && bytes[i] != 0x2F { return nil }
    let path = i < bytes.count ? String(decoding: bytes[i..<bytes.count], as: UTF8.self) : "/"
    return HTTPURL(ip: ip, port: UInt16(port), host: host, path: path)
}

private func joinURL(_ base: String, _ relative: String) -> String {
    var out = Array(base.utf8)
    if out.isEmpty || out[out.count - 1] != 0x2F { out.append(0x2F) }
    let rb = Array(relative.utf8)
    var i = 0
    while i < rb.count {
        out.append(rb[i])
        i += 1
    }
    return String(decoding: out, as: UTF8.self)
}

private func openCString(_ path: String, _ flags: Int32) -> Int32 {
    var cpath = Array(path.utf8CString)
    return cpath.withUnsafeMutableBufferPointer { bp in
        swiftos_open(bp.baseAddress!, flags)
    }
}

private func unlinkPath(_ path: String) {
    var cpath = Array(path.utf8CString)
    cpath.withUnsafeMutableBufferPointer { bp in
        _ = swiftos_unlink(bp.baseAddress!)
    }
}

private func readFile(_ path: String, maxSize: Int) -> [UInt8]? {
    var cpath = Array(path.utf8CString)
    var mode: UInt32 = 0
    var size: UInt = 0
    let statRc = cpath.withUnsafeMutableBufferPointer { bp in
        swiftos_stat(bp.baseAddress!, &mode, nil, nil, nil, &size, nil)
    }
    if statRc != 0 || size > UInt(maxSize) { return nil }
    let fd = cpath.withUnsafeMutableBufferPointer { bp in
        swiftos_open(bp.baseAddress!, oRdOnly)
    }
    if fd < 0 { return nil }
    var out = [UInt8](repeating: 0, count: Int(size))
    let ok = size == 0 || readExact(fd, &out, Int(size))
    _ = swiftos_close(fd)
    return ok ? out : nil
}

private func writeFile(_ path: String, _ bytes: [UInt8]) -> Bool {
    let fd = openCString(path, oWrOnly | oCreat | oTrunc)
    if fd < 0 { return false }
    let ok = writeAll(fd, bytes)
    _ = swiftos_close(fd)
    return ok
}

private func writeTextFile(_ path: String, _ text: String) -> Bool {
    writeFile(path, Array(text.utf8))
}

private func trimASCII(_ bytes: [UInt8]) -> [UInt8] {
    var start = 0
    var end = bytes.count
    while start < end && bytes[start] <= 0x20 { start += 1 }
    while end > start && bytes[end - 1] <= 0x20 { end -= 1 }
    var out: [UInt8] = []
    var i = start
    while i < end {
        out.append(bytes[i])
        i += 1
    }
    return out
}

private func readRepoURL() -> String? {
    guard let bytes = readFile(repoURLPath, maxSize: repoURLMax) else { return nil }
    let trimmed = trimASCII(bytes)
    if trimmed.isEmpty { return nil }
    return String(decoding: trimmed, as: UTF8.self)
}

private func httpStatusOK(_ header: [UInt8]) -> Bool {
    if header.count < 12 { return false }
    var i = 0
    while i < header.count && header[i] != 0x20 && header[i] != 0x0D { i += 1 }
    if i + 3 >= header.count || header[i] != 0x20 { return false }
    return header[i + 1] == 0x32 && header[i + 2] == 0x30 && header[i + 3] == 0x30
}

private func downloadHTTP(_ urlText: String, to outputPath: String) -> Bool {
    guard let url = parseURL(urlText) else {
        put("pkg: bad URL\n")
        return false
    }
    let sock = swiftos_socket_stream()
    if sock < 0 {
        put("pkg: socket failed\n")
        return false
    }
    if swiftos_connect(sock, url.ip, url.port) != 0 {
        put("pkg: connect failed\n")
        _ = swiftos_close(sock)
        return false
    }

    let request = "GET \(url.path) HTTP/1.0\r\nHost: \(url.host)\r\nConnection: close\r\n\r\n"
    if !writeAll(sock, Array(request.utf8)) {
        put("pkg: request failed\n")
        _ = swiftos_close(sock)
        return false
    }

    unlinkPath(outputPath)
    let outfd = openCString(outputPath, oWrOnly | oCreat | oTrunc)
    if outfd < 0 {
        put("pkg: cannot create cache file\n")
        _ = swiftos_close(sock)
        return false
    }

    var header: [UInt8] = []
    var sawHeader = false
    var ok = false
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: ioChunk) { buf in
        let base = buf.baseAddress!
        while true {
            let r = swiftos_read(sock, UnsafeMutableRawPointer(base), UInt(ioChunk))
            if r < 0 {
                if sawHeader && ok { break }
                ok = false
                break
            }
            if r == 0 { break }
            if !sawHeader {
                var i = 0
                while i < Int(r) {
                    header.append(base[i])
                    i += 1
                }
                if header.count > httpHeaderMax { ok = false; break }
                let split = findBytes(header, [0x0D, 0x0A, 0x0D, 0x0A])
                if split >= 0 {
                    if !httpStatusOK(header) {
                        put("pkg: HTTP status not OK\n")
                        ok = false
                        break
                    }
                    sawHeader = true
                    ok = true
                    let bodyStart = split + 4
                    if bodyStart < header.count {
                        let bodyCount = header.count - bodyStart
                        let wrote = header.withUnsafeBytes { raw in
                            writeAll(outfd, raw.baseAddress!.advanced(by: bodyStart), bodyCount)
                        }
                        if !wrote {
                            put("pkg: cache write failed\n")
                            ok = false
                            break
                        }
                    }
                }
            } else {
                if !writeAll(outfd, UnsafeRawPointer(base), Int(r)) {
                    put("pkg: cache write failed\n")
                    ok = false
                    break
                }
            }
        }
    }
    _ = swiftos_close(outfd)
    _ = swiftos_close(sock)
    if !sawHeader || !ok {
        if !sawHeader { put("pkg: response header missing\n") }
        unlinkPath(outputPath)
        return false
    }
    return true
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

private func verifySignedCatalog(_ signed: [UInt8]) -> [UInt8]? {
    if signed.count <= signedHeaderSize { return nil }
    guard let publicKey = readFile(trustRootPath, maxSize: 32), publicKey.count == 32 else {
        return nil
    }
    let bodyLen = signed.count - signedHeaderSize
    let ok = signed.withUnsafeBytes { sb in
        publicKey.withUnsafeBytes { pb in
            ed25519Verify(message: sb.baseAddress!.advanced(by: signedHeaderSize),
                          bodyLen,
                          signature: sb.baseAddress!,
                          publicKey: pb.baseAddress!)
        }
    }
    if !ok { return nil }
    var body: [UInt8] = []
    var i = signedHeaderSize
    while i < signed.count {
        body.append(signed[i])
        i += 1
    }
    return body
}

private func loadVerifiedCatalog() -> [UInt8]? {
    guard let signed = readFile(catalogCachePath, maxSize: catalogMax + signedHeaderSize) else {
        put("pkg: run pkg update first\n")
        return nil
    }
    guard let catalog = verifySignedCatalog(signed) else {
        put("pkg: catalog verification failed\n")
        return nil
    }
    if !validateCatalogBody(catalog) { return nil }
    return catalog
}

private func objectRangeForPackage(_ catalog: [UInt8], _ name: String) -> Range<Int>? {
    var needle = staticBytes("\"name\":\"")
    let nb = Array(name.utf8)
    var i = 0
    while i < nb.count {
        needle.append(nb[i])
        i += 1
    }
    needle.append(0x22)
    let pos = findBytes(catalog, needle)
    if pos < 0 { return nil }
    var start = pos
    while start >= 0 && catalog[start] != 0x7B { start -= 1 }
    if start < 0 { return nil }
    var end = pos
    while end < catalog.count && catalog[end] != 0x7D { end += 1 }
    if end >= catalog.count { return nil }
    return start..<(end + 1)
}

private func parseCatalogPackageObject(_ object: [UInt8]) -> CatalogPackage? {
    guard let name = jsonString(object, "name"),
          let version = jsonString(object, "version"),
          let arch = jsonString(object, "arch"),
          let target = jsonString(object, "target"),
          let abi = jsonString(object, "abi"),
          let linkage = jsonString(object, "linkage"),
          let sha = jsonString(object, "sha256"),
          let url = jsonString(object, "url") else { return nil }
    let revision = jsonUInt(object, "revision") ?? 1
    let size = jsonUInt(object, "size") ?? 0
    if arch != "aarch64" || target != "swift-os" || abi != "swos-0" || linkage != "static" {
        return nil
    }
    if sha.utf8.count != 64 || url.isEmpty || name.isEmpty || version.isEmpty {
        return nil
    }
    return CatalogPackage(name: name, version: version, revision: revision,
                          sha256: sha, size: size, url: url)
}

private func validateCatalogBody(_ catalog: [UInt8]) -> Bool {
    guard let expires = jsonUInt(catalog, "expires"), expires > 0 else {
        put("pkg: catalog invalid\n")
        return false
    }
    let now = swiftos_time()
    if now != 0 && expires <= now {
        put("pkg: catalog expired\n")
        return false
    }

    let key = staticBytes("\"name\":\"")
    var pos = 0
    var sawPackage = false
    while true {
        let start = findBytesFrom(catalog, key, pos)
        if start < 0 { break }
        var objectStart = start
        while objectStart >= 0 && catalog[objectStart] != 0x7B { objectStart -= 1 }
        if objectStart < 0 {
            put("pkg: catalog invalid\n")
            return false
        }
        var objectEnd = start
        while objectEnd < catalog.count && catalog[objectEnd] != 0x7D { objectEnd += 1 }
        if objectEnd >= catalog.count {
            put("pkg: catalog invalid\n")
            return false
        }
        let object = Array(catalog[objectStart..<(objectEnd + 1)])
        if parseCatalogPackageObject(object) == nil {
            put("pkg: catalog incompatible\n")
            return false
        }
        sawPackage = true
        pos = objectEnd + 1
    }
    if !sawPackage {
        put("pkg: catalog invalid\n")
        return false
    }
    return true
}

private func findCatalogPackage(_ catalog: [UInt8], _ name: String) -> CatalogPackage? {
    guard let range = objectRangeForPackage(catalog, name) else { return nil }
    return parseCatalogPackageObject(Array(catalog[range]))
}

private func printPackageLine(_ pkg: CatalogPackage) {
    putString(pkg.name)
    put("-")
    putString(pkg.version)
    put("_")
    putUInt(pkg.revision)
    put("\n")
}

private func searchCatalog(_ query: String) -> Int32 {
    guard let catalog = loadVerifiedCatalog() else { return 1 }
    let key = staticBytes("\"name\":\"")
    let queryBytes = Array(query.utf8)
    var pos = 0
    var found = false
    while true {
        let start = findBytesFrom(catalog, key, pos)
        if start < 0 { break }
        let nameStart = start + key.count
        var nameEnd = nameStart
        while nameEnd < catalog.count && catalog[nameEnd] != 0x22 { nameEnd += 1 }
        if nameEnd >= catalog.count { break }
        let nameBytes = Array(catalog[nameStart..<nameEnd])
        if containsBytes(nameBytes, queryBytes) {
            let name = String(decoding: nameBytes, as: UTF8.self)
            if let pkg = findCatalogPackage(catalog, name) {
                printPackageLine(pkg)
                found = true
            }
        }
        pos = nameEnd + 1
    }
    if !found { put("no matching packages\n") }
    return 0
}

private func infoCatalog(_ name: String) -> Int32 {
    guard let catalog = loadVerifiedCatalog() else { return 1 }
    guard let pkg = findCatalogPackage(catalog, name) else {
        put("pkg: package not found\n")
        return 1
    }
    put("name: ")
    putString(pkg.name)
    put("\nversion: ")
    putString(pkg.version)
    put("_")
    putUInt(pkg.revision)
    put("\nsize: ")
    putUInt(pkg.size)
    put("\nsha256: ")
    putString(pkg.sha256)
    put("\nurl: ")
    putString(pkg.url)
    put("\n")
    return 0
}

private func hexString(_ bytes: [UInt8]) -> String {
    let table = staticBytes("0123456789abcdef")
    var out: [UInt8] = []
    var i = 0
    while i < bytes.count {
        out.append(table[Int(bytes[i] >> 4)])
        out.append(table[Int(bytes[i] & 0x0F)])
        i += 1
    }
    return String(decoding: out, as: UTF8.self)
}

private func sha256FileHex(_ path: String) -> String? {
    let fd = openCString(path, oRdOnly)
    if fd < 0 { return nil }
    var hasher = SHA256Stream()
    var ok = true
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: ioChunk) { buf in
        let base = buf.baseAddress!
        while true {
            let r = swiftos_read(fd, UnsafeMutableRawPointer(base), UInt(ioChunk))
            if r < 0 { ok = false; break }
            if r == 0 { break }
            hasher.update(UnsafeRawPointer(base), Int(r))
        }
    }
    _ = swiftos_close(fd)
    if !ok { return nil }
    var digest = [UInt8](repeating: 0, count: sha256DigestLen)
    digest.withUnsafeMutableBytes { raw in
        hasher.finalize(raw.baseAddress!)
    }
    return hexString(digest)
}

private func isLocalPackageArgument(_ arg: String) -> Bool {
    let bytes = Array(arg.utf8)
    var i = 0
    while i < bytes.count {
        if bytes[i] == 0x2F { return true }
        i += 1
    }
    let suffix = staticBytes(".swpkg")
    if bytes.count < suffix.count { return false }
    let off = bytes.count - suffix.count
    i = 0
    while i < suffix.count {
        if bytes[off + i] != suffix[i] { return false }
        i += 1
    }
    return true
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

private func updateRepository(_ url: String) -> Int32 {
    let catalogURL = joinURL(url, "catalog.signed")
    if !downloadHTTP(catalogURL, to: catalogCachePath) {
        put("pkg: catalog download failed\n")
        return 1
    }
    guard let signed = readFile(catalogCachePath, maxSize: catalogMax + signedHeaderSize),
          let catalog = verifySignedCatalog(signed) else {
        put("pkg: catalog verification failed\n")
        unlinkPath(catalogCachePath)
        return 1
    }
    if !validateCatalogBody(catalog) {
        unlinkPath(catalogCachePath)
        return 1
    }
    if !writeTextFile(repoURLPath, url + "\n") {
        put("pkg: cannot save repository URL\n")
        return 1
    }
    put("pkg: catalog updated ")
    putString(url)
    put("\n")
    return 0
}

private func installFromRepository(_ name: String) -> Int32 {
    guard let repoURL = readRepoURL() else {
        put("pkg: run pkg update first\n")
        return 1
    }
    guard let catalog = loadVerifiedCatalog() else { return 1 }
    guard let pkg = findCatalogPackage(catalog, name) else {
        put("pkg: package not found\n")
        return 1
    }

    put("pkg: fetching ")
    printPackageLine(pkg)
    let packageURL = joinURL(repoURL, pkg.url)
    if !downloadHTTP(packageURL, to: packageCachePath) {
        put("pkg: package download failed\n")
        return 1
    }
    guard let digest = sha256FileHex(packageCachePath), digest == pkg.sha256 else {
        put("pkg: package SHA-256 mismatch\n")
        unlinkPath(packageCachePath)
        return 1
    }
    return install(packageCachePath)
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
        put("usage: pkg update URL | pkg search TEXT | pkg info NAME | pkg install FILE|NAME | pkg list\n")
        return 1
    }
    let cmd = cString(cmdp)
    if cmd == "update" {
        guard argc >= 3, let urlp = argv[2] else {
            put("usage: pkg update URL\n")
            return 1
        }
        return updateRepository(cString(urlp))
    }
    if cmd == "search" {
        guard argc >= 3, let textp = argv[2] else {
            put("usage: pkg search TEXT\n")
            return 1
        }
        return searchCatalog(cString(textp))
    }
    if cmd == "info" {
        guard argc >= 3, let namep = argv[2] else {
            put("usage: pkg info NAME\n")
            return 1
        }
        return infoCatalog(cString(namep))
    }
    if cmd == "list" {
        return list()
    }
    if cmd == "install" {
        guard argc >= 3, let argp = argv[2] else {
            put("usage: pkg install FILE|NAME\n")
            return 1
        }
        let arg = cString(argp)
        if isLocalPackageArgument(arg) {
            return install(arg)
        }
        return installFromRepository(arg)
    }
    put("usage: pkg update URL | pkg search TEXT | pkg info NAME | pkg install FILE|NAME | pkg list\n")
    return 1
}
