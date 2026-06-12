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

private func argEquals(_ p: UnsafeMutablePointer<CChar>?, _ literal: StaticString) -> Bool {
    guard let p else { return false }
    return literal.withUTF8Buffer { bytes in
        var i = 0
        while i < bytes.count {
            if p[i] == 0 { return false }
            if UInt8(bitPattern: p[i]) != bytes[i] { return false }
            i += 1
        }
        return p[i] == 0
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
    _ = envp

    var check = false
    var requireStatic6 = false
    var ai: Int32 = 1
    while ai < argc {
        let arg = argv?[Int(ai)]
        if argEquals(arg, "--check") {
            check = true
        } else if argEquals(arg, "--require-static6") {
            check = true
            requireStatic6 = true
        } else {
            put("netinfo: usage netinfo [--check] [--require-static6]\n")
            return 2
        }
        ai += 1
    }

    let rc = swiftos_netinfo_refresh()
    if rc != 0 {
        put("netinfo: unavailable\n")
        return 1
    }

    let flags = swiftos_net_flags()
    let ipv4 = swiftos_net_ipv4()
    let gateway4 = swiftos_net_gateway4()
    let dns4 = swiftos_net_dns4()
    let mask4 = swiftos_net_mask4()
    let prefix4 = prefixLenFromMask(mask4)
    let prefix6 = swiftos_net_ipv6_prefix_len()

    put("netinfo: ready ")
    put((flags & flagReady) != 0 ? "yes\n" : "no\n")

    put("netinfo: ipv4 ")
    printIPv4(ipv4)
    swiftos_putc(0x2F)
    printUInt(prefix4)
    put(" source ")
    put((flags & flagDHCP4) != 0 ? "dhcp\n" : "fallback\n")

    put("netinfo: gateway4 ")
    printIPv4(gateway4)
    swiftos_putc(0x0A)

    put("netinfo: dns4 ")
    printIPv4(dns4)
    swiftos_putc(0x0A)

    put("netinfo: ipv6 ")
    printIPv6(false)
    put(" prefix ")
    printUInt(UInt(prefix6))
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
    if check {
        var ok = true
        if (flags & flagReady) == 0 || ipv4 == 0 || prefix4 == 0 || gateway4 == 0 || dns4 == 0 {
            ok = false
            put("netinfo: check failed ipv4\n")
        }
        if requireStatic6 {
            if (flags & flagStatic6) == 0 || (flags & flagGateway6) == 0 || prefix6 != 64 {
                ok = false
                put("netinfo: check failed static6\n")
            }
        }
        if ok {
            put("netinfo: check ok\n")
        }
        return ok ? 0 : 2
    }
    return 0
}
