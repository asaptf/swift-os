// SPDX-License-Identifier: Apache-2.0
// pkg.swift - tiny target-side package manager bootstrap.

private let oRdOnly: Int32 = 0
private let oWrOnly: Int32 = 1
private let oCreat: Int32 = 0x40
private let oTrunc: Int32 = 0x80
private let swpkgHeaderSize = 128
private let manifestMax = 262144
private let signedHeaderSize = 64
private let ioChunk = 4096
private let httpHeaderMax = 8192
private let catalogMax = 131072
private let repoURLMax = 512
private let dnsServerMax = 64
private let pkgFilesMax = 262144
private let trustRootPath = "/etc/pkg/repo-root.pub"
private let defaultDNSServerPath = "/etc/pkg/dns-server"
private let defaultRepoURLPath = "/etc/pkg/repo-url"
private let repoURLPath = "/tmp/pkg-repo-url"
private let catalogCachePath = "/tmp/pkg-catalog.signed"
private let maxCatalogPackages = 64
private let maxPackageDepends = 8

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
    let depends: [String]
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

private func bytesEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    if a.count != b.count { return false }
    var i = 0
    while i < a.count {
        if a[i] != b[i] { return false }
        i += 1
    }
    return true
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

private func parsePortBytes(_ bytes: [UInt8], _ start: Int, _ end: Int) -> UInt16? {
    if start >= end { return nil }
    var port: UInt = 0
    var i = start
    while i < end {
        let ch = bytes[i]
        if ch < 0x30 || ch > 0x39 { return nil }
        port = port * 10 + UInt(ch - 0x30)
        if port > 65535 { return nil }
        i += 1
    }
    return UInt16(port)
}

private func isDNSHostByte(_ ch: UInt8) -> Bool {
    (ch >= 0x30 && ch <= 0x39) ||
    (ch >= 0x41 && ch <= 0x5A) ||
    (ch >= 0x61 && ch <= 0x7A) ||
    ch == 0x2D ||
    ch == 0x2E
}

private func isValidDNSHost(_ bytes: [UInt8], _ start: Int, _ end: Int) -> Bool {
    if start >= end || end - start > 253 { return false }
    var labelLen = 0
    var sawDot = false
    var labelFirst: UInt8 = 0
    var labelLast: UInt8 = 0
    var i = start
    while i < end {
        let ch = bytes[i]
        if !isDNSHostByte(ch) { return false }
        if ch == 0x2E {
            if labelLen == 0 { return false }
            if labelFirst == 0x2D || labelLast == 0x2D { return false }
            sawDot = true
            labelLen = 0
            labelFirst = 0
            labelLast = 0
        } else {
            if labelLen == 0 { labelFirst = ch }
            labelLast = ch
            labelLen += 1
            if labelLen > 63 { return false }
        }
        i += 1
    }
    if labelLen == 0 { return false }
    if labelFirst == 0x2D || labelLast == 0x2D { return false }
    return sawDot
}

private func resolveURLHost(_ host: String) -> UInt32? {
    let bytes = Array(host.utf8)
    if let ip = parseIPv4Bytes(bytes, 0, bytes.count) { return ip }
    if !isValidDNSHost(bytes, 0, bytes.count) { return nil }
    let (dnsIP, dnsPort) = readDNSServer()
    var cHost = Array(host.utf8CString)
    let ip = cHost.withUnsafeBufferPointer { bp in
        swiftos_resolve(bp.baseAddress!, dnsIP, dnsPort)
    }
    return ip == 0 ? nil : ip
}

private func parseURL(_ text: String, resolveHost: Bool = true) -> HTTPURL? {
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
    let host = String(decoding: bytes[hostStart..<i], as: UTF8.self)
    let ip: UInt32
    if resolveHost {
        guard let resolvedIP = resolveURLHost(host) else { return nil }
        ip = resolvedIP
    } else if parseIPv4Bytes(bytes, hostStart, i) != nil || isValidDNSHost(bytes, hostStart, i) {
        ip = 0
    } else {
        return nil
    }
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
    guard let bytes = readFile(repoURLPath, maxSize: repoURLMax) ??
                      readFile(defaultRepoURLPath, maxSize: repoURLMax) else { return nil }
    let trimmed = trimASCII(bytes)
    if trimmed.isEmpty { return nil }
    return String(decoding: trimmed, as: UTF8.self)
}

private func readDNSServer() -> (UInt32, UInt16) {
    guard let bytes = readFile(defaultDNSServerPath, maxSize: dnsServerMax) else { return (0, 0) }
    let trimmed = trimASCII(bytes)
    if trimmed.isEmpty { return (0, 0) }
    var split = trimmed.count
    var i = 0
    while i < trimmed.count {
        if trimmed[i] == 0x3A {
            split = i
            break
        }
        i += 1
    }
    guard let ip = parseIPv4Bytes(trimmed, 0, split) else { return (0, 0) }
    if split == trimmed.count { return (ip, 0) }
    guard let port = parsePortBytes(trimmed, split + 1, trimmed.count) else { return (0, 0) }
    return (ip, port)
}

private func repoSet(_ url: String) -> Int32 {
    guard parseURL(url, resolveHost: false) != nil else {
        put("pkg: bad URL\n")
        return 1
    }
    if !writeTextFile(repoURLPath, url + "\n") {
        put("pkg: cannot save repository URL\n")
        return 1
    }
    put("pkg: repository set ")
    putString(url)
    put("\n")
    return 0
}

private func repoShow() -> Int32 {
    guard let url = readRepoURL() else {
        put("pkg: no repository configured\n")
        return 1
    }
    putString(url)
    put("\n")
    return 0
}

private func httpStatusOK(_ header: [UInt8]) -> Bool {
    if header.count < 12 { return false }
    var i = 0
    while i < header.count && header[i] != 0x20 && header[i] != 0x0D { i += 1 }
    if i + 3 >= header.count || header[i] != 0x20 { return false }
    return header[i + 1] == 0x32 && header[i + 2] == 0x30 && header[i + 3] == 0x30
}

private func asciiLower(_ b: UInt8) -> UInt8 {
    if b >= 0x41 && b <= 0x5A { return b + 0x20 }
    return b
}

private func httpContentLength(_ header: [UInt8], upTo end: Int) -> Int {
    let name = staticBytes("content-length:")
    var line = 0
    while line < end {
        var lineEnd = line
        while lineEnd < end && header[lineEnd] != 0x0D && header[lineEnd] != 0x0A {
            lineEnd += 1
        }
        if lineEnd - line >= name.count {
            var matched = true
            var i = 0
            while i < name.count {
                if asciiLower(header[line + i]) != name[i] {
                    matched = false
                    break
                }
                i += 1
            }
            if matched {
                var pos = line + name.count
                while pos < lineEnd && (header[pos] == 0x20 || header[pos] == 0x09) {
                    pos += 1
                }
                var value = 0
                var any = false
                while pos < lineEnd && header[pos] >= 0x30 && header[pos] <= 0x39 {
                    let digit = Int(header[pos] - 0x30)
                    if value > (Int.max - digit) / 10 { return -1 }
                    value = value * 10 + digit
                    any = true
                    pos += 1
                }
                return any ? value : -1
            }
        }
        while lineEnd < end && (header[lineEnd] == 0x0D || header[lineEnd] == 0x0A) {
            lineEnd += 1
        }
        line = lineEnd
    }
    return -1
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

    var outfd = openCString(outputPath, oWrOnly | oCreat | oTrunc)
    if outfd < 0 {
        unlinkPath(outputPath)
        outfd = openCString(outputPath, oWrOnly | oCreat | oTrunc)
    }
    if outfd < 0 {
        put("pkg: cannot create cache file\n")
        _ = swiftos_close(sock)
        return false
    }

    var header: [UInt8] = []
    var sawHeader = false
    var ok = false
    var expectedBody = -1
    var bodyWritten = 0
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
                    expectedBody = httpContentLength(header, upTo: split)
                    sawHeader = true
                    ok = true
                    let bodyStart = split + 4
                    if bodyStart < header.count {
                        var bodyCount = header.count - bodyStart
                        if expectedBody >= 0 && bodyCount > expectedBody {
                            bodyCount = expectedBody
                        }
                        if bodyCount > 0 {
                            let wrote = header.withUnsafeBytes { raw in
                                writeAll(outfd, raw.baseAddress!.advanced(by: bodyStart), bodyCount)
                            }
                            if !wrote {
                                put("pkg: cache write failed\n")
                                ok = false
                                break
                            }
                            bodyWritten += bodyCount
                        }
                    }
                    if expectedBody >= 0 && bodyWritten >= expectedBody { break }
                }
            } else {
                var bodyCount = Int(r)
                if expectedBody >= 0 {
                    let remaining = expectedBody - bodyWritten
                    if remaining <= 0 { break }
                    if bodyCount > remaining { bodyCount = remaining }
                }
                if bodyCount > 0 {
                    if !writeAll(outfd, UnsafeRawPointer(base), bodyCount) {
                        put("pkg: cache write failed\n")
                        ok = false
                        break
                    }
                    bodyWritten += bodyCount
                }
                if expectedBody >= 0 && bodyWritten >= expectedBody { break }
            }
        }
    }
    _ = swiftos_close(outfd)
    _ = swiftos_close(sock)
    if sawHeader && ok && expectedBody >= 0 && bodyWritten != expectedBody {
        put("pkg: response truncated\n")
        ok = false
    }
    if !sawHeader || !ok {
        if !sawHeader { put("pkg: response header missing\n") }
        unlinkPath(outputPath)
        return false
    }
    return true
}

private func isJSONSpace(_ ch: UInt8) -> Bool {
    ch == 0x20 || ch == 0x0A || ch == 0x0D || ch == 0x09
}

private func matchingJSONClose(_ bytes: [UInt8], start: Int, open: UInt8, close: UInt8) -> Int {
    if start < 0 || start >= bytes.count || bytes[start] != open { return -1 }
    var depth = 0
    var inString = false
    var escaped = false
    var i = start
    while i < bytes.count {
        let ch = bytes[i]
        if inString {
            if escaped {
                escaped = false
            } else if ch == 0x5C {
                escaped = true
            } else if ch == 0x22 {
                inString = false
            }
        } else if ch == 0x22 {
            inString = true
        } else if ch == open {
            depth += 1
        } else if ch == close {
            depth -= 1
            if depth == 0 { return i }
            if depth < 0 { return -1 }
        }
        i += 1
    }
    return -1
}

private func jsonValueEnd(_ bytes: [UInt8], start: Int) -> Int {
    if start < 0 || start >= bytes.count { return -1 }
    if bytes[start] == 0x7B {
        let close = matchingJSONClose(bytes, start: start, open: 0x7B, close: 0x7D)
        return close < 0 ? -1 : close + 1
    }
    if bytes[start] == 0x5B {
        let close = matchingJSONClose(bytes, start: start, open: 0x5B, close: 0x5D)
        return close < 0 ? -1 : close + 1
    }
    if bytes[start] == 0x22 {
        var escaped = false
        var i = start + 1
        while i < bytes.count {
            let ch = bytes[i]
            if escaped {
                escaped = false
            } else if ch == 0x5C {
                escaped = true
            } else if ch == 0x22 {
                return i + 1
            }
            i += 1
        }
        return -1
    }

    var i = start
    while i < bytes.count && bytes[i] != 0x2C && bytes[i] != 0x7D && bytes[i] != 0x5D {
        i += 1
    }
    return i
}

private func topLevelJSONValueStart(_ object: [UInt8], _ key: StaticString) -> Int {
    var objectStart = 0
    while objectStart < object.count && isJSONSpace(object[objectStart]) { objectStart += 1 }
    if objectStart >= object.count || object[objectStart] != 0x7B { return -1 }
    let objectEnd = matchingJSONClose(object, start: objectStart, open: 0x7B, close: 0x7D)
    if objectEnd < 0 { return -1 }

    let wanted = staticBytes(key)
    var i = objectStart + 1
    while i < objectEnd {
        while i < objectEnd && (isJSONSpace(object[i]) || object[i] == 0x2C) { i += 1 }
        if i >= objectEnd { break }
        if object[i] != 0x22 { return -1 }
        i += 1

        var foundKey: [UInt8] = []
        var escaped = false
        while i < objectEnd {
            let ch = object[i]
            if escaped {
                foundKey.append(ch)
                escaped = false
            } else if ch == 0x5C {
                escaped = true
            } else if ch == 0x22 {
                break
            } else {
                foundKey.append(ch)
            }
            i += 1
        }
        if i >= objectEnd || object[i] != 0x22 { return -1 }
        i += 1
        while i < objectEnd && isJSONSpace(object[i]) { i += 1 }
        if i >= objectEnd || object[i] != 0x3A { return -1 }
        i += 1
        while i < objectEnd && isJSONSpace(object[i]) { i += 1 }
        if i >= objectEnd { return -1 }
        if bytesEqual(foundKey, wanted) { return i }
        let end = jsonValueEnd(object, start: i)
        if end < 0 || end > objectEnd + 1 { return -1 }
        i = end
    }
    return -1
}

private func jsonString(_ manifest: [UInt8], _ key: StaticString) -> String? {
    let start = topLevelJSONValueStart(manifest, key)
    if start < 0 || start >= manifest.count || manifest[start] != 0x22 { return nil }
    var i = start + 1
    var out: [UInt8] = []
    var escaped = false
    while i < manifest.count {
        let ch = manifest[i]
        if escaped {
            out.append(ch)
            escaped = false
        } else if ch == 0x5C {
            escaped = true
        } else if ch == 0x22 {
            return out.isEmpty ? nil : String(decoding: out, as: UTF8.self)
        } else {
            out.append(ch)
        }
        i += 1
    }
    return nil
}

private func jsonUInt(_ manifest: [UInt8], _ key: StaticString) -> UInt? {
    let start = topLevelJSONValueStart(manifest, key)
    if start < 0 { return nil }
    var i = start
    var value: UInt = 0
    var any = false
    while i < manifest.count && manifest[i] >= 0x30 && manifest[i] <= 0x39 {
        value = value * 10 + UInt(manifest[i] - 0x30)
        any = true
        i += 1
    }
    return any ? value : nil
}

private func catalogPackageObjectRanges(_ catalog: [UInt8]) -> [Range<Int>]? {
    let arrayStart = topLevelJSONValueStart(catalog, "packages")
    if arrayStart < 0 || arrayStart >= catalog.count || catalog[arrayStart] != 0x5B { return nil }
    let arrayEnd = matchingJSONClose(catalog, start: arrayStart, open: 0x5B, close: 0x5D)
    if arrayEnd < 0 { return nil }
    var ranges: [Range<Int>] = []
    var i = arrayStart + 1
    while i < arrayEnd {
        while i < arrayEnd && (isJSONSpace(catalog[i]) || catalog[i] == 0x2C) { i += 1 }
        if i >= arrayEnd { break }
        if catalog[i] != 0x7B { return nil }
        let objectEnd = matchingJSONClose(catalog, start: i, open: 0x7B, close: 0x7D)
        if objectEnd < 0 || objectEnd > arrayEnd { return nil }
        ranges.append(i..<(objectEnd + 1))
        if ranges.count > maxCatalogPackages { return nil }
        i = objectEnd + 1
    }
    return ranges
}

private func dependencyNames(_ object: [UInt8]) -> [String]? {
    let arrayStart = topLevelJSONValueStart(object, "depends")
    if arrayStart < 0 || arrayStart >= object.count || object[arrayStart] != 0x5B { return nil }
    let arrayEnd = matchingJSONClose(object, start: arrayStart, open: 0x5B, close: 0x5D)
    if arrayEnd < 0 { return nil }

    var out: [String] = []
    var i = arrayStart + 1
    while i < arrayEnd {
        while i < arrayEnd && (isJSONSpace(object[i]) || object[i] == 0x2C) { i += 1 }
        if i >= arrayEnd { break }
        if object[i] != 0x7B { return nil }
        let objectEnd = matchingJSONClose(object, start: i, open: 0x7B, close: 0x7D)
        if objectEnd < 0 || objectEnd > arrayEnd { return nil }
        guard let name = jsonString(Array(object[i..<(objectEnd + 1)]), "name") else { return nil }
        out.append(name)
        if out.count > maxPackageDepends { return nil }
        i = objectEnd + 1
    }
    return out
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

private func loadVerifiedCatalog(quiet: Bool = false) -> [UInt8]? {
    guard let signed = readFile(catalogCachePath, maxSize: catalogMax + signedHeaderSize) else {
        if !quiet { put("pkg: run pkg update first\n") }
        return nil
    }
    guard let catalog = verifySignedCatalog(signed) else {
        if !quiet { put("pkg: catalog verification failed\n") }
        return nil
    }
    if !validateCatalogBody(catalog) { return nil }
    return catalog
}

private func parseCatalogPackageObject(_ object: [UInt8]) -> CatalogPackage? {
    guard let name = jsonString(object, "name"),
          let version = jsonString(object, "version"),
          let arch = jsonString(object, "arch"),
          let target = jsonString(object, "target"),
          let abi = jsonString(object, "abi"),
          let linkage = jsonString(object, "linkage"),
          let sha = jsonString(object, "sha256"),
          let url = jsonString(object, "url"),
          let depends = dependencyNames(object) else { return nil }
    let revision = jsonUInt(object, "revision") ?? 1
    let size = jsonUInt(object, "size") ?? 0
    if arch != "aarch64" || target != "swift-os" || abi != "swos-0" || linkage != "static" {
        return nil
    }
    if sha.utf8.count != 64 || url.isEmpty || name.isEmpty || version.isEmpty {
        return nil
    }
    return CatalogPackage(name: name, version: version, revision: revision,
                          sha256: sha, size: size, url: url, depends: depends)
}

private func collectCatalogPackages(_ catalog: [UInt8]) -> [CatalogPackage]? {
    guard let ranges = catalogPackageObjectRanges(catalog), !ranges.isEmpty else {
        put("pkg: catalog invalid\n")
        return nil
    }
    var packages: [CatalogPackage] = []
    var i = 0
    while i < ranges.count {
        guard let pkg = parseCatalogPackageObject(Array(catalog[ranges[i]])) else {
            put("pkg: catalog incompatible\n")
            return nil
        }
        packages.append(pkg)
        i += 1
    }

    i = 0
    while i < packages.count {
        var d = 0
        while d < packages[i].depends.count {
            var found = false
            var p = 0
            while p < packages.count {
                if packages[p].name == packages[i].depends[d] { found = true; break }
                p += 1
            }
            if !found {
                put("pkg: dependency missing ")
                putString(packages[i].depends[d])
                put("\n")
                return nil
            }
            d += 1
        }
        i += 1
    }
    return packages
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
    return collectCatalogPackages(catalog) != nil
}

private func findCatalogPackage(_ catalog: [UInt8], _ name: String) -> CatalogPackage? {
    guard let packages = collectCatalogPackages(catalog) else { return nil }
    var i = 0
    while i < packages.count {
        if packages[i].name == name { return packages[i] }
        i += 1
    }
    return nil
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
    guard let packages = collectCatalogPackages(catalog) else { return 1 }
    let queryBytes = Array(query.utf8)
    var i = 0
    var found = false
    while i < packages.count {
        let nameBytes = Array(packages[i].name.utf8)
        if containsBytes(nameBytes, queryBytes) {
            printPackageLine(packages[i])
            found = true
        }
        i += 1
    }
    if !found { put("no matching packages\n") }
    return 0
}

private func printCatalogInfo(_ pkg: CatalogPackage) {
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
    put("\ndepends: ")
    if pkg.depends.isEmpty {
        put("none")
    } else {
        var i = 0
        while i < pkg.depends.count {
            if i > 0 { put(",") }
            putString(pkg.depends[i])
            i += 1
        }
    }
    put("\n")
}

private func installedPackageVersion(_ name: String) -> String? {
    let nameBytes = Array(name.utf8)
    if nameBytes.isEmpty || nameBytes.count > 31 { return nil }
    var index: Int32 = 0
    while index < 16 {
        var buf = [CChar](repeating: 0, count: 80)
        let rc = buf.withUnsafeMutableBufferPointer { bp in
            swiftos_pkg_info(Int32(index), bp.baseAddress!, UInt(bp.count))
        }
        if rc < 0 { break }
        var ok = true
        var i = 0
        while i < nameBytes.count {
            if UInt8(bitPattern: buf[i]) != nameBytes[i] { ok = false; break }
            i += 1
        }
        if ok && buf[nameBytes.count] == CChar(bitPattern: 0x2D) {
            var versionBytes: [UInt8] = []
            i = nameBytes.count + 1
            while i < buf.count && buf[i] != 0 {
                versionBytes.append(UInt8(bitPattern: buf[i]))
                i += 1
            }
            return String(decoding: versionBytes, as: UTF8.self)
        }
        index += 1
    }
    return nil
}

private func printInstalledInfo(_ name: String) -> Bool {
    guard let version = installedPackageVersion(name) else { return false }
    put("name: ")
    putString(name)
    put("\nversion: ")
    putString(version)
    put("\nsource: installed\n")
    return true
}

private func infoPackage(_ name: String) -> Int32 {
    if let catalog = loadVerifiedCatalog(quiet: true),
       let pkg = findCatalogPackage(catalog, name) {
        printCatalogInfo(pkg)
        return 0
    }
    if printInstalledInfo(name) { return 0 }
    put("pkg: package not found\n")
    return 1
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

private func sha256Bytes(_ bytes: [UInt8]) -> [UInt8] {
    var digest = [UInt8](repeating: 0, count: sha256DigestLen)
    bytes.withUnsafeBytes { raw in
        digest.withUnsafeMutableBytes { out in
            let p = raw.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!
            sha256(p, bytes.count, out.baseAddress!)
        }
    }
    return digest
}

private func bytesEqualRange(_ a: [UInt8], _ aStart: Int,
                             _ b: [UInt8], _ bStart: Int,
                             _ count: Int) -> Bool {
    if aStart < 0 || bStart < 0 || aStart + count > a.count || bStart + count > b.count {
        return false
    }
    var i = 0
    while i < count {
        if a[aStart + i] != b[bStart + i] { return false }
        i += 1
    }
    return true
}

private func streamBegin(_ name: String, _ versionRevision: String,
                         _ payloadSize: UInt, _ payloadHash: [UInt8]) -> Bool {
    if payloadHash.count != sha256DigestLen { return false }
    var cname = Array(name.utf8CString)
    var cver = Array(versionRevision.utf8CString)
    let rc = cname.withUnsafeMutableBufferPointer { nbp in
        cver.withUnsafeMutableBufferPointer { vbp in
            payloadHash.withUnsafeBufferPointer { hp in
                swiftos_pkg_stream_begin(nbp.baseAddress!, vbp.baseAddress!,
                                         payloadSize, hp.baseAddress!)
            }
        }
    }
    return rc == 0
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

private func installedPackageNamed(_ name: String) -> Bool {
    installedPackageVersion(name) != nil
}

private func installHTTPPackage(_ pkg: CatalogPackage, from urlText: String) -> Int32 {
    guard let url = parseURL(urlText) else {
        put("pkg: bad URL\n")
        return 1
    }
    let sock = swiftos_socket_stream()
    if sock < 0 {
        put("pkg: socket failed\n")
        return 1
    }
    if swiftos_connect(sock, url.ip, url.port) != 0 {
        put("pkg: connect failed\n")
        _ = swiftos_close(sock)
        return 1
    }

    let request = "GET \(url.path) HTTP/1.0\r\nHost: \(url.host)\r\nConnection: close\r\n\r\n"
    if !writeAll(sock, Array(request.utf8)) {
        put("pkg: request failed\n")
        _ = swiftos_close(sock)
        return 1
    }

    var httpHeader: [UInt8] = []
    var sawHTTPHeader = false
    var ok = false
    var expectedBody = -1
    var bodySeen = 0

    var packageHasher = SHA256Stream()
    var packageHeader: [UInt8] = []
    var manifest: [UInt8] = []
    var manifestSize: UInt = 0
    var payloadOffset: UInt = 0
    var payloadSize: UInt = 0
    var packageSize: UInt = 0
    var payloadHash = [UInt8](repeating: 0, count: sha256DigestLen)
    var manifestReady = false
    var streamStarted = false
    var payloadWritten: UInt = 0
    var bodyRead: UInt = 0
    var installName = ""
    var installVersionRevision = ""

    func abortStream() {
        if streamStarted {
            _ = swiftos_pkg_stream_abort()
            streamStarted = false
        }
    }

    func validatePackageHeader() -> Bool {
        let magic = staticBytes("SWPKG001")
        if packageHeader.count != swpkgHeaderSize { return false }
        if !bytesEqualRange(packageHeader, 0, magic, 0, magic.count) { return false }
        if le32(packageHeader, 8) != 1 || le32(packageHeader, 12) != UInt32(swpkgHeaderSize) {
            return false
        }
        let manifestOffset = le64(packageHeader, 16)
        manifestSize = le64(packageHeader, 24)
        payloadOffset = le64(packageHeader, 32)
        payloadSize = le64(packageHeader, 40)
        let signatureOffset = le64(packageHeader, 112)
        let signatureSize = le64(packageHeader, 120)
        let (computedPayloadOffset, payloadOffsetOverflow) = manifestOffset.addingReportingOverflow(manifestSize)
        let (computedPackageSize, packageSizeOverflow) = payloadOffset.addingReportingOverflow(payloadSize)
        if signatureOffset != 0 || signatureSize != 0 { return false }
        if manifestOffset != UInt(swpkgHeaderSize) { return false }
        if payloadOffsetOverflow || payloadOffset != computedPayloadOffset { return false }
        if packageSizeOverflow || manifestSize == 0 || payloadSize == 0 { return false }
        if manifestSize > UInt(manifestMax) { return false }
        if pkg.size != 0 && pkg.size != computedPackageSize { return false }
        if expectedBody >= 0 && UInt(expectedBody) != computedPackageSize { return false }
        packageSize = computedPackageSize
        var i = 0
        while i < sha256DigestLen {
            payloadHash[i] = packageHeader[80 + i]
            i += 1
        }
        return true
    }

    func finishManifest() -> Bool {
        let manifestHash = sha256Bytes(manifest)
        if !bytesEqualRange(manifestHash, 0, packageHeader, 48, sha256DigestLen) {
            put("pkg: manifest SHA-256 mismatch\n")
            return false
        }
        guard let name = jsonString(manifest, "name"),
              let version = jsonString(manifest, "version") else {
            put("pkg: invalid package manifest\n")
            return false
        }
        let revision = jsonUInt(manifest, "revision") ?? 1
        if name != pkg.name || version != pkg.version || revision != pkg.revision {
            put("pkg: catalog/package metadata mismatch\n")
            return false
        }
        let versionRevision = "\(version)_\(revision)"
        if name.utf8.count > 31 || versionRevision.utf8.count > 15 {
            put("pkg: package metadata too long\n")
            return false
        }
        if !streamBegin(name, versionRevision, payloadSize, payloadHash) {
            put("pkg: package stream begin failed\n")
            return false
        }
        streamStarted = true
        manifestReady = true
        installName = name
        installVersionRevision = versionRevision
        return true
    }

    func consumeBody(_ ptr: UnsafeRawPointer, _ count: Int) -> Bool {
        if count <= 0 { return true }
        packageHasher.update(ptr, count)
        let src = ptr.assumingMemoryBound(to: UInt8.self)
        var off = 0
        while off < count {
            if packageHeader.count < swpkgHeaderSize {
                var take = swpkgHeaderSize - packageHeader.count
                if take > count - off { take = count - off }
                var i = 0
                while i < take {
                    packageHeader.append(src[off + i])
                    i += 1
                }
                off += take
                bodyRead += UInt(take)
                if packageHeader.count == swpkgHeaderSize && !validatePackageHeader() {
                    put("pkg: invalid package header\n")
                    return false
                }
            } else if !manifestReady {
                let remainingManifest = Int(manifestSize) - manifest.count
                var take = remainingManifest
                if take > count - off { take = count - off }
                if take <= 0 { return false }
                var i = 0
                while i < take {
                    manifest.append(src[off + i])
                    i += 1
                }
                off += take
                bodyRead += UInt(take)
                if manifest.count == Int(manifestSize) && !finishManifest() {
                    return false
                }
            } else {
                if payloadWritten >= payloadSize {
                    put("pkg: package has trailing data\n")
                    return false
                }
                let remainingPayload = payloadSize - payloadWritten
                var take = count - off
                if UInt(take) > remainingPayload { take = Int(remainingPayload) }
                if take <= 0 { return false }
                let rc = swiftos_pkg_stream_write(ptr.advanced(by: off), UInt(take))
                if rc != 0 {
                    put("pkg: package stream write failed\n")
                    return false
                }
                off += take
                bodyRead += UInt(take)
                payloadWritten += UInt(take)
            }
        }
        return true
    }

    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: ioChunk) { buf in
        let base = buf.baseAddress!
        while true {
            let r = swiftos_read(sock, UnsafeMutableRawPointer(base), UInt(ioChunk))
            if r < 0 {
                if sawHTTPHeader && ok { break }
                ok = false
                break
            }
            if r == 0 { break }
            if !sawHTTPHeader {
                var i = 0
                while i < Int(r) {
                    httpHeader.append(base[i])
                    i += 1
                }
                if httpHeader.count > httpHeaderMax { ok = false; break }
                let split = findBytes(httpHeader, [0x0D, 0x0A, 0x0D, 0x0A])
                if split >= 0 {
                    if !httpStatusOK(httpHeader) {
                        put("pkg: HTTP status not OK\n")
                        ok = false
                        break
                    }
                    expectedBody = httpContentLength(httpHeader, upTo: split)
                    sawHTTPHeader = true
                    ok = true
                    let bodyStart = split + 4
                    if bodyStart < httpHeader.count {
                        var bodyCount = httpHeader.count - bodyStart
                        if expectedBody >= 0 && bodyCount > expectedBody {
                            bodyCount = expectedBody
                        }
                        if bodyCount > 0 {
                            let consumed = httpHeader.withUnsafeBytes { raw in
                                consumeBody(raw.baseAddress!.advanced(by: bodyStart), bodyCount)
                            }
                            if !consumed {
                                ok = false
                                break
                            }
                            bodySeen += bodyCount
                        }
                    }
                    if expectedBody >= 0 && bodySeen >= expectedBody { break }
                }
            } else {
                var bodyCount = Int(r)
                if expectedBody >= 0 {
                    let remaining = expectedBody - bodySeen
                    if remaining <= 0 { break }
                    if bodyCount > remaining { bodyCount = remaining }
                }
                if bodyCount > 0 {
                    if !consumeBody(UnsafeRawPointer(base), bodyCount) {
                        ok = false
                        break
                    }
                    bodySeen += bodyCount
                }
                if expectedBody >= 0 && bodySeen >= expectedBody { break }
            }
        }
    }
    _ = swiftos_close(sock)

    if sawHTTPHeader && ok && expectedBody >= 0 && bodySeen != expectedBody {
        put("pkg: response truncated\n")
        ok = false
    }
    if !sawHTTPHeader || !ok {
        if !sawHTTPHeader { put("pkg: response header missing\n") }
        abortStream()
        return 1
    }
    if !streamStarted || !manifestReady || payloadWritten != payloadSize || bodyRead != packageSize {
        put("pkg: package truncated\n")
        abortStream()
        return 1
    }

    var packageDigest = [UInt8](repeating: 0, count: sha256DigestLen)
    packageDigest.withUnsafeMutableBytes { raw in
        packageHasher.finalize(raw.baseAddress!)
    }
    if hexString(packageDigest) != pkg.sha256 {
        put("pkg: package SHA-256 mismatch\n")
        abortStream()
        return 1
    }
    let commitRc = swiftos_pkg_stream_commit()
    streamStarted = false
    if commitRc != 0 {
        put("pkg: install failed\n")
        return 1
    }
    put("pkg: installed ")
    putString(installName)
    put("-")
    putString(installVersionRevision)
    put("\n")
    return 0
}

private func installCatalogPackage(_ pkg: CatalogPackage, repoURL: String) -> Int32 {
    put("pkg: fetching ")
    printPackageLine(pkg)
    let packageURL = joinURL(repoURL, pkg.url)
    return installHTTPPackage(pkg, from: packageURL)
}

private func installResolved(_ name: String, repoURL: String, catalog: [UInt8], stack: [String]) -> Int32 {
    if installedPackageNamed(name) { return 0 }
    var s = 0
    while s < stack.count {
        if stack[s] == name {
            put("pkg: dependency cycle ")
            putString(name)
            put("\n")
            return 1
        }
        s += 1
    }
    guard let pkg = findCatalogPackage(catalog, name) else {
        put("pkg: package not found\n")
        return 1
    }
    var nextStack = stack
    nextStack.append(name)
    var i = 0
    while i < pkg.depends.count {
        let rc = installResolved(pkg.depends[i], repoURL: repoURL, catalog: catalog, stack: nextStack)
        if rc != 0 { return rc }
        i += 1
    }
    return installCatalogPackage(pkg, repoURL: repoURL)
}

private func installFromRepository(_ name: String) -> Int32 {
    guard let repoURL = readRepoURL() else {
        put("pkg: run pkg update first\n")
        return 1
    }
    guard let catalog = loadVerifiedCatalog() else { return 1 }
    return installResolved(name, repoURL: repoURL, catalog: catalog, stack: [])
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

private func files(_ name: String) -> Int32 {
    var cname = Array(name.utf8CString)
    var dummy = [CChar](repeating: 0, count: 1)
    let needed = cname.withUnsafeMutableBufferPointer { nbp in
        dummy.withUnsafeMutableBufferPointer { dbp in
            swiftos_pkg_files(nbp.baseAddress!, dbp.baseAddress!, 0)
        }
    }
    if needed == -2 {
        put("pkg: package not installed\n")
        return 1
    }
    if needed < 0 {
        put("pkg: files failed\n")
        return 1
    }
    if needed == 0 {
        put("pkg: no files\n")
        return 0
    }
    let neededCount = Int(needed)
    if neededCount > pkgFilesMax {
        put("pkg: file list too large\n")
        return 1
    }
    var out = [CChar](repeating: 0, count: neededCount)
    let outCount = out.count
    let rc = cname.withUnsafeMutableBufferPointer { nbp in
        out.withUnsafeMutableBufferPointer { obp in
            swiftos_pkg_files(nbp.baseAddress!, obp.baseAddress!, UInt(outCount))
        }
    }
    if rc < 0 {
        put("pkg: files failed\n")
        return 1
    }
    let written = Int(rc)
    if written > out.count {
        put("pkg: files changed during read\n")
        return 1
    }
    let ok = out.withUnsafeBufferPointer { bp in
        writeAll(1, UnsafeRawPointer(bp.baseAddress!), written)
    }
    return ok ? 0 : 1
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp
    guard let argv = argv, argc >= 2, let cmdp = argv[1] else {
        put("usage: pkg repo set URL|show | pkg update [URL] | pkg search TEXT | pkg info NAME | pkg install FILE|NAME | pkg list | pkg files NAME\n")
        return 1
    }
    let cmd = cString(cmdp)
    if cmd == "repo" {
        guard argc >= 3, let subp = argv[2] else {
            put("usage: pkg repo set URL|show\n")
            return 1
        }
        let sub = cString(subp)
        if sub == "show" { return repoShow() }
        if sub == "set" {
            guard argc >= 4, let urlp = argv[3] else {
                put("usage: pkg repo set URL\n")
                return 1
            }
            return repoSet(cString(urlp))
        }
        put("usage: pkg repo set URL|show\n")
        return 1
    }
    if cmd == "update" {
        let url: String
        if argc >= 3, let urlp = argv[2] {
            url = cString(urlp)
        } else if let configured = readRepoURL() {
            url = configured
        } else {
            put("pkg: no repository configured\n")
            return 1
        }
        return updateRepository(url)
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
        return infoPackage(cString(namep))
    }
    if cmd == "list" {
        return list()
    }
    if cmd == "files" {
        guard argc >= 3, let namep = argv[2] else {
            put("usage: pkg files NAME\n")
            return 1
        }
        return files(cString(namep))
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
    put("usage: pkg repo set URL|show | pkg update [URL] | pkg search TEXT | pkg info NAME | pkg install FILE|NAME | pkg list | pkg files NAME\n")
    return 1
}
