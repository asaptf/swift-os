// SPDX-License-Identifier: Apache-2.0
// httpd.swift — native Swift `/bin/httpd` for swift-os (net-e/net-g/net-h2).
//
// A concurrent static-file HTTP/1.0 server: bind 8080, listen, then a single
// poll()-driven event loop multiplexes the listener plus all live connections.
// Per connection it parses the request path, maps it into the /www docroot on
// the VFS, and serves it: a regular file streams with a stat-derived
// Content-Length and an extension-derived Content-Type; a directory with no
// index.html gets a generated HTML listing (net-h2). 404 if missing.
//
// Simple HTTP/1.0 keep-alive: when the request carries `Connection: keep-alive`
// (case-insensitive), the response uses the same header and the accepted
// socket stays open for the next sequential request on that fd. Default is
// still Connection: close. Multiple connections are serviced across poll
// iterations. Exercises socket/poll/accept/read/write/close + open/stat/getdents
// through the swiftos_* bridge.
//
// Pass "6" (or -6) as argv[1] to use AF_INET6 stream socket (dual-stack
// HTTP listener over IPv6; same poll/accept/read/write paths). Drive with
// nc -6 or curl -g against guest IPv6 (hostfwd tcp:[::1]:8080-:8080 etc).

private let listenPort: UInt16 = 8080
private let maxConns = 8
private let pollIn: Int16 = 0x001
private let docroot: StaticString = "/www"
private let oRdOnly: Int32 = 0
private let sIFMT: UInt32 = 0xF000
private let sIFDIR: UInt32 = 0x4000
private let dentsCap = 2048

private func writeStr(_ fd: Int32, _ s: StaticString) {
    s.withUTF8Buffer { _ = swiftos_write(fd, $0.baseAddress, UInt($0.count)) }
}

/// Write `v` as decimal digits to `fd`.
private func writeUInt(_ fd: Int32, _ v: UInt) {
    withUnsafeTemporaryAllocation(byteCount: 24, alignment: 1) { b in
        let p = b.baseAddress!
        var i = 24
        var x = v
        repeat {
            i -= 1
            p.storeBytes(of: UInt8(0x30 + (x % 10)), toByteOffset: i, as: UInt8.self)
            x /= 10
        } while x > 0
        _ = swiftos_write(fd, p + i, UInt(24 - i))
    }
}

private func writeConnectionHeader(_ fd: Int32, keepAlive: Bool) {
    if keepAlive {
        writeStr(fd, "\r\nConnection: keep-alive\r\n\r\n")
    } else {
        writeStr(fd, "\r\nConnection: close\r\n\r\n")
    }
}

private func send404(_ fd: Int32, keepAlive: Bool) {
    writeStr(fd, "HTTP/1.0 404 Not Found\r\nContent-Length: 0")
    writeConnectionHeader(fd, keepAlive: keepAlive)
}

/// ASCII lower-case for A–Z; other bytes unchanged.
@inline(__always)
private func lowerASCII(_ b: UInt8) -> UInt8 {
    if b >= 0x41 && b <= 0x5A { return b &+ 0x20 }
    return b
}

/// True if request bytes `p[0..<n]` contain a Connection: keep-alive header.
/// Scans case-insensitively for "connection:" then skips LWS and matches
/// "keep-alive" as the header value token.
private func requestWantsKeepAlive(_ p: UnsafeRawPointer, _ n: Int) -> Bool {
    // Needle "connection:" length 11.
    if n < 11 { return false }
    var i = 0
    while i + 11 <= n {
        var match = true
        // "connection:"
        let needle: [UInt8] = [
            0x63, 0x6F, 0x6E, 0x6E, 0x65, 0x63, 0x74, 0x69, 0x6F, 0x6E, 0x3A
        ]
        var k = 0
        while k < 11 {
            if lowerASCII(p.load(fromByteOffset: i + k, as: UInt8.self)) != needle[k] {
                match = false
                break
            }
            k += 1
        }
        if match {
            var j = i + 11
            // Skip spaces/tabs after the colon.
            while j < n {
                let c = p.load(fromByteOffset: j, as: UInt8.self)
                if c == 0x20 || c == 0x09 { j += 1; continue }
                break
            }
            // "keep-alive" = 10 bytes
            if j + 10 <= n {
                let ka: [UInt8] = [
                    0x6B, 0x65, 0x65, 0x70, 0x2D, 0x61, 0x6C, 0x69, 0x76, 0x65
                ]
                var ok = true
                var t = 0
                while t < 10 {
                    if lowerASCII(p.load(fromByteOffset: j + t, as: UInt8.self)) != ka[t] {
                        ok = false
                        break
                    }
                    t += 1
                }
                if ok { return true }
            }
            i += 1
            continue
        }
        i += 1
    }
    return false
}

/// Pick a Content-Type from the request path's extension. `p[0..<len]` is the
/// raw request path bytes (e.g. "/sub/note.txt"); the suffix after the final '.'
/// (when it follows the final '/') selects the type. Defaults to octet-stream.
private func mimeType(_ p: UnsafePointer<UInt8>, _ len: Int) -> StaticString {
    // Find the last '.' that comes after the last '/'.
    var dot = -1
    var i = 0
    while i < len {
        let c = p[i]
        if c == 0x2F { dot = -1 }        // '/' — reset; extension is per-segment
        else if c == 0x2E { dot = i }    // '.'
        i += 1
    }
    if dot < 0 || dot + 1 >= len { return "application/octet-stream" }
    let ext = p + dot + 1
    let elen = len - dot - 1
    // Case-sensitive match (lowercase suffixes only) — keeps it simple.
    @inline(__always) func eq(_ s: StaticString) -> Bool {
        if Int(s.utf8CodeUnitCount) != elen { return false }
        let sp = s.utf8Start
        var k = 0
        while k < elen { if ext[k] != sp[k] { return false }; k += 1 }
        return true
    }
    if eq("html") { return "text/html" }
    if eq("txt")  { return "text/plain" }
    if eq("css")  { return "text/css" }
    if eq("js")   { return "text/javascript" }
    if eq("json") { return "application/json" }
    return "application/octet-stream"
}

/// Generate an HTML directory listing for the open directory `dfd` and write it
/// (with a full 200/text/html response) to `cfd`. `reqPath[0..<reqLen]` is the
/// request path (used in the page title / heading). The body is buffered so we
/// can send an accurate Content-Length, then written in one shot.
private func serveListing(_ cfd: Int32, _ dfd: Int32,
                          _ reqPath: UnsafePointer<UInt8>, _ reqLen: Int,
                          keepAlive: Bool) {
    // Cap the generated page; plenty for a demo docroot.
    let bodyCap = 8192
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: bodyCap) { body in
      withUnsafeTemporaryAllocation(of: UInt8.self, capacity: dentsCap) { dbuf in
        let bb = body.baseAddress!
        var w = 0
        @inline(__always) func put(_ b: UInt8) { if w < bodyCap { bb[w] = b; w += 1 } }
        @inline(__always) func putS(_ s: StaticString) { s.withUTF8Buffer { for b in $0 { put(b) } } }
        @inline(__always) func putRaw(_ p: UnsafePointer<UInt8>, _ len: Int) {
            var i = 0; while i < len { put(p[i]); i += 1 }
        }

        putS("<!doctype html>\n<html><head><title>Index of ")
        putRaw(reqPath, reqLen)
        putS("</title></head>\n<body>\n<h1>Index of ")
        putRaw(reqPath, reqLen)
        putS("</h1>\n<ul>\n")

        let dbase = dbuf.baseAddress!
        while true {
            let n = swiftos_getdents(dfd, UnsafeMutableRawPointer(dbase), UInt(dentsCap))
            if n <= 0 { break }
            var off = 0
            while off < Int(n) {
                let rec = dbase + off
                let reclen = Int(UInt16(rec[16]) | (UInt16(rec[17]) << 8))
                if reclen <= 0 { break }
                let namePtr = rec + 19
                var nameLen = 0
                while namePtr[nameLen] != 0 { nameLen += 1 }
                // Skip "." and ".." pseudo-entries.
                let isDot = nameLen == 1 && namePtr[0] == 0x2E
                let isDotDot = nameLen == 2 && namePtr[0] == 0x2E && namePtr[1] == 0x2E
                if !isDot && !isDotDot {
                    putS("<li><a href=\"")
                    putRaw(namePtr, nameLen)
                    putS("\">")
                    putRaw(namePtr, nameLen)
                    putS("</a></li>\n")
                }
                off += reclen
            }
        }
        putS("</ul>\n</body></html>\n")

        writeStr(cfd, "HTTP/1.0 200 OK\r\nContent-Type: text/html\r\nContent-Length: ")
        writeUInt(cfd, UInt(w))
        writeConnectionHeader(cfd, keepAlive: keepAlive)
        _ = swiftos_write(cfd, bb, UInt(w))
      }
    }
}

/// Result of handling one HTTP request on an accepted socket.
/// - peerClosed: read returned <= 0 (drop the connection)
/// - closeAfter: response sent with Connection: close (or error path)
/// - keepAlive: response sent with Connection: keep-alive; leave fd open
private enum ServeResult {
    case peerClosed
    case closeAfter
    case keepAlive
}

/// Read one request from `cfd`, resolve it into /www, and serve the file (or 404).
/// Returns whether the connection should stay open for another sequential request.
private func serveConnection(_ cfd: Int32) -> ServeResult {
  return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 256) { pathBuf -> ServeResult in
    let pathStore = pathBuf.baseAddress!
    return withUnsafeTemporaryAllocation(byteCount: 1024, alignment: 16) { req -> ServeResult in
        let rp = req.baseAddress!
        let r = swiftos_read(cfd, rp, UInt(req.count))
        if r <= 0 { return .peerClosed }
        let n = Int(r)
        let keepAlive = requestWantsKeepAlive(rp, n)

        @inline(__always) func rb(_ i: Int) -> UInt8 { rp.load(fromByteOffset: i, as: UInt8.self) }
        @inline(__always) func done(_ ok: Bool) -> ServeResult {
            if keepAlive && ok { return .keepAlive }
            return .closeAfter
        }

        // Require "GET " and a path starting with '/'.
        if n < 6 || rb(0) != 0x47 || rb(1) != 0x45 || rb(2) != 0x54 || rb(3) != 0x20 || rb(4) != 0x2F {
            send404(cfd, keepAlive: false); return .closeAfter
        }
        var pend = 4
        while pend < n {
            let c = rb(pend)
            if c == 0x20 || c == 0x0D || c == 0x0A { break }
            pend += 1
        }
        let pathLen = pend - 4
        if pathLen <= 0 || pathLen > 200 {
            send404(cfd, keepAlive: keepAlive)
            return done(false)
        }
        // Path-traversal guard: reject ".." anywhere.
        var t = 4
        while t + 1 < pend {
            if rb(t) == 0x2E && rb(t + 1) == 0x2E {
                send404(cfd, keepAlive: keepAlive)
                return done(false)
            }
            t += 1
        }

        // Copy the request path bytes (req[4..<pend]) into a stable buffer, so
        // logging and MIME selection stay correct even after the file-serving
        // path reuses `rp` for file content.
        do {
            var i = 0
            while i < pathLen && i < 256 { pathStore[i] = rb(4 + i); i += 1 }
        }
        let reqPathPtr = UnsafePointer(pathStore)

        // Build the docroot-relative C path: "/www" + path, with "/" → "/www/index.html".
        let served = withUnsafeTemporaryAllocation(byteCount: 256, alignment: 1) { cp -> Bool in
            let cpb = cp.baseAddress!
            var w = 0
            func put(_ b: UInt8) { if w < 255 { cpb.storeBytes(of: b, toByteOffset: w, as: UInt8.self); w += 1 } }
            func putStatic(_ s: StaticString) { s.withUTF8Buffer { for b in $0 { put(b) } } }
            putStatic(docroot)
            if pathLen == 1 {
                putStatic("/index.html")
            } else {
                var j = 4
                while j < pend { put(rb(j)); j += 1 }
            }
            put(0)
            let cpath = cpb.assumingMemoryBound(to: CChar.self)

            var mode: UInt32 = 0
            var size: UInt = 0
            if swiftos_stat(cpath, &mode, nil, nil, nil, &size, nil) != 0 { return false }

            // A directory: serve a generated listing (the "/" → index.html
            // rewrite above already prefers an index when one exists).
            if (mode & sIFMT) == sIFDIR {
                let dfd = swiftos_open(cpath, oRdOnly)
                if dfd < 0 { return false }
                serveListing(cfd, dfd, reqPathPtr, pathLen, keepAlive: keepAlive)
                _ = swiftos_close(dfd)
                return true
            }

            let fd = swiftos_open(cpath, oRdOnly)
            if fd < 0 { return false }
            // Peek one chunk to confirm it's a readable regular file (a directory
            // read returns < 0); only then commit to a 200 + headers.
            let first = swiftos_read(fd, rp, UInt(req.count))   // reuse the request buffer
            if first < 0 { _ = swiftos_close(fd); return false }

            writeStr(cfd, "HTTP/1.0 200 OK\r\nContent-Type: ")
            writeStr(cfd, mimeType(reqPathPtr, pathLen))
            writeStr(cfd, "\r\nContent-Length: ")
            writeUInt(cfd, size)
            writeConnectionHeader(cfd, keepAlive: keepAlive)
            if first > 0 { _ = swiftos_write(cfd, rp, UInt(first)) }
            while true {
                let m = swiftos_read(fd, rp, UInt(req.count))
                if m <= 0 { break }
                _ = swiftos_write(cfd, rp, UInt(m))
            }
            _ = swiftos_close(fd)
            return true
        }

        // Log line (the request path was saved in pathStore above, so it stays
        // correct even though file serving reuses `rp`).
        swiftos_puts(served ? "httpd: 200 " : "httpd: 404 ")
        _ = swiftos_write(1, pathStore, UInt(pathLen))
        if keepAlive { swiftos_puts(" (keep-alive)") }
        swiftos_putc(0x0A)
        if !served {
            send404(cfd, keepAlive: keepAlive)
            return done(false)
        }
        return done(true)
    }
  }
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp

    let useV6: Bool = {
        guard argc >= 2, let av = argv, let a1 = av[1] else { return false }
        let c0 = a1[0]
        return c0 == 0x36 /* '6' */ || (c0 == 0x2D /*'-'*/ && a1[1] == 0x36)
    }()

    let lfd = useV6 ? swiftos_socket_stream_ipv6() : swiftos_socket_stream()
    if lfd < 0 { swiftos_puts("httpd: socket failed\n"); return 1 }
    if swiftos_bind(lfd, listenPort) != 0 { swiftos_puts("httpd: bind failed\n"); _ = swiftos_close(lfd); return 1 }
    if swiftos_listen(lfd, Int32(maxConns)) != 0 { swiftos_puts("httpd: listen failed\n"); _ = swiftos_close(lfd); return 1 }
    swiftos_puts(useV6 ? "httpd: listening on 8080 (IPv6)\n" : "httpd: listening on 8080\n")

    var conns = [Int32](repeating: -1, count: maxConns)

    while true {
        withUnsafeTemporaryAllocation(byteCount: (maxConns + 1) * 8, alignment: 8) { raw in
            let base = raw.baseAddress!
            // Slot 0 = listener; slots 1.. = active connections (in conns-index order).
            base.storeBytes(of: lfd, toByteOffset: 0, as: Int32.self)
            base.storeBytes(of: pollIn, toByteOffset: 4, as: Int16.self)
            base.storeBytes(of: Int16(0), toByteOffset: 6, as: Int16.self)
            var n = 1
            for ci in 0..<maxConns where conns[ci] >= 0 {
                let off = n * 8
                base.storeBytes(of: conns[ci], toByteOffset: off, as: Int32.self)
                base.storeBytes(of: pollIn, toByteOffset: off + 4, as: Int16.self)
                base.storeBytes(of: Int16(0), toByteOffset: off + 6, as: Int16.self)
                n += 1
            }

            if swiftos_poll(base, UInt(n), -1) <= 0 { return }

            // Service ready connections first (slots in the same conns-index order
            // they were built), then accept new ones — so a freshly-accepted
            // connection never desyncs the slot mapping.
            var slot = 1
            for ci in 0..<maxConns where conns[ci] >= 0 {
                let rev = base.load(fromByteOffset: slot * 8 + 6, as: Int16.self)
                slot += 1
                if (rev & pollIn) == 0 { continue }
                switch serveConnection(conns[ci]) {
                case .keepAlive:
                    // Leave conns[ci] open for the next sequential request.
                    break
                case .peerClosed, .closeAfter:
                    _ = swiftos_close(conns[ci])
                    conns[ci] = -1
                }
            }

            let lrev = base.load(fromByteOffset: 6, as: Int16.self)
            if (lrev & pollIn) != 0 {
                let c = swiftos_accept(lfd)
                if c >= 0 {
                    var placed = false
                    for ci in 0..<maxConns where conns[ci] < 0 { conns[ci] = Int32(c); placed = true; break }
                    if !placed { _ = swiftos_close(c) }   // table full: drop
                }
            }
        }
    }
}
