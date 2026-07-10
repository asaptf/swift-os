// SPDX-License-Identifier: Apache-2.0
// tcpget.swift — native Swift `/bin/tcpget` for swift-os (net-d demo).
//
// A minimal TCP client: connect to [host] [port] (default 10.0.2.2:5555 — the
// QEMU slirp host alias), send one request line, read the reply, print it, and
// close. `host` may be a dotted IPv4 address or a DNS name (resolved via the
// kernel resolve syscall). Optional args 3–4 pin the DNS server IP and port for
// hermetic tests (same pattern as /bin/nslookup). Exercises the active-open path
// (resolve → socket → connect → write/read → close) through the swiftos_* bridge.
// Pair it with a host server, e.g. `printf 'srv-reply\n' | nc -l 5555`, when QEMU
// has a user-net NIC attached.

private func cstrlen(_ p: UnsafePointer<CChar>) -> Int {
    var n = 0; while p[n] != 0 { n += 1 }; return n
}

private func printUInt(_ v: UInt) {
    if v >= 10 { printUInt(v / 10) }
    swiftos_putc(UInt8(0x30 + (v % 10)))
}

/// Parse a dotted-decimal IPv4 (e.g. "10.0.2.2") into host order, or nil.
private func parseIPv4(_ p: UnsafePointer<CChar>) -> UInt32? {
    var octets = [UInt32](repeating: 0, count: 4)
    var idx = 0, cur: UInt32 = 0, digits = 0, i = 0
    while true {
        let ch = p[i]
        if ch >= 0x30 && ch <= 0x39 {
            cur = cur * 10 + UInt32(ch - 0x30)
            if cur > 255 { return nil }
            digits += 1
        } else if ch == 0x2E || ch == 0 {           // '.' or NUL
            if digits == 0 || idx > 3 { return nil }
            octets[idx] = cur; idx += 1; cur = 0; digits = 0
            if ch == 0 { break }
        } else {
            return nil
        }
        i += 1
    }
    if idx != 4 { return nil }
    return (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]
}

/// Parse an unsigned decimal port (or any small UInt) from a C string.
private func parseUInt(_ p: UnsafePointer<CChar>) -> UInt? {
    var v: UInt = 0, i = 0, digits = 0
    while p[i] >= 0x30 && p[i] <= 0x39 {
        v = v * 10 + UInt(p[i] - 0x30)
        digits += 1
        i += 1
        if digits > 10 { return nil }
    }
    if digits == 0 || p[i] != 0 { return nil }
    return v
}

private func printIPv4(_ ip: UInt32) {
    printUInt(UInt((ip >> 24) & 0xFF))
    swiftos_putc(0x2E)
    printUInt(UInt((ip >> 16) & 0xFF))
    swiftos_putc(0x2E)
    printUInt(UInt((ip >> 8) & 0xFF))
    swiftos_putc(0x2E)
    printUInt(UInt(ip & 0xFF))
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp

    var ip: UInt32 = 0x0A00_0202     // 10.0.2.2 (slirp host alias)
    var port: UInt16 = 5555
    var resolvedByName = false

    // argv[1] = host (IP or name); argv[2] = port; argv[3]/[4] = optional DNS IP/port.
    if argc >= 2, let hostArg = argv?[1] {
        if let parsed = parseIPv4(hostArg) {
            ip = parsed
        } else {
            var dnsIP: UInt32 = 0
            var dnsPort: UInt16 = 0
            if argc >= 4, let a = argv?[3], let dip = parseIPv4(a) { dnsIP = dip }
            if argc >= 5, let a = argv?[4], let dp = parseUInt(a), dp > 0, dp <= 65535 {
                dnsPort = UInt16(dp)
            }
            let resolved = swiftos_resolve(hostArg, dnsIP, dnsPort)
            if resolved == 0 {
                swiftos_puts("tcpget: resolve failed\n")
                return 1
            }
            ip = resolved
            resolvedByName = true
            swiftos_puts("tcpget: resolved ")
            _ = swiftos_write(1, UnsafeRawPointer(hostArg), UInt(cstrlen(hostArg)))
            swiftos_puts(" -> ")
            printIPv4(ip)
            swiftos_putc(0x0A)
        }
    }
    if argc >= 3, let a = argv?[2], let v = parseUInt(a), v > 0, v <= 65535 {
        port = UInt16(v)
    }

    let fd = swiftos_socket_stream()
    if fd < 0 { swiftos_puts("tcpget: socket failed\n"); return 1 }
    if swiftos_connect(fd, ip, port) != 0 {
        swiftos_puts("tcpget: connect failed\n"); _ = swiftos_close(fd); return 1
    }
    if resolvedByName {
        swiftos_puts("tcpget: connected by name\n")
    } else {
        swiftos_puts("tcpget: connected\n")
    }

    let request: [UInt8] = [0x47, 0x45, 0x54, 0x20, 0x73, 0x77, 0x6F, 0x73, 0x0A]  // "GET swos\n"
    let wrote = request.withUnsafeBytes { swiftos_write(fd, $0.baseAddress, UInt($0.count)) }
    swiftos_puts("tcpget: sent ")
    printUInt(UInt(wrote >= 0 ? wrote : 0))
    swiftos_puts(" bytes\n")

    let n = withUnsafeTemporaryAllocation(byteCount: 2048, alignment: 16) { raw -> Int in
        let r = swiftos_read(fd, raw.baseAddress, UInt(raw.count))
        if r > 0 {
            swiftos_puts("tcpget: got ")
            printUInt(UInt(r))
            swiftos_puts(" bytes: ")
            _ = swiftos_write(1, raw.baseAddress, UInt(r))
        }
        return r
    }
    if n <= 0 { swiftos_puts("tcpget: no reply\n") }
    _ = swiftos_close(fd)
    return 0
}
