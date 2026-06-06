// httpd.swift — native Swift `/bin/httpd` for swift-os (net-e demo).
//
// A minimal concurrent HTTP/1.0 server: bind 8080, listen, then a single
// poll()-driven event loop multiplexes the listener plus all live connections.
// Per connection it reads the request, sends a fixed 200 response, and closes
// (Connection: close). Multiple connections are serviced concurrently across
// poll iterations — the point of the demo. Exercises socket/bind/listen/accept/
// poll/read/write/close through the swiftos_* bridge.

private let listenPort: UInt16 = 8080
private let maxConns = 8
private let pollIn: Int16 = 0x001

private func printUInt(_ v: UInt) {
    if v >= 10 { printUInt(v / 10) }
    swiftos_putc(UInt8(0x30 + (v % 10)))
}

private func sendResponse(_ fd: Int32) {
    let resp: StaticString = """
    HTTP/1.0 200 OK\r
    Content-Type: text/plain\r
    Content-Length: 19\r
    Connection: close\r
    \r
    Hello from swift-os
    """
    resp.withUTF8Buffer { _ = swiftos_write(fd, $0.baseAddress, UInt($0.count)) }
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

            // Service ready connections first (slots assigned in the same
            // conns-index order they were built), then accept new ones — so a
            // freshly-accepted connection never desyncs the slot mapping.
            var slot = 1
            for ci in 0..<maxConns where conns[ci] >= 0 {
                let rev = base.load(fromByteOffset: slot * 8 + 6, as: Int16.self)
                slot += 1
                if (rev & pollIn) == 0 { continue }
                let cfd = conns[ci]
                let got = withUnsafeTemporaryAllocation(byteCount: 1024, alignment: 16) { rb -> Int in
                    swiftos_read(cfd, rb.baseAddress, UInt(rb.count))
                }
                if got > 0 {
                    sendResponse(cfd)
                    swiftos_puts("httpd: 200 fd ")
                    printUInt(UInt(cfd))
                    swiftos_putc(0x0A)
                }
                _ = swiftos_close(cfd)
                conns[ci] = -1
            }

            // New connection?
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
