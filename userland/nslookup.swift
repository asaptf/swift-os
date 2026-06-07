// SPDX-License-Identifier: Apache-2.0
// nslookup.swift — native Swift `/bin/nslookup` for swift-os (net-f demo).
//
// Resolve a hostname to an IPv4 via the kernel DNS resolver (which queries a DNS
// server over UDP). Usage: nslookup <name> [server-ip] [port]. With no server it
// uses the slirp DNS at 10.0.2.3:53; the test passes an explicit host responder.

private func cstrlen(_ p: UnsafePointer<CChar>) -> Int {
    var n = 0; while p[n] != 0 { n += 1 }; return n
}

private func printUInt(_ v: UInt) {
    if v >= 10 { printUInt(v / 10) }
    swiftos_putc(UInt8(0x30 + (v % 10)))
}

private func printIPv4(_ ip: UInt32) {
    printUInt(UInt((ip >> 24) & 0xFF)); swiftos_putc(0x2E)
    printUInt(UInt((ip >> 16) & 0xFF)); swiftos_putc(0x2E)
    printUInt(UInt((ip >> 8) & 0xFF));  swiftos_putc(0x2E)
    printUInt(UInt(ip & 0xFF))
}

/// Parse a dotted-decimal IPv4 into host order, or 0 on bad input.
private func parseIPv4(_ p: UnsafePointer<CChar>) -> UInt32 {
    var octet: UInt32 = 0, value: UInt32 = 0, parts = 0, digits = 0, i = 0
    while true {
        let ch = p[i]
        if ch >= 0x30 && ch <= 0x39 {
            octet = octet * 10 + UInt32(ch - 0x30)
            if octet > 255 { return 0 }
            digits += 1
        } else if ch == 0x2E || ch == 0 {
            if digits == 0 || parts > 3 { return 0 }
            value = (value << 8) | octet; parts += 1; octet = 0; digits = 0
            if ch == 0 { break }
        } else {
            return 0
        }
        i += 1
    }
    return parts == 4 ? value : 0
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp
    guard argc >= 2, let argv = argv, let nameArg = argv[1] else {
        swiftos_puts("usage: nslookup <name> [server-ip] [port]\n")
        return 1
    }

    var serverIP: UInt32 = 0
    if argc >= 3, let a = argv[2] { serverIP = parseIPv4(a) }
    var port: UInt16 = 0
    if argc >= 4, let a = argv[3] {
        var v: UInt = 0, i = 0
        while a[i] >= 0x30 && a[i] <= 0x39 { v = v * 10 + UInt(a[i] - 0x30); i += 1 }
        if v > 0 && v <= 65535 { port = UInt16(v) }
    }

    let ip = swiftos_resolve(nameArg, serverIP, port)
    _ = swiftos_write(1, UnsafeRawPointer(nameArg), UInt(cstrlen(nameArg)))
    if ip == 0 {
        swiftos_puts(": not found\n")
        return 1
    }
    swiftos_puts(" -> ")
    printIPv4(ip)
    swiftos_putc(0x0A)
    return 0
}
