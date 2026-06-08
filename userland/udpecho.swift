// SPDX-License-Identifier: Apache-2.0
// udpecho.swift — native Swift `/bin/udpecho` for swift-os (net-b demo).
//
// Opens a UDP socket, binds port 5555, receives one datagram, prints its size
// and sender, and echoes the bytes back. Exercises the net-b socket syscalls
// (socket/bind/sendto/recvfrom) through the swiftos_* bridge.
// Pass "6" (or -6) as argv[1] to use AF_INET6 + extended v6 msg layout
// (true IPv6 UDP path, dual-stack).
// Drive v4: `printf swos-udp | nc -u 127.0.0.1 5555` (with hostfwd udp::5555-:5555).
// Drive v6: use nc -6 against the guest's IPv6 (link-local or via hostfwd v6).

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

private func hexDigit(_ n: UInt8) -> UInt8 {
    return n < 10 ? (0x30 + n) : (0x61 + (n - 10))
}
private func printHexByte(_ b: UInt8) {
    swiftos_putc(hexDigit(b >> 4))
    swiftos_putc(hexDigit(b & 0xF))
}
private func printIPv6(_ ip6: [UInt8]) {
    for g in 0..<8 {
        if g > 0 { swiftos_putc(0x3A) }
        printHexByte(ip6[g*2])
        printHexByte(ip6[g*2 + 1])
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

    let fd = useV6 ? swiftos_socket_ipv6() : swiftos_socket()
    if fd < 0 { swiftos_puts("udpecho: socket failed\n"); return 1 }
    if swiftos_bind(fd, listenPort) != 0 {
        swiftos_puts("udpecho: bind failed\n")
        _ = swiftos_close(fd)
        return 1
    }
    swiftos_puts(useV6 ? "udpecho: listening on 5555 (IPv6)\n" : "udpecho: listening on 5555\n")

    var senderIPv4: UInt32 = 0
    var senderIPv6 = [UInt8](repeating: 0, count: 16)
    var senderPort: UInt16 = 0
    let n = withUnsafeTemporaryAllocation(byteCount: 2048, alignment: 16) { raw -> Int in
        let r: Int
        if useV6 {
            r = senderIPv6.withUnsafeMutableBufferPointer { ip6p in
                swiftos_recvfrom_ipv6(fd, raw.baseAddress, UInt(raw.count), ip6p.baseAddress!, &senderPort)
            }
            if r > 0 {
                senderIPv6.withUnsafeBufferPointer { ip6p in
                    _ = swiftos_sendto_ipv6(fd, raw.baseAddress, UInt(r), ip6p.baseAddress!, senderPort)
                }
            }
        } else {
            r = swiftos_recvfrom(fd, raw.baseAddress, UInt(raw.count), &senderIPv4, &senderPort)
            if r > 0 { _ = swiftos_sendto(fd, raw.baseAddress, UInt(r), senderIPv4, senderPort) }
        }
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
    if useV6 {
        printIPv6(senderIPv6)
    } else {
        printIPv4(senderIPv4)
    }
    swiftos_putc(0x3A)            // ':'
    printUInt(UInt(senderPort))
    swiftos_putc(0x0A)           // newline
    _ = swiftos_close(fd)
    return 0
}
