// SPDX-License-Identifier: Apache-2.0
// netinfo.swift - target-side network status preflight for deploy checks.

private let flagReady: UInt32 = 1 << 0
private let flagDHCP4: UInt32 = 1 << 1
private let flagStatic6: UInt32 = 1 << 2
private let flagGateway6: UInt32 = 1 << 3

private func put(_ s: StaticString) {
    s.withUTF8Buffer { buf in
        for b in buf { swiftos_putc(b) }
    }
}

private func printUInt(_ v: UInt) {
    if v >= 10 { printUInt(v / 10) }
    swiftos_putc(UInt8(0x30 + (v % 10)))
}

private func printIPv4(_ ip: UInt32) {
    printUInt(UInt((ip >> 24) & 0xFF)); swiftos_putc(0x2E)
    printUInt(UInt((ip >> 16) & 0xFF)); swiftos_putc(0x2E)
    printUInt(UInt((ip >> 8) & 0xFF)); swiftos_putc(0x2E)
    printUInt(UInt(ip & 0xFF))
}

private func prefixLenFromMask(_ mask: UInt32) -> UInt {
    var prefix: UInt = 0
    var seenZero = false
    var bit = 0
    while bit < 32 {
        let set = (mask & (UInt32(1) << (31 - bit))) != 0
        if set {
            if seenZero { return 0 }
            prefix += 1
        } else {
            seenZero = true
        }
        bit += 1
    }
    return prefix
}

private func hexDigit(_ n: UInt8) -> UInt8 {
    return n < 10 ? (0x30 + n) : (0x61 + (n - 10))
}

private func printHex16(_ v: UInt16) {
    swiftos_putc(hexDigit(UInt8((v >> 12) & 0xF)))
    swiftos_putc(hexDigit(UInt8((v >> 8) & 0xF)))
    swiftos_putc(hexDigit(UInt8((v >> 4) & 0xF)))
    swiftos_putc(hexDigit(UInt8(v & 0xF)))
}

private func netByte(_ gateway: Bool, _ index: UInt32) -> UInt8 {
    return gateway ? swiftos_net_gateway6_byte(index) : swiftos_net_ipv6_byte(index)
}

private func printIPv6(_ gateway: Bool) {
    var group = 0
    while group < 8 {
        if group > 0 { swiftos_putc(0x3A) }
        let i = UInt32(group * 2)
        let hi = UInt16(netByte(gateway, i))
        let lo = UInt16(netByte(gateway, i + 1))
        printHex16((hi << 8) | lo)
        group += 1
    }
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc
    _ = argv
    _ = envp

    let rc = swiftos_netinfo_refresh()
    if rc != 0 {
        put("netinfo: unavailable\n")
        return 1
    }

    let flags = swiftos_net_flags()
    put("netinfo: ready ")
    put((flags & flagReady) != 0 ? "yes\n" : "no\n")

    put("netinfo: ipv4 ")
    printIPv4(swiftos_net_ipv4())
    swiftos_putc(0x2F)
    printUInt(prefixLenFromMask(swiftos_net_mask4()))
    put(" source ")
    put((flags & flagDHCP4) != 0 ? "dhcp\n" : "fallback\n")

    put("netinfo: gateway4 ")
    printIPv4(swiftos_net_gateway4())
    swiftos_putc(0x0A)

    put("netinfo: dns4 ")
    printIPv4(swiftos_net_dns4())
    swiftos_putc(0x0A)

    put("netinfo: ipv6 ")
    printIPv6(false)
    put(" prefix ")
    printUInt(UInt(swiftos_net_ipv6_prefix_len()))
    put(" source ")
    put((flags & flagStatic6) != 0 ? "static\n" : "link-local\n")

    put("netinfo: gateway6 ")
    if (flags & flagGateway6) != 0 {
        printIPv6(true)
        swiftos_putc(0x0A)
    } else {
        put("none\n")
    }

    put("netinfo: HC27 OK\n")
    return 0
}
