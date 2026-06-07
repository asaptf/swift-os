// SPDX-License-Identifier: Apache-2.0
// udpecho.swift — native Swift `/bin/udpecho` for swift-os (net-b demo).
//
// Opens a UDP socket, binds port 5555, receives one datagram, prints its size
// and sender, and echoes the bytes back. Exercises the net-b socket syscalls
// (socket/bind/sendto/recvfrom) through the swiftos_* bridge. Drive it with a
// host sender, e.g. `printf swos-udp | nc -u 127.0.0.1 5555` when QEMU is booted
// with `-netdev user,hostfwd=udp::5555-:5555`.

private let listenPort: UInt16 = 5555

private func printUInt(_ v: UInt) {
    if v >= 10 { printUInt(v / 10) }
    swiftos_putc(UInt8(0x30 + (v % 10)))
}

private func printIPv4(_ ip: UInt32) {
    printUInt(UInt((ip >> 24) & 0xFF)); swiftos_putc(0x2E)   // '.'
    printUInt(UInt((ip >> 16) & 0xFF)); swiftos_putc(0x2E)
    printUInt(UInt((ip >> 8) & 0xFF));  swiftos_putc(0x2E)
    printUInt(UInt(ip & 0xFF))
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp

    let fd = swiftos_socket()
    if fd < 0 { swiftos_puts("udpecho: socket failed\n"); return 1 }
    if swiftos_bind(fd, listenPort) != 0 {
        swiftos_puts("udpecho: bind failed\n")
        _ = swiftos_close(fd)
        return 1
    }
    swiftos_puts("udpecho: listening on 5555\n")

    var ip: UInt32 = 0
    var port: UInt16 = 0
    let n = withUnsafeTemporaryAllocation(byteCount: 2048, alignment: 16) { raw -> Int in
        let r = swiftos_recvfrom(fd, raw.baseAddress, UInt(raw.count), &ip, &port)
        if r > 0 { _ = swiftos_sendto(fd, raw.baseAddress, UInt(r), ip, port) }  // echo back
        return r
    }
    if n < 0 {
        swiftos_puts("udpecho: recvfrom failed\n")
        _ = swiftos_close(fd)
        return 1
    }

    swiftos_puts("udpecho: got ")
    printUInt(UInt(n))
    swiftos_puts(" bytes from ")
    printIPv4(ip)
    swiftos_putc(0x3A)            // ':'
    printUInt(UInt(port))
    swiftos_putc(0x0A)           // newline
    _ = swiftos_close(fd)
    return 0
}
