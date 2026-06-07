// SPDX-License-Identifier: Apache-2.0
// tlsget.swift — native Swift `/bin/tlsget`: a minimal HTTPS (TLS 1.3) client.
//
// Usage: tlsget [ip] [port] [host]
//   ip    dotted-decimal IPv4 of the server   (default 10.0.2.2 — slirp host)
//   port  TCP port                             (default 443)
//   host  Host: header / SNI-less name shown   (default "localhost")
//
// It opens a TCP stream (socket → connect, like /bin/tcpget), then drives the
// sans-IO TLS 1.3 engine in userland/lib/tls13.swift over swiftos_read/write:
//   socket → connect → ClientHello → (read/feed/advance, draining out) → done →
//   encrypted "GET / HTTP/1.1" → read+decrypt the response body → print it.
// The crypto + tls13 sources are compiled INTO this ELF (see the Makefile rule),
// so the same TLS code is exercised here and by the host tls_handshake_test.
//
// ⚠️  NO CERTIFICATE VERIFICATION. tls13.swift accepts ANY server certificate
//     (chain, signature, name and expiry are all unchecked) — confidentiality
//     against a passive eavesdropper only, NOT authentication. X.509 verification
//     is deliberately deferred to a later track; see the tls13.swift header. This
//     tool exists to bring the TLS 1.3 record/handshake machinery up end-to-end.

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
        } else if ch == 0x2E || ch == 0 {            // '.' or NUL
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

// Fill `buf` with `n` pseudo-random bytes. There is NO kernel entropy source on
// swift-os yet (see arc4random_buf in swift_user.c), so we mix the few varying
// quantities we have — wall-clock seconds, pid, and a stack address — through a
// splitmix64 PRNG. This is NOT cryptographically strong; it is acceptable here
// only because the TLS client already provides no authentication (cert checks
// are deferred) and the demo server is local. A real client needs getrandom(2).
private func fillRandom(_ buf: UnsafeMutableRawPointer, _ n: Int) {
    var probe: UInt64 = 0
    var x = UInt64(swiftos_time())
        ^ (UInt64(bitPattern: Int64(swiftos_getpid())) &* 0x9E37_79B9_7F4A_7C15)
        ^ withUnsafeMutablePointer(to: &probe) { UInt64(UInt(bitPattern: $0)) }
    if x == 0 { x = 0x9E37_79B9_7F4A_7C15 }
    for i in 0..<n {
        x = x &* 6364136223846793005 &+ 1442695040888963407
        var z = x
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        buf.storeBytes(of: UInt8((z >> 24) & 0xFF), toByteOffset: i, as: UInt8.self)
    }
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp

    var ip: UInt32 = 0x0A00_0202     // 10.0.2.2 (slirp host alias)
    var port: UInt16 = 443
    if argc >= 2, let a = argv?[1], let parsed = parseIPv4(a) { ip = parsed }
    if argc >= 3, let a = argv?[2] {
        var v: UInt = 0, i = 0
        while a[i] >= 0x30 && a[i] <= 0x39 { v = v * 10 + UInt(a[i] - 0x30); i += 1 }
        if v > 0 && v <= 65535 { port = UInt16(v) }
    }

    // ---- TCP connect (active open) ----
    let fd = swiftos_socket_stream()
    if fd < 0 { swiftos_puts("tlsget: socket failed\n"); return 1 }
    if swiftos_connect(fd, ip, port) != 0 {
        swiftos_puts("tlsget: connect failed\n"); _ = swiftos_close(fd); return 1
    }
    swiftos_puts("tlsget: connected\n")

    // ---- TLS 1.3 handshake (sans-IO engine driven over the socket) ----
    let client = TLS13Client()
    var sk = [UInt8](repeating: 0, count: 32)
    var ch = [UInt8](repeating: 0, count: 32)
    sk.withUnsafeMutableBytes { fillRandom($0.baseAddress!, 32) }
    ch.withUnsafeMutableBytes { fillRandom($0.baseAddress!, 32) }
    sk.withUnsafeBytes { skp in
        ch.withUnsafeBytes { chp in
            client.startHandshake(randomSK: skp.baseAddress!, randomCH: chp.baseAddress!)
        }
    }

    // Drain any queued outbound TLS bytes to the socket.
    func flushOut() -> Bool {
        while client.pendingOut > 0 {
            let ok = withUnsafeTemporaryAllocation(byteCount: tlsMaxRecord, alignment: 16) { raw -> Bool in
                let n = client.takeTLS(raw.baseAddress!, raw.count)
                if n <= 0 { return true }
                var off = 0
                while off < n {
                    let w = swiftos_write(fd, raw.baseAddress!.advanced(by: off), UInt(n - off))
                    if w <= 0 { return false }
                    off += Int(w)
                }
                return true
            }
            if !ok { return false }
        }
        return true
    }

    if !flushOut() { swiftos_puts("tlsget: write failed\n"); _ = swiftos_close(fd); return 1 }

    // Read → feed → advance until the handshake completes or fails. The first
    // advance() may already report completion if everything is buffered.
    var done = false
    var failed = false
    let rxCap = tlsMaxRecord
    let buf = UnsafeMutableRawPointer.allocate(byteCount: rxCap, alignment: 16)
    defer { buf.deallocate() }

    switch client.advance() {
    case .handshakeComplete: done = true
    case .failed:            failed = true
    case .needMoreData:      break
    }

    while !done && !failed {
        let r = swiftos_read(fd, buf, UInt(rxCap))
        if r <= 0 { failed = true; break }              // peer closed mid-handshake
        client.feedTLS(buf, Int(r))
        switch client.advance() {
        case .handshakeComplete: done = true
        case .failed:            failed = true
        case .needMoreData:      break
        }
        if !flushOut() { failed = true; break }          // client Finished etc.
    }

    if failed || !done {
        swiftos_puts("tlsget: handshake failed (err ")
        printUInt(UInt(client.lastError))
        swiftos_puts(")\n")
        _ = swiftos_close(fd)
        return 1
    }
    // The client Finished is queued during the completing advance(); flush it.
    if !flushOut() { swiftos_puts("tlsget: write failed\n"); _ = swiftos_close(fd); return 1 }
    swiftos_puts("tlsget: handshake complete\n")

    // ---- Encrypted HTTP/1.1 GET ----
    // Minimal request; Connection: close lets the server end the body with EOF.
    var req = [UInt8]()
    req.append(contentsOf: Array("GET / HTTP/1.1\r\nHost: ".utf8))
    if argc >= 4, let h = argv?[3] {
        var i = 0; while h[i] != 0 { req.append(UInt8(bitPattern: h[i])); i += 1 }
    } else {
        req.append(contentsOf: Array("localhost".utf8))
    }
    req.append(contentsOf: Array("\r\nConnection: close\r\n\r\n".utf8))
    req.withUnsafeBytes { client.sendAppData($0.baseAddress!, $0.count) }
    if !flushOut() { swiftos_puts("tlsget: write failed\n"); _ = swiftos_close(fd); return 1 }

    // ---- Read + decrypt the response, print application data to stdout ----
    swiftos_puts("tlsget: body:\n")
    var total = 0
    while true {
        let r = swiftos_read(fd, buf, UInt(rxCap))
        if r <= 0 { break }                              // server closed (EOF)
        client.feedTLS(buf, Int(r))
        switch client.advance() {
        case .failed:
            // A close_notify alert lands here; if we already have body bytes it
            // is a clean end, otherwise report it.
            if client.pendingAppData == 0 && total == 0 {
                swiftos_puts("tlsget: read error (err ")
                printUInt(UInt(client.lastError))
                swiftos_puts(")\n")
            }
        default:
            break
        }
        while client.pendingAppData > 0 {
            let n = client.receiveAppData(buf, rxCap)
            if n <= 0 { break }
            _ = swiftos_write(1, buf, UInt(n))
            total += n
        }
        if client.lastError != 0 { break }               // alert / decrypt failure
    }

    swiftos_puts("\ntlsget: received ")
    printUInt(UInt(total))
    swiftos_puts(" body bytes\n")
    _ = swiftos_close(fd)
    return total > 0 ? 0 : 1
}
