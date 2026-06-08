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

/// Parse a full 8-group hex IPv6 (e.g. 2001:0db8:0000:... no :: compression) to 16 network bytes, or nil.
private func parseIPv6(_ p: UnsafePointer<CChar>) -> [UInt8]? {
    var bytes = [UInt8](repeating: 0, count: 16)
    var i = 0, g = 0
    while g < 8 {
        var val: UInt16 = 0
        var digits = 0
        while true {
            let ch = p[i]
            if ch == 0 { break }
            let d: UInt16
            if ch >= 0x30 && ch <= 0x39 { d = UInt16(ch - 0x30) }
            else if ch >= 0x61 && ch <= 0x66 { d = 10 + UInt16(ch - 0x61) }
            else if ch >= 0x41 && ch <= 0x46 { d = 10 + UInt16(ch - 0x41) }
            else { break }
            val = (val << 4) | d
            digits += 1
            if digits > 4 { return nil }
            i += 1
        }
        if digits == 0 { return nil }
        bytes[g*2] = UInt8(val >> 8)
        bytes[g*2 + 1] = UInt8(val & 0xFF)
        g += 1
        if g < 8 {
            if p[i] != 0x3A { return nil }
            i += 1
        } else if p[i] != 0 {
            return nil
        }
    }
    return bytes
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

// Minimal DNS A/AAAA query/response handling in userland (for AAAA support and
// IPv6 server reachability). Uses the bridge UDP (v4 or v6). Returns (ok, v4, v6bytes).
private func directResolveAAAA(_ name: UnsafePointer<CChar>, nameLen: Int,
                               serverIP: UInt32, serverIP6: [UInt8]?,
                               serverPort: UInt16, wantAAAA: Bool) -> (Bool, UInt32, [UInt8]) {
    let v6Server = serverIP6 != nil
    let fd = v6Server ? swiftos_socket_ipv6() : swiftos_socket()
    if fd < 0 { return (false, 0, [UInt8](repeating: 0, count: 16)) }
    // implicit bind on send; use ephemeral

    let id: UInt16 = 0xBEEF
    let qtype: UInt16 = wantAAAA ? 28 : 1   // AAAA=28, A=1
    let qclass: UInt16 = 1

    let result = withUnsafeTemporaryAllocation(byteCount: 1024, alignment: 16) { raw -> (Bool, UInt32, [UInt8]) in
        let q = raw.baseAddress!
        // header
        q.storeBytes(of: id.bigEndian, toByteOffset: 0, as: UInt16.self)
        q.storeBytes(of: UInt16(0x0100).bigEndian, toByteOffset: 2, as: UInt16.self) // flags RD
        q.storeBytes(of: UInt16(1).bigEndian, toByteOffset: 4, as: UInt16.self) // qd=1
        q.storeBytes(of: UInt16(0).bigEndian, toByteOffset: 6, as: UInt16.self)
        q.storeBytes(of: UInt16(0).bigEndian, toByteOffset: 8, as: UInt16.self)
        q.storeBytes(of: UInt16(0).bigEndian, toByteOffset: 10, as: UInt16.self)
        var off = 12
        // qname
        var start = 0
        var j = 0
        while j <= nameLen {
            let atEnd = (j == nameLen)
            let isDot = !atEnd && name[j] == 0x2E
            if isDot || atEnd {
                let llen = j - start
                if llen > 0 && llen <= 63 {
                    q.storeBytes(of: UInt8(llen), toByteOffset: off, as: UInt8.self); off += 1
                    var k=0; while k<llen { q.storeBytes(of: UInt8(bitPattern: name[start+k]), toByteOffset: off, as: UInt8.self); off+=1; k+=1 }
                }
                start = j + 1
            }
            if atEnd { break }
            j += 1
        }
        q.storeBytes(of: UInt8(0), toByteOffset: off, as: UInt8.self); off += 1
        q.storeBytes(of: qtype.bigEndian, toByteOffset: off, as: UInt16.self); off += 2
        q.storeBytes(of: qclass.bigEndian, toByteOffset: off, as: UInt16.self); off += 2
        let qlen = off

        let sport = serverPort == 0 ? UInt16(53) : serverPort
        let sendOK: Int
        if v6Server {
            let s6 = serverIP6!
            sendOK = s6.withUnsafeBufferPointer { bp in
                Int(swiftos_sendto_ipv6(fd, q, UInt(qlen), bp.baseAddress!, sport))
            }
        } else {
            sendOK = Int(swiftos_sendto(fd, q, UInt(qlen), serverIP, sport))
        }
        if sendOK <= 0 { return (false, 0, [UInt8](repeating: 0, count: 16)) }

        // recv response into the second half of the scratch allocation
        let r = q.advanced(by: 512)
        var srcp: UInt16 = 0
        var src6 = [UInt8](repeating: 0, count: 16)
        let n: Int
        if v6Server {
            n = src6.withUnsafeMutableBufferPointer { bp in
                Int(swiftos_recvfrom_ipv6(fd, r, 512, bp.baseAddress!, &srcp))
            }
        } else {
            var src4: UInt32 = 0
            n = Int(swiftos_recvfrom(fd, r, 512, &src4, &srcp))
        }
        if n < 12 { return (false, 0, [UInt8](repeating: 0, count: 16)) }

        // basic parse (id, response, rcode=0, find first matching answer)
        let rid = UInt16((UInt16(r.load(fromByteOffset: 0, as: UInt8.self)) << 8) |
                         UInt16(r.load(fromByteOffset: 1, as: UInt8.self)))
        if rid != id { return (false, 0, [UInt8](repeating: 0, count: 16)) }
        let flags = UInt16((UInt16(r.load(fromByteOffset: 2, as: UInt8.self)) << 8) |
                           UInt16(r.load(fromByteOffset: 3, as: UInt8.self)))
        if (flags & 0x8000) == 0 { return (false, 0, [UInt8](repeating: 0, count: 16)) }
        if (flags & 0x000F) != 0 { return (false, 0, [UInt8](repeating: 0, count: 16)) }
        let ancount = Int((UInt16(r.load(fromByteOffset: 6, as: UInt8.self)) << 8) |
                          UInt16(r.load(fromByteOffset: 7, as: UInt8.self)))
        if ancount == 0 { return (false, 0, [UInt8](repeating: 0, count: 16)) }

        // skip qd (assume 1)
        off = 12
        // skip qname + qtype+qclass (4)
        while off < n && r.load(fromByteOffset: off, as: UInt8.self) != 0 {
            if (r.load(fromByteOffset: off, as: UInt8.self) & 0xC0) == 0xC0 {
                off += 2
                break
            }
            off += 1 + Int(r.load(fromByteOffset: off, as: UInt8.self))
        }
        off += 1 + 4  // term + type/class

        for _ in 0..<ancount {
            // name skip
            while off < n {
                let b = r.load(fromByteOffset: off, as: UInt8.self)
                if b == 0 {
                    off += 1
                    break
                }
                if (b & 0xC0) == 0xC0 {
                    off += 2
                    break
                }
                off += 1 + Int(b)
            }
            if off + 10 > n { break }
            let rtype = UInt16((UInt16(r.load(fromByteOffset: off, as: UInt8.self)) << 8) |
                               UInt16(r.load(fromByteOffset: off + 1, as: UInt8.self)))
            let rdlen = Int((UInt16(r.load(fromByteOffset: off + 8, as: UInt8.self)) << 8) |
                            UInt16(r.load(fromByteOffset: off + 9, as: UInt8.self)))
            off += 10
            if off + rdlen > n { break }
            if wantAAAA && rtype == 28 && rdlen == 16 {
                var res = [UInt8](repeating: 0, count: 16)
                for k in 0..<16 { res[k] = r.load(fromByteOffset: off + k, as: UInt8.self) }
                return (true, 0, res)
            }
            if !wantAAAA && rtype == 1 && rdlen == 4 {
                let v4 = (UInt32(r.load(fromByteOffset: off, as: UInt8.self)) << 24) |
                         (UInt32(r.load(fromByteOffset: off + 1, as: UInt8.self)) << 16) |
                         (UInt32(r.load(fromByteOffset: off + 2, as: UInt8.self)) << 8) |
                         UInt32(r.load(fromByteOffset: off + 3, as: UInt8.self))
                return (true, v4, [UInt8](repeating: 0, count: 16))
            }
            off += rdlen
        }
        return (false, 0, [UInt8](repeating: 0, count: 16))
    }
    _ = swiftos_close(fd)
    return result
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp
    guard argc >= 2, let argv = argv, let nameArg = argv[1] else {
        swiftos_puts("usage: nslookup <name> [server-ip] [port] [AAAA]\n")
        return 1
    }

    var serverIP: UInt32 = 0
    var serverIP6: [UInt8]? = nil
    if argc >= 3, let a = argv[2] {
        serverIP = parseIPv4(a)
        if serverIP == 0 {
            serverIP6 = parseIPv6(a)
        }
    }
    var port: UInt16 = 0
    if argc >= 4, let a = argv[3] {
        var v: UInt = 0, i = 0
        while a[i] >= 0x30 && a[i] <= 0x39 { v = v * 10 + UInt(a[i] - 0x30); i += 1 }
        if v > 0 && v <= 65535 { port = UInt16(v) }
    }
    let wantAAAA: Bool = (argc >= 5) && argv[4] != nil && argv[4]![0] == 0x41 /*A*/ && argv[4]![1] == 0x41 && argv[4]![2] == 0x41 && argv[4]![3] == 0x41

    _ = swiftos_write(1, UnsafeRawPointer(nameArg), UInt(cstrlen(nameArg)))

    if !wantAAAA && serverIP6 == nil {
        // compat path: kernel A-only resolve (v4 server)
        let ip = swiftos_resolve(nameArg, serverIP, port)
        if ip == 0 {
            swiftos_puts(": not found\n")
            return 1
        }
        swiftos_puts(" -> ")
        printIPv4(ip)
        swiftos_putc(0x0A)
        return 0
    }

    // Direct path for AAAA or IPv6 DNS server (exercises userland UDPv4/v6 + DNS codec in tool)
    let nameLen = cstrlen(nameArg)
    let (ok, v4, v6) = directResolveAAAA(nameArg, nameLen: nameLen, serverIP: serverIP, serverIP6: serverIP6, serverPort: port, wantAAAA: wantAAAA)
    if !ok {
        swiftos_puts(": not found\n")
        return 1
    }
    swiftos_puts(" -> ")
    if wantAAAA {
        printIPv6(v6)
    } else {
        printIPv4(v4)
    }
    swiftos_putc(0x0A)
    return 0
}
