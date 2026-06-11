// SPDX-License-Identifier: Apache-2.0
// sshd.swift — SSH server transport preflight for swift-os.
//
// This is not a complete SSH daemon yet. It proves the deployment-critical
// server shape: bind guest TCP/22, accept a normal OpenSSH client, exchange SSH
// identification strings, then send a valid unencrypted SSH_MSG_DISCONNECT.
// The next milestone adds KEX, host keys, userauth, and a session channel.

private let defaultPort: UInt16 = 22
private let pollIn: Int16 = 0x001
private let serverBanner: StaticString = "SSH-2.0-swift-os_sshd-preauth\r\n"
private let disconnectText: StaticString =
    "swift-os sshd transport preflight: key exchange/auth not enabled yet"

private func writeStr(_ fd: Int32, _ s: StaticString) {
    s.withUTF8Buffer { _ = swiftos_write(fd, $0.baseAddress, UInt($0.count)) }
}

private func printUInt(_ v: UInt) {
    if v >= 10 { printUInt(v / 10) }
    swiftos_putc(UInt8(0x30 + (v % 10)))
}

private func parsePort(_ p: UnsafePointer<CChar>) -> UInt16? {
    var i = 0
    var value: UInt = 0
    var sawDigit = false
    while p[i] != 0 {
        let c = p[i]
        if c < 0x30 || c > 0x39 { return nil }
        sawDigit = true
        value = value * 10 + UInt(c - 0x30)
        if value == 0 || value > 65535 { return nil }
        i += 1
    }
    return sawDigit ? UInt16(value) : nil
}

private func chosenPort(_ argc: Int32,
                        _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> UInt16 {
    guard argc >= 2, let av = argv else { return defaultPort }
    if let a1 = av[1] {
        if a1[0] == 0x2D, a1[1] == 0x70, a1[2] == 0, argc >= 3, let a2 = av[2],
           let p = parsePort(a2) {
            return p
        }
        if let p = parsePort(a1) { return p }
    }
    return defaultPort
}

private func putU32BE(_ p: UnsafeMutableRawPointer, _ off: Int, _ v: UInt32) {
    p.storeBytes(of: UInt8((v >> 24) & 0xFF), toByteOffset: off, as: UInt8.self)
    p.storeBytes(of: UInt8((v >> 16) & 0xFF), toByteOffset: off + 1, as: UInt8.self)
    p.storeBytes(of: UInt8((v >> 8) & 0xFF), toByteOffset: off + 2, as: UInt8.self)
    p.storeBytes(of: UInt8(v & 0xFF), toByteOffset: off + 3, as: UInt8.self)
}

private func pollReadable(_ fd: Int32, _ timeoutMs: Int) -> Bool {
    withUnsafeTemporaryAllocation(byteCount: 8, alignment: 8) { raw -> Bool in
        let base = raw.baseAddress!
        base.storeBytes(of: fd, toByteOffset: 0, as: Int32.self)
        base.storeBytes(of: pollIn, toByteOffset: 4, as: Int16.self)
        base.storeBytes(of: Int16(0), toByteOffset: 6, as: Int16.self)
        return swiftos_poll(base, 1, timeoutMs) > 0
    }
}

private func readClientBanner(_ fd: Int32,
                              _ out: UnsafeMutableBufferPointer<UInt8>) -> Int {
    var used = 0
    while used < out.count - 1 {
        if !pollReadable(fd, 5000) { return -1 }
        let r = swiftos_read(fd, UnsafeMutableRawPointer(out.baseAddress! + used),
                             UInt(out.count - 1 - used))
        if r <= 0 { return -1 }
        used += Int(r)
        var i = 0
        while i < used {
            if out[i] == 0x0A {
                var len = i
                if len > 0 && out[len - 1] == 0x0D { len -= 1 }
                out[len] = 0
                return len
            }
            i += 1
        }
    }
    out[out.count - 1] = 0
    return out.count - 1
}

private func isSSHBanner(_ p: UnsafePointer<UInt8>, _ len: Int) -> Bool {
    if len < 4 { return false }
    return p[0] == 0x53 && p[1] == 0x53 && p[2] == 0x48 && p[3] == 0x2D
}

private func sendPreauthDisconnect(_ fd: Int32) {
    disconnectText.withUTF8Buffer { desc in
        let descLen = desc.count
        let payloadLen = 1 + 4 + 4 + descLen + 4
        var padLen = (8 - ((4 + 1 + payloadLen) & 7)) & 7
        if padLen < 4 { padLen += 8 }
        let packetLen = 1 + payloadLen + padLen
        let totalLen = 4 + packetLen

        withUnsafeTemporaryAllocation(byteCount: totalLen, alignment: 8) { raw in
            let p = raw.baseAddress!
            putU32BE(p, 0, UInt32(packetLen))
            p.storeBytes(of: UInt8(padLen), toByteOffset: 4, as: UInt8.self)
            var w = 5
            p.storeBytes(of: UInt8(1), toByteOffset: w, as: UInt8.self) // SSH_MSG_DISCONNECT
            w += 1
            putU32BE(p, w, 11) // SSH_DISCONNECT_BY_APPLICATION
            w += 4
            putU32BE(p, w, UInt32(descLen))
            w += 4
            var i = 0
            while i < descLen {
                p.storeBytes(of: desc[i], toByteOffset: w + i, as: UInt8.self)
                i += 1
            }
            w += descLen
            putU32BE(p, w, 0) // empty language tag
            w += 4
            i = 0
            while i < padLen {
                p.storeBytes(of: UInt8(0xA5 ^ UInt8(i & 0xFF)),
                             toByteOffset: w + i,
                             as: UInt8.self)
                i += 1
            }
            _ = swiftos_write(fd, p, UInt(totalLen))
        }
    }
}

private func serveOne(_ fd: Int32) {
    writeStr(fd, serverBanner)
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 256) { line in
        let n = readClientBanner(fd, line)
        if n > 0 && isSSHBanner(UnsafePointer(line.baseAddress!), n) {
            swiftos_puts("sshd: client ")
            _ = swiftos_write(1, line.baseAddress, UInt(n))
            swiftos_puts("\n")
            sendPreauthDisconnect(fd)
            swiftos_puts("sshd: sent preauth disconnect\n")
        } else {
            swiftos_puts("sshd: invalid client banner\n")
        }
    }
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp
    let port = chosenPort(argc, argv)
    let lfd = swiftos_socket_stream()
    if lfd < 0 { swiftos_puts("sshd: socket failed\n"); return 1 }
    if swiftos_bind(lfd, port) != 0 {
        swiftos_puts("sshd: bind failed\n")
        _ = swiftos_close(lfd)
        return 1
    }
    if swiftos_listen(lfd, 4) != 0 {
        swiftos_puts("sshd: listen failed\n")
        _ = swiftos_close(lfd)
        return 1
    }
    swiftos_puts("sshd: listening on ")
    printUInt(UInt(port))
    swiftos_puts(" (transport preflight)\n")

    while true {
        let cfd = swiftos_accept(lfd)
        if cfd < 0 {
            swiftos_puts("sshd: accept failed\n")
            _ = swiftos_close(lfd)
            return 1
        }
        serveOne(cfd)
        _ = swiftos_close(cfd)
    }
}
