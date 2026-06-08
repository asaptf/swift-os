// SPDX-License-Identifier: Apache-2.0
// tcpecho.swift — native Swift `/bin/tcpecho` for swift-os (net-c2 demo).
//
// A one-shot TCP echo server: open a stream socket, bind 5555, listen, accept
// one connection, read a chunk, echo it back, and close. Exercises the net-c
// socket surface (socket/bind/listen/accept + stream read/write) through the
// swiftos_* bridge.
// Pass "6" (or -6) as argv[1] to use AF_INET6 stream socket (dual-stack TCPv6
// listener/accept path).
// Drive v4: `nc 127.0.0.1 5555` (hostfwd=tcp::5555-:5555).
// Drive v6: `nc -6` against guest IPv6 (when hostfwd v6 present).

private let listenPort: UInt16 = 5555

private func printUInt(_ v: UInt) {
    if v >= 10 { printUInt(v / 10) }
    swiftos_putc(UInt8(0x30 + (v % 10)))
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

    let fd = useV6 ? swiftos_socket_stream_ipv6() : swiftos_socket_stream()
    if fd < 0 { swiftos_puts("tcpecho: socket failed\n"); return 1 }
    if swiftos_bind(fd, listenPort) != 0 {
        swiftos_puts("tcpecho: bind failed\n"); _ = swiftos_close(fd); return 1
    }
    if swiftos_listen(fd, 1) != 0 {
        swiftos_puts("tcpecho: listen failed\n"); _ = swiftos_close(fd); return 1
    }
    swiftos_puts(useV6 ? "tcpecho: listening on 5555 (IPv6)\n" : "tcpecho: listening on 5555\n")

    let conn = swiftos_accept(fd)
    if conn < 0 { swiftos_puts("tcpecho: accept failed\n"); _ = swiftos_close(fd); return 1 }

    let n = withUnsafeTemporaryAllocation(byteCount: 2048, alignment: 16) { raw -> Int in
        let r = swiftos_read(conn, raw.baseAddress, UInt(raw.count))
        if r > 0 { _ = swiftos_write(conn, raw.baseAddress, UInt(r)) }   // echo
        return r
    }
    if n >= 0 {
        swiftos_puts("tcpecho: got ")
        printUInt(UInt(n))
        swiftos_puts(" bytes\n")
    } else {
        swiftos_puts("tcpecho: read failed\n")
    }
    _ = swiftos_close(conn)
    _ = swiftos_close(fd)
    return 0
}
