// httpd.swift — native Swift `/bin/httpd` for swift-os (net-e/net-g).
//
// A concurrent static-file HTTP/1.0 server: bind 8080, listen, then a single
// poll()-driven event loop multiplexes the listener plus all live connections.
// Per connection it parses the request path, maps it into the /www docroot on
// the VFS, and streams the file with the right Content-Length (404 if missing),
// then closes (Connection: close). Multiple connections are serviced across poll
// iterations. Exercises socket/poll/accept/read/write/close + open/stat through
// the swiftos_* bridge.

private let listenPort: UInt16 = 8080
private let maxConns = 8
private let pollIn: Int16 = 0x001
private let docroot: StaticString = "/www"
private let oRdOnly: Int32 = 0

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

private func send404(_ fd: Int32) {
    writeStr(fd, "HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
}

/// Read one request from `cfd`, resolve it into /www, and serve the file (or 404).
private func serveConnection(_ cfd: Int32) {
    withUnsafeTemporaryAllocation(byteCount: 1024, alignment: 16) { req in
        let rp = req.baseAddress!
        let r = swiftos_read(cfd, rp, UInt(req.count))
        if r <= 0 { return }
        let n = Int(r)

        @inline(__always) func rb(_ i: Int) -> UInt8 { rp.load(fromByteOffset: i, as: UInt8.self) }

        // Require "GET " and a path starting with '/'.
        if n < 6 || rb(0) != 0x47 || rb(1) != 0x45 || rb(2) != 0x54 || rb(3) != 0x20 || rb(4) != 0x2F {
            send404(cfd); return
        }
        var pend = 4
        while pend < n {
            let c = rb(pend)
            if c == 0x20 || c == 0x0D || c == 0x0A { break }
            pend += 1
        }
        let pathLen = pend - 4
        if pathLen <= 0 || pathLen > 200 { send404(cfd); return }
        // Path-traversal guard: reject ".." anywhere.
        var t = 4
        while t + 1 < pend {
            if rb(t) == 0x2E && rb(t + 1) == 0x2E { send404(cfd); return }
            t += 1
        }

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

            var size: UInt = 0
            if swiftos_stat(cpath, nil, nil, nil, nil, &size, nil) != 0 { return false }
            let fd = swiftos_open(cpath, oRdOnly)
            if fd < 0 { return false }
            // Peek one chunk to confirm it's a readable regular file (a directory
            // read returns < 0); only then commit to a 200 + headers.
            let first = swiftos_read(fd, rp, UInt(req.count))   // reuse the request buffer
            if first < 0 { _ = swiftos_close(fd); return false }

            writeStr(cfd, "HTTP/1.0 200 OK\r\nContent-Type: text/html\r\nContent-Length: ")
            writeUInt(cfd, size)
            writeStr(cfd, "\r\nConnection: close\r\n\r\n")
            if first > 0 { _ = swiftos_write(cfd, rp, UInt(first)) }
            while true {
                let m = swiftos_read(fd, rp, UInt(req.count))
                if m <= 0 { break }
                _ = swiftos_write(cfd, rp, UInt(m))
            }
            _ = swiftos_close(fd)
            return true
        }

        // Log line (the request path bytes are still intact in req[4..<pend]).
        swiftos_puts(served ? "httpd: 200 " : "httpd: 404 ")
        _ = swiftos_write(1, rp + 4, UInt(pathLen))
        swiftos_putc(0x0A)
        if !served { send404(cfd) }
    }
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp

    let lfd = swiftos_socket_stream()
    if lfd < 0 { swiftos_puts("httpd: socket failed\n"); return 1 }
    if swiftos_bind(lfd, listenPort) != 0 { swiftos_puts("httpd: bind failed\n"); _ = swiftos_close(lfd); return 1 }
    if swiftos_listen(lfd, Int32(maxConns)) != 0 { swiftos_puts("httpd: listen failed\n"); _ = swiftos_close(lfd); return 1 }
    swiftos_puts("httpd: listening on 8080\n")

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
                serveConnection(conns[ci])
                _ = swiftos_close(conns[ci])
                conns[ci] = -1
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
