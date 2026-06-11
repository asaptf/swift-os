// SPDX-License-Identifier: Apache-2.0
// sshd.swift — SSH server session preflight for swift-os.
//
// This is still not a complete SSH login daemon. It proves the modern transport
// and pre-login path that Hetzner-style remote access needs next: TCP/22, SSH
// identification, curve25519-sha256, ssh-ed25519 host authentication,
// chacha20-poly1305, Ed25519 publickey user auth, and one direct session/exec
// command. PTY, shells, scp/sftp, a full service manager, and real entropy are
// separate milestones.

private let defaultPort: UInt16 = 22
private let pollIn: Int16 = 0x001
private let serverVersion: StaticString = "SSH-2.0-swift-os_sshd-session"
private let serverBanner: StaticString = "SSH-2.0-swift-os_sshd-session\r\n"
private let disconnectText: StaticString =
    "swift-os sshd session preflight: unsupported request"

private let maxPacketLen = 8192
private let maxPayloadLen = 7800
private let sshBlockSize = 8
private let maxExecCommandLen = 512
private let maxExecInputLen = 512
private let maxExecOutputLen = 4096
private let maxExecArgs = 8
private let spawnRightRead: UInt32 = 1 << 0
private let spawnRightWrite: UInt32 = 1 << 1
private let oReadOnly: Int32 = 0
private let oWriteOnly: Int32 = 1
private let oCreate: Int32 = 0x40
private let oTrunc: Int32 = 0x80

private let msgDisconnect: UInt8 = 1
private let msgServiceRequest: UInt8 = 5
private let msgServiceAccept: UInt8 = 6
private let msgUserauthRequest: UInt8 = 50
private let msgUserauthFailure: UInt8 = 51
private let msgUserauthSuccess: UInt8 = 52
private let msgUserauthPkOk: UInt8 = 60
private let msgGlobalRequest: UInt8 = 80
private let msgRequestSuccess: UInt8 = 81
private let msgRequestFailure: UInt8 = 82
private let msgChannelOpen: UInt8 = 90
private let msgChannelOpenConfirmation: UInt8 = 91
private let msgChannelOpenFailure: UInt8 = 92
private let msgChannelWindowAdjust: UInt8 = 93
private let msgChannelData: UInt8 = 94
private let msgChannelEof: UInt8 = 96
private let msgChannelClose: UInt8 = 97
private let msgChannelRequest: UInt8 = 98
private let msgChannelSuccess: UInt8 = 99
private let msgChannelFailure: UInt8 = 100

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

private func isOnceArg(_ p: UnsafePointer<CChar>) -> Bool {
    (p[0] == 0x2D && p[1] == 0x2D && p[2] == 0x6F && p[3] == 0x6E &&
     p[4] == 0x63 && p[5] == 0x65 && p[6] == 0) ||
    (p[0] == 0x2D && p[1] == 0x31 && p[2] == 0)
}

private func isSshdOnceName(_ p: UnsafePointer<CChar>) -> Bool {
    p[0] == 0x73 && p[1] == 0x73 && p[2] == 0x68 && p[3] == 0x64 &&
    p[4] == 0x2D && p[5] == 0x6F && p[6] == 0x6E && p[7] == 0x63 &&
    p[8] == 0x65 && p[9] == 0
}

private func fileRequestsOnceMode() -> Bool {
    let fd = swiftos_open("/tmp/swos-sshd-once", 0)
    if fd < 0 { return false }
    _ = swiftos_close(fd)
    return true
}

private struct SSHDConfig {
    var port: UInt16 = defaultPort
    var once: Bool = false
}

private func parseConfig(_ argc: Int32,
                         _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> SSHDConfig {
    var cfg = SSHDConfig()
    guard let av = argv else { return cfg }
    if let name = av[0], isSshdOnceName(name) {
        cfg.once = true
    }
    if argc < 2 { return cfg }
    var i: Int32 = 1
    while i < argc {
        if let arg = av[Int(i)] {
            if isOnceArg(arg) {
                cfg.once = true
            } else if arg[0] == 0x2D, arg[1] == 0x70, arg[2] == 0,
                      i + 1 < argc, let next = av[Int(i + 1)] {
                if let p = parsePort(next) { cfg.port = p }
                i += 1
            } else if let p = parsePort(arg) {
                cfg.port = p
            }
        }
        i += 1
    }
    return cfg
}

private func getU32BE(_ p: UnsafeRawPointer, _ off: Int) -> UInt32 {
    (UInt32(p.load(fromByteOffset: off, as: UInt8.self)) << 24) |
    (UInt32(p.load(fromByteOffset: off + 1, as: UInt8.self)) << 16) |
    (UInt32(p.load(fromByteOffset: off + 2, as: UInt8.self)) << 8) |
    UInt32(p.load(fromByteOffset: off + 3, as: UInt8.self))
}

private func putU32BE(_ p: UnsafeMutableRawPointer, _ off: Int, _ v: UInt32) {
    p.storeBytes(of: UInt8((v >> 24) & 0xFF), toByteOffset: off, as: UInt8.self)
    p.storeBytes(of: UInt8((v >> 16) & 0xFF), toByteOffset: off + 1, as: UInt8.self)
    p.storeBytes(of: UInt8((v >> 8) & 0xFF), toByteOffset: off + 2, as: UInt8.self)
    p.storeBytes(of: UInt8(v & 0xFF), toByteOffset: off + 3, as: UInt8.self)
}

private func copyBytes(_ dst: UnsafeMutableRawPointer, _ dstOff: Int,
                       _ src: UnsafeRawPointer, _ len: Int) {
    var i = 0
    while i < len {
        dst.storeBytes(of: src.load(fromByteOffset: i, as: UInt8.self),
                       toByteOffset: dstOff + i,
                       as: UInt8.self)
        i += 1
    }
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

private func readExact(_ fd: Int32, _ p: UnsafeMutableRawPointer, _ len: Int,
                       _ timeoutMs: Int = 5000) -> Bool {
    var off = 0
    while off < len {
        if !pollReadable(fd, timeoutMs) { return false }
        let r = swiftos_read(fd, p + off, UInt(len - off))
        if r <= 0 { return false }
        off += Int(r)
    }
    return true
}

private func writeExact(_ fd: Int32, _ p: UnsafeRawPointer, _ len: Int) -> Bool {
    var off = 0
    while off < len {
        let w = swiftos_write(fd, p + off, UInt(len - off))
        if w <= 0 { return false }
        off += Int(w)
    }
    return true
}

private func readClientBanner(_ fd: Int32,
                              _ out: UnsafeMutableBufferPointer<UInt8>) -> Int {
    var used = 0
    while used < out.count - 1 {
        if !pollReadable(fd, 5000) { return -1 }
        let r = swiftos_read(fd, UnsafeMutableRawPointer(out.baseAddress! + used), 1)
        if r <= 0 { return -1 }
        used += Int(r)
        if out[used - 1] == 0x0A {
            var len = used - 1
            if len > 0 && out[len - 1] == 0x0D { len -= 1 }
            out[len] = 0
            return len
        }
    }
    out[out.count - 1] = 0
    return out.count - 1
}

private func isSSHBanner(_ p: UnsafePointer<UInt8>, _ len: Int) -> Bool {
    len >= 4 && p[0] == 0x53 && p[1] == 0x53 && p[2] == 0x48 && p[3] == 0x2D
}

private func fillPseudoRandom(_ p: UnsafeMutableRawPointer, _ len: Int, _ domain: UInt64) {
    var probe: UInt64 = 0
    var x = UInt64(swiftos_time())
        ^ (UInt64(bitPattern: Int64(swiftos_getpid())) &* 0x9E37_79B9_7F4A_7C15)
        ^ withUnsafeMutablePointer(to: &probe) { UInt64(UInt(bitPattern: $0)) }
        ^ domain
    if x == 0 { x = 0xD1B5_4A32_D192_ED03 }
    var i = 0
    while i < len {
        x = x &* 6364136223846793005 &+ 1442695040888963407
        var z = x
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        p.storeBytes(of: UInt8((z >> 24) & 0xFF), toByteOffset: i, as: UInt8.self)
        i += 1
    }
}

private func hexNibble(_ c: UInt8) -> UInt8? {
    if c >= 0x30 && c <= 0x39 { return c - 0x30 }
    if c >= 0x61 && c <= 0x66 { return c - 0x61 + 10 }
    if c >= 0x41 && c <= 0x46 { return c - 0x41 + 10 }
    return nil
}

private func isSeedSpace(_ c: UInt8) -> Bool {
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
}

private func readHostKeySeed(_ out32: UnsafeMutableRawPointer) -> Bool {
    let fd = swiftos_open("/etc/ssh/ssh_host_ed25519_seed", 0)
    guard fd >= 0 else {
        swiftos_puts("sshd: host key seed missing /etc/ssh/ssh_host_ed25519_seed\n")
        return false
    }
    defer { _ = swiftos_close(fd) }

    return withUnsafeTemporaryAllocation(byteCount: 160, alignment: 1) { raw -> Bool in
        var used = 0
        while used < raw.count {
            let r = swiftos_read(fd, raw.baseAddress! + used, UInt(raw.count - used))
            if r < 0 {
                swiftos_puts("sshd: host key seed read failed\n")
                return false
            }
            if r == 0 { break }
            used += Int(r)
        }
        if used == raw.count {
            let extraRead = withUnsafeTemporaryAllocation(byteCount: 1, alignment: 1) { extra -> Int in
                swiftos_read(fd, extra.baseAddress!, 1)
            }
            if extraRead < 0 {
                swiftos_puts("sshd: host key seed read failed\n")
                return false
            }
            if extraRead > 0 {
                swiftos_puts("sshd: host key seed too long\n")
                return false
            }
        }

        var outOff = 0
        var high: UInt8 = 0
        var haveHigh = false
        var i = 0
        while i < used {
            let c = raw.baseAddress!.load(fromByteOffset: i, as: UInt8.self)
            if c == 0x23 { // '#'
                while i < used &&
                      raw.baseAddress!.load(fromByteOffset: i, as: UInt8.self) != 0x0A {
                    i += 1
                }
                continue
            }
            if isSeedSpace(c) {
                i += 1
                continue
            }
            guard let n = hexNibble(c) else {
                swiftos_puts("sshd: host key seed invalid hex\n")
                return false
            }
            if haveHigh {
                if outOff >= 32 {
                    swiftos_puts("sshd: host key seed too long\n")
                    return false
                }
                out32.storeBytes(of: (high << 4) | n, toByteOffset: outOff, as: UInt8.self)
                outOff += 1
                haveHigh = false
            } else {
                high = n
                haveHigh = true
            }
            i += 1
        }

        guard !haveHigh, outOff == 32 else {
            swiftos_puts("sshd: host key seed wrong length\n")
            return false
        }
        swiftos_puts("sshd: loaded host key seed /etc/ssh/ssh_host_ed25519_seed\n")
        return true
    }
}

private struct SSHWriter {
    let p: UnsafeMutableRawPointer
    let cap: Int
    var len: Int = 0

    mutating func u8(_ v: UInt8) -> Bool {
        if len + 1 > cap { return false }
        p.storeBytes(of: v, toByteOffset: len, as: UInt8.self)
        len += 1
        return true
    }

    mutating func u32(_ v: UInt32) -> Bool {
        if len + 4 > cap { return false }
        putU32BE(p, len, v)
        len += 4
        return true
    }

    mutating func bytes(_ src: UnsafeRawPointer, _ n: Int) -> Bool {
        if len + n > cap { return false }
        copyBytes(p, len, src, n)
        len += n
        return true
    }

    mutating func string(_ src: UnsafeRawPointer, _ n: Int) -> Bool {
        u32(UInt32(n)) && bytes(src, n)
    }

    mutating func mpint(_ src: UnsafeRawPointer, _ n: Int) -> Bool {
        var first = 0
        while first < n && src.load(fromByteOffset: first, as: UInt8.self) == 0 { first += 1 }
        if first == n { return u32(0) }
        let bodyLen = n - first
        let high = src.load(fromByteOffset: first, as: UInt8.self)
        if (high & 0x80) != 0 {
            if !u32(UInt32(bodyLen + 1)) || !u8(0) { return false }
        } else if !u32(UInt32(bodyLen)) {
            return false
        }
        return bytes(src + first, bodyLen)
    }
}

private struct SSHStringView {
    let p: UnsafeRawPointer
    let len: Int
}

private struct SSHReader {
    let p: UnsafeRawPointer
    let len: Int
    var off: Int = 0

    var remaining: Int { len - off }

    mutating func u8() -> UInt8? {
        if off + 1 > len { return nil }
        let v = p.load(fromByteOffset: off, as: UInt8.self)
        off += 1
        return v
    }

    mutating func bool() -> Bool? {
        guard let v = u8() else { return nil }
        return v != 0
    }

    mutating func u32() -> UInt32? {
        if off + 4 > len { return nil }
        let v = getU32BE(p, off)
        off += 4
        return v
    }

    mutating func string() -> SSHStringView? {
        guard let n32 = u32() else { return nil }
        let n = Int(n32)
        if off + n > len { return nil }
        let view = SSHStringView(p: p + off, len: n)
        off += n
        return view
    }
}

private func writerStatic(_ w: inout SSHWriter, _ s: StaticString) -> Bool {
    s.withUTF8Buffer { w.bytes($0.baseAddress!, $0.count) }
}

private func writerStringStatic(_ w: inout SSHWriter, _ s: StaticString) -> Bool {
    s.withUTF8Buffer { w.string($0.baseAddress!, $0.count) }
}

private func bytesEqual(_ lhs: UnsafeRawPointer, _ rhs: UnsafeRawPointer, _ n: Int) -> Bool {
    var diff: UInt8 = 0
    var i = 0
    while i < n {
        diff |= lhs.load(fromByteOffset: i, as: UInt8.self) ^
                rhs.load(fromByteOffset: i, as: UInt8.self)
        i += 1
    }
    return diff == 0
}

private func stringEquals(_ view: SSHStringView, _ s: StaticString) -> Bool {
    s.withUTF8Buffer { sb -> Bool in
        if view.len != sb.count { return false }
        return bytesEqual(view.p, sb.baseAddress!, view.len)
    }
}

private func isAuthSpace(_ c: UInt8) -> Bool {
    c == 0x20 || c == 0x09 || c == 0x0D
}

private func base64Value(_ c: UInt8) -> Int {
    if c >= 0x41 && c <= 0x5A { return Int(c - 0x41) }
    if c >= 0x61 && c <= 0x7A { return Int(c - 0x61) + 26 }
    if c >= 0x30 && c <= 0x39 { return Int(c - 0x30) + 52 }
    if c == 0x2B { return 62 }
    if c == 0x2F { return 63 }
    return -1
}

private func decodeBase64(_ src: UnsafeRawPointer, _ len: Int,
                          _ out: UnsafeMutableRawPointer, _ cap: Int) -> Int {
    var bits = 0
    var acc: UInt32 = 0
    var outLen = 0
    var sawPad = false
    var i = 0
    while i < len {
        let c = src.load(fromByteOffset: i, as: UInt8.self)
        if c == 0x3D {
            sawPad = true
            i += 1
            continue
        }
        let v = base64Value(c)
        if v < 0 || sawPad { return -1 }
        acc = (acc << 6) | UInt32(v)
        bits += 6
        if bits >= 8 {
            bits -= 8
            if outLen >= cap { return -1 }
            out.storeBytes(of: UInt8((acc >> UInt32(bits)) & 0xFF),
                           toByteOffset: outLen,
                           as: UInt8.self)
            outLen += 1
        }
        i += 1
    }
    return outLen
}

private func nextAuthorizedToken(_ p: UnsafeRawPointer,
                                 _ lineEnd: Int,
                                 _ off: inout Int) -> SSHStringView? {
    while off < lineEnd && isAuthSpace(p.load(fromByteOffset: off, as: UInt8.self)) {
        off += 1
    }
    if off >= lineEnd { return nil }
    let start = off
    while off < lineEnd && !isAuthSpace(p.load(fromByteOffset: off, as: UInt8.self)) {
        off += 1
    }
    return SSHStringView(p: p + start, len: off - start)
}

private func ed25519PublicKeyFromBlob(_ blob: SSHStringView) -> SSHStringView? {
    var r = SSHReader(p: blob.p, len: blob.len)
    guard let alg = r.string(),
          stringEquals(alg, "ssh-ed25519"),
          let key = r.string(),
          key.len == 32,
          r.remaining == 0 else {
        return nil
    }
    return key
}

private func authorizedKeysBufferMatches(_ blob: SSHStringView,
                                         _ p: UnsafeRawPointer,
                                         _ len: Int) -> Bool {
    var lineStart = 0
    while lineStart < len {
        var lineEnd = lineStart
        while lineEnd < len && p.load(fromByteOffset: lineEnd, as: UInt8.self) != 0x0A {
            lineEnd += 1
        }

        var off = lineStart
        while off < lineEnd && isAuthSpace(p.load(fromByteOffset: off, as: UInt8.self)) {
            off += 1
        }
        if off < lineEnd && p.load(fromByteOffset: off, as: UInt8.self) != 0x23 {
            if let first = nextAuthorizedToken(p, lineEnd, &off) {
                var keyType = first
                var keyData = nextAuthorizedToken(p, lineEnd, &off)
                if !stringEquals(keyType, "ssh-ed25519"),
                   let second = keyData,
                   stringEquals(second, "ssh-ed25519") {
                    keyType = second
                    keyData = nextAuthorizedToken(p, lineEnd, &off)
                }

                if stringEquals(keyType, "ssh-ed25519"), let data = keyData {
                    let matched = withUnsafeTemporaryAllocation(byteCount: 128, alignment: 8) { decoded -> Bool in
                        let decodedLen = decodeBase64(data.p, data.len,
                                                      decoded.baseAddress!,
                                                      decoded.count)
                        return decodedLen == blob.len &&
                               bytesEqual(decoded.baseAddress!, blob.p, blob.len)
                    }
                    if matched { return true }
                }
            }
        }

        lineStart = lineEnd + 1
    }
    return false
}

private func authorizedKeyBlobMatches(_ blob: SSHStringView) -> Bool {
    guard ed25519PublicKeyFromBlob(blob) != nil else { return false }
    let fd = swiftos_open("/etc/ssh/authorized_keys", 0)
    if fd < 0 { return false }
    defer { _ = swiftos_close(fd) }

    return withUnsafeTemporaryAllocation(byteCount: 4096, alignment: 8) { raw -> Bool in
        var used = 0
        while used < raw.count {
            let r = swiftos_read(fd, raw.baseAddress! + used, UInt(raw.count - used))
            if r < 0 { return false }
            if r == 0 { break }
            used += Int(r)
        }
        let matched = authorizedKeysBufferMatches(blob, raw.baseAddress!, used)
        if matched {
            swiftos_puts("sshd: authorized key matched /etc/ssh/authorized_keys\n")
        }
        return matched
    }
}

private func makePlainPacket(_ payload: UnsafeRawPointer, _ payloadLen: Int,
                             _ out: UnsafeMutableRawPointer, _ cap: Int) -> Int {
    var padLen = sshBlockSize - ((payloadLen + 5) % sshBlockSize)
    if padLen < 4 { padLen += sshBlockSize }
    let packetLen = payloadLen + padLen + 1
    let totalLen = 4 + packetLen
    if totalLen > cap { return -1 }
    putU32BE(out, 0, UInt32(packetLen))
    out.storeBytes(of: UInt8(padLen), toByteOffset: 4, as: UInt8.self)
    copyBytes(out, 5, payload, payloadLen)
    var i = 0
    while i < padLen {
        out.storeBytes(of: UInt8(0x5A ^ UInt8((payloadLen + i) & 0xFF)),
                       toByteOffset: 5 + payloadLen + i,
                       as: UInt8.self)
        i += 1
    }
    return totalLen
}

private func makeChachaPlainPacket(_ payload: UnsafeRawPointer, _ payloadLen: Int,
                                   _ out: UnsafeMutableRawPointer, _ cap: Int) -> Int {
    var padLen = sshBlockSize - ((payloadLen + 1) % sshBlockSize)
    if padLen < 4 { padLen += sshBlockSize }
    let packetLen = payloadLen + padLen + 1
    let totalLen = 4 + packetLen
    if totalLen > cap { return -1 }
    putU32BE(out, 0, UInt32(packetLen))
    out.storeBytes(of: UInt8(padLen), toByteOffset: 4, as: UInt8.self)
    copyBytes(out, 5, payload, payloadLen)
    var i = 0
    while i < padLen {
        out.storeBytes(of: UInt8(0xA5 ^ UInt8((payloadLen + i) & 0xFF)),
                       toByteOffset: 5 + payloadLen + i,
                       as: UInt8.self)
        i += 1
    }
    return totalLen
}

private func sendPlainPacket(_ fd: Int32, _ payload: UnsafeRawPointer, _ payloadLen: Int,
                             _ seq: inout UInt32) -> Bool {
    withUnsafeTemporaryAllocation(byteCount: maxPacketLen, alignment: 8) { raw -> Bool in
        let n = makePlainPacket(payload, payloadLen, raw.baseAddress!, raw.count)
        if n <= 0 { return false }
        if !writeExact(fd, raw.baseAddress!, n) { return false }
        seq &+= 1
        return true
    }
}

private func readPlainPacket(_ fd: Int32, _ payload: UnsafeMutableRawPointer,
                             _ cap: Int, _ seq: inout UInt32) -> Int {
    var lenWord: UInt32 = 0
    let ok = withUnsafeMutableBytes(of: &lenWord) { readExact(fd, $0.baseAddress!, 4) }
    if !ok { return -1 }
    let packetLen = Int(UInt32(bigEndian: lenWord))
    if packetLen < 5 || packetLen > maxPacketLen { return -1 }

    return withUnsafeTemporaryAllocation(byteCount: packetLen, alignment: 8) { raw -> Int in
        let base = raw.baseAddress!
        if !readExact(fd, base, packetLen) { return -1 }
        let padLen = Int(base.load(fromByteOffset: 0, as: UInt8.self))
        let payloadLen = packetLen - padLen - 1
        if padLen < 4 || payloadLen < 1 || payloadLen > cap { return -1 }
        copyBytes(payload, 0, base + 1, payloadLen)
        seq &+= 1
        return payloadLen
    }
}

private func buildKexInit(_ out: UnsafeMutableRawPointer, _ cap: Int) -> Int {
    var w = SSHWriter(p: out, cap: cap)
    guard w.u8(20) else { return -1 } // SSH_MSG_KEXINIT
    fillPseudoRandom(out + w.len, 16, 0x4b4558494e495431)
    w.len += 16

    guard writerStringStatic(&w, "curve25519-sha256,curve25519-sha256@libssh.org,kex-strict-s-v00@openssh.com"),
          writerStringStatic(&w, "ssh-ed25519"),
          writerStringStatic(&w, "chacha20-poly1305@openssh.com"),
          writerStringStatic(&w, "chacha20-poly1305@openssh.com"),
          writerStringStatic(&w, "hmac-sha2-256"),
          writerStringStatic(&w, "hmac-sha2-256"),
          writerStringStatic(&w, "none"),
          writerStringStatic(&w, "none"),
          w.u32(0),
          w.u32(0),
          w.u8(0),
          w.u32(0) else {
        return -1
    }
    return w.len
}

private func buildHostKeyBlob(_ out: UnsafeMutableRawPointer, _ cap: Int,
                              _ seed: UnsafeRawPointer) -> Int {
    var pub = (UInt64(0), UInt64(0), UInt64(0), UInt64(0))
    return withUnsafeMutableBytes(of: &pub) { pb in
        ed25519PublicKey(seed: seed, publicKey: pb.baseAddress!)
        var w = SSHWriter(p: out, cap: cap)
        guard writerStringStatic(&w, "ssh-ed25519"),
              w.string(pb.baseAddress!, 32) else {
            return -1
        }
        return w.len
    }
}

private func buildSignatureBlob(_ out: UnsafeMutableRawPointer, _ cap: Int,
                                _ signature: UnsafeRawPointer) -> Int {
    var w = SSHWriter(p: out, cap: cap)
    guard writerStringStatic(&w, "ssh-ed25519"),
          w.string(signature, 64) else {
        return -1
    }
    return w.len
}

private func buildExchangeHash(_ out32: UnsafeMutableRawPointer,
                               _ clientVersion: UnsafeRawPointer, _ clientVersionLen: Int,
                               _ clientKex: UnsafeRawPointer, _ clientKexLen: Int,
                               _ serverKex: UnsafeRawPointer, _ serverKexLen: Int,
                               _ hostKey: UnsafeRawPointer, _ hostKeyLen: Int,
                               _ clientPub: UnsafeRawPointer, _ serverPub: UnsafeRawPointer,
                               _ shared: UnsafeRawPointer) -> Bool {
    withUnsafeTemporaryAllocation(byteCount: 16384, alignment: 8) { raw -> Bool in
        var w = SSHWriter(p: raw.baseAddress!, cap: raw.count)
        let ok = serverVersion.withUTF8Buffer { sv -> Bool in
            w.string(clientVersion, clientVersionLen) &&
            w.string(sv.baseAddress!, sv.count) &&
            w.string(clientKex, clientKexLen) &&
            w.string(serverKex, serverKexLen) &&
            w.string(hostKey, hostKeyLen) &&
            w.string(clientPub, 32) &&
            w.string(serverPub, 32) &&
            w.mpint(shared, 32)
        }
        if !ok { return false }
        sha256(raw.baseAddress!, w.len, out32)
        return true
    }
}

private func deriveSSHKey(_ out: UnsafeMutableRawPointer, _ outLen: Int,
                          _ letter: UInt8,
                          _ shared: UnsafeRawPointer,
                          _ exchangeHash: UnsafeRawPointer) -> Bool {
    withUnsafeTemporaryAllocation(byteCount: 4 + 33 + 32 + outLen + 32, alignment: 8) { raw -> Bool in
        let kmp = raw.baseAddress!
        var kw = SSHWriter(p: kmp, cap: raw.count)
        if !kw.mpint(shared, 32) { return false }
        let kmpLen = kw.len

        var produced = 0
        while produced < outLen {
            var w = SSHWriter(p: kmp + kmpLen, cap: raw.count - kmpLen)
            guard w.bytes(exchangeHash, 32) else { return false }
            if produced == 0 {
                guard w.u8(letter), w.bytes(exchangeHash, 32) else { return false }
            } else {
                guard w.bytes(out, produced) else { return false }
            }
            withUnsafeTemporaryAllocation(byteCount: 32, alignment: 8) { digest in
                sha256(kmp, kmpLen + w.len, digest.baseAddress!)
                let n = min(32, outLen - produced)
                copyBytes(out, produced, digest.baseAddress!, n)
                produced += n
            }
        }
        return true
    }
}

private func nonceForSeq(_ seq: UInt32, _ out12: UnsafeMutableRawPointer) {
    var i = 0
    while i < 8 {
        out12.storeBytes(of: UInt8(0), toByteOffset: i, as: UInt8.self)
        i += 1
    }
    putU32BE(out12, 8, seq)
}

private func sendEncryptedChachaPacket(_ fd: Int32,
                                       _ payload: UnsafeRawPointer, _ payloadLen: Int,
                                       _ key64: UnsafeRawPointer,
                                       _ seq: inout UInt32) -> Bool {
    withUnsafeTemporaryAllocation(byteCount: maxPacketLen + 16, alignment: 8) { plain -> Bool in
        let totalPlain = makeChachaPlainPacket(payload, payloadLen, plain.baseAddress!, maxPacketLen)
        if totalPlain <= 0 { return false }
        let packetLen = Int(getU32BE(plain.baseAddress!, 0))
        let restLen = packetLen

        return withUnsafeTemporaryAllocation(byteCount: totalPlain + 16, alignment: 8) { enc -> Bool in
            var nonce = (UInt64(0), UInt32(0))
            withUnsafeMutableBytes(of: &nonce) { nb in
                nonceForSeq(seq, nb.baseAddress!)
                chacha20Encrypt(key: key64 + 32, counter: 0, nonce: nb.baseAddress!,
                                input: plain.baseAddress!, output: enc.baseAddress!, len: 4)
                chacha20Encrypt(key: key64, counter: 1, nonce: nb.baseAddress!,
                                input: plain.baseAddress! + 4, output: enc.baseAddress! + 4,
                                len: restLen)
                var polyKey = (
                    UInt64(0), UInt64(0), UInt64(0), UInt64(0),
                    UInt64(0), UInt64(0), UInt64(0), UInt64(0)
                )
                withUnsafeMutableBytes(of: &polyKey) { pk in
                    chacha20Block(key: key64, counter: 0, nonce: nb.baseAddress!, out: pk.baseAddress!)
                    poly1305Mac(key: pk.baseAddress!, msg: enc.baseAddress!, len: 4 + restLen,
                                 tagOut: enc.baseAddress! + 4 + restLen)
                }
            }
            if !writeExact(fd, enc.baseAddress!, 4 + restLen + 16) { return false }
            seq &+= 1
            return true
        }
    }
}

private func readEncryptedChachaPacket(_ fd: Int32,
                                       _ payload: UnsafeMutableRawPointer, _ cap: Int,
                                       _ key64: UnsafeRawPointer,
                                       _ seq: inout UInt32) -> Int {
    withUnsafeTemporaryAllocation(byteCount: maxPacketLen + 20, alignment: 8) { enc -> Int in
        withUnsafeTemporaryAllocation(byteCount: maxPacketLen, alignment: 8) { plain -> Int in
            guard let encBase = enc.baseAddress, let plainBase = plain.baseAddress else { return -1 }
            if !readExact(fd, encBase, 4) { return -1 }

            var nonce = (UInt64(0), UInt32(0))
            withUnsafeMutableBytes(of: &nonce) { nb in
                nonceForSeq(seq, nb.baseAddress!)
                chacha20Encrypt(key: key64 + 32, counter: 0, nonce: nb.baseAddress!,
                                input: encBase, output: plainBase, len: 4)
            }
            let packetLen = Int(getU32BE(plainBase, 0))
            if packetLen < 5 || packetLen > maxPacketLen || (packetLen % sshBlockSize) != 0 {
                return -1
            }
            if !readExact(fd, encBase + 4, packetLen + 16) { return -1 }

            var tagOK = false
            withUnsafeMutableBytes(of: &nonce) { nb in
                var polyKey = (
                    UInt64(0), UInt64(0), UInt64(0), UInt64(0),
                    UInt64(0), UInt64(0), UInt64(0), UInt64(0)
                )
                withUnsafeMutableBytes(of: &polyKey) { pk in
                    withUnsafeTemporaryAllocation(byteCount: 16, alignment: 8) { tag in
                        chacha20Block(key: key64, counter: 0, nonce: nb.baseAddress!,
                                      out: pk.baseAddress!)
                        poly1305Mac(key: pk.baseAddress!, msg: encBase, len: 4 + packetLen,
                                     tagOut: tag.baseAddress!)
                        tagOK = bytesEqual(tag.baseAddress!, encBase + 4 + packetLen, 16)
                    }
                }
                if tagOK {
                    chacha20Encrypt(key: key64, counter: 1, nonce: nb.baseAddress!,
                                    input: encBase + 4, output: plainBase, len: packetLen)
                }
            }
            if !tagOK { return -1 }
            let padLen = Int(plainBase.load(fromByteOffset: 0, as: UInt8.self))
            let payloadLen = packetLen - padLen - 1
            if padLen < 4 || payloadLen < 1 || payloadLen > cap { return -1 }
            copyBytes(payload, 0, plainBase + 1, payloadLen)
            seq &+= 1
            return payloadLen
        }
    }
}

private func isExecSpace(_ c: UInt8) -> Bool {
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
}

private func execPathIsAllowed(_ path: SSHStringView) -> Bool {
    let prefix: StaticString = "/bin/"
    return prefix.withUTF8Buffer { pb -> Bool in
        if path.len <= pb.count { return false }
        var i = 0
        while i < pb.count {
            if path.p.load(fromByteOffset: i, as: UInt8.self) != pb[i] { return false }
            i += 1
        }
        while i < path.len {
            let c = path.p.load(fromByteOffset: i, as: UInt8.self)
            if c == 0x2F || c == 0 { return false }
            i += 1
        }
        return true
    }
}

private func cStringLen(_ p: UnsafePointer<CChar>) -> Int {
    var n = 0
    while p[n] != 0 { n += 1 }
    return n
}

private func execCPathIsAllowed(_ path: UnsafePointer<CChar>) -> Bool {
    execPathIsAllowed(SSHStringView(p: UnsafeRawPointer(path), len: cStringLen(path)))
}

private func parseExecArgv(_ command: SSHStringView,
                           _ raw: UnsafeMutableRawPointer,
                           _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int {
    var inOff = 0
    var outOff = 0
    var argc = 0

    while true {
        while inOff < command.len &&
            isExecSpace(command.p.load(fromByteOffset: inOff, as: UInt8.self)) {
            inOff += 1
        }
        if inOff >= command.len { break }
        if argc >= maxExecArgs { return -1 }

        argv[argc] = (raw + outOff).assumingMemoryBound(to: CChar.self)
        argc += 1

        while inOff < command.len {
            var c = command.p.load(fromByteOffset: inOff, as: UInt8.self)
            if c == 0 { return -1 }
            if isExecSpace(c) { break }

            if c == 0x27 { // single quote: copy bytes literally until the next quote.
                inOff += 1
                var closed = false
                while inOff < command.len {
                    c = command.p.load(fromByteOffset: inOff, as: UInt8.self)
                    if c == 0 { return -1 }
                    if c == 0x27 {
                        inOff += 1
                        closed = true
                        break
                    }
                    raw.storeBytes(of: c, toByteOffset: outOff, as: UInt8.self)
                    outOff += 1
                    inOff += 1
                }
                if !closed { return -1 }
                continue
            }

            if c == 0x22 { // double quote: copy bytes, with backslash escaping.
                inOff += 1
                var closed = false
                while inOff < command.len {
                    c = command.p.load(fromByteOffset: inOff, as: UInt8.self)
                    if c == 0 { return -1 }
                    if c == 0x22 {
                        inOff += 1
                        closed = true
                        break
                    }
                    if c == 0x5C {
                        inOff += 1
                        if inOff >= command.len { return -1 }
                        c = command.p.load(fromByteOffset: inOff, as: UInt8.self)
                        if c == 0 { return -1 }
                    }
                    raw.storeBytes(of: c, toByteOffset: outOff, as: UInt8.self)
                    outOff += 1
                    inOff += 1
                }
                if !closed { return -1 }
                continue
            }

            if c == 0x5C {
                inOff += 1
                if inOff >= command.len { return -1 }
                c = command.p.load(fromByteOffset: inOff, as: UInt8.self)
                if c == 0 { return -1 }
            }

            raw.storeBytes(of: c, toByteOffset: outOff, as: UInt8.self)
            outOff += 1
            inOff += 1
        }

        raw.storeBytes(of: UInt8(0), toByteOffset: outOff, as: UInt8.self)
        outOff += 1
    }

    argv[argc] = nil
    return argc
}

private func copyStaticToOutput(_ s: StaticString,
                                _ output: UnsafeMutableRawPointer,
                                _ outputCap: Int) -> Int {
    s.withUTF8Buffer { mb -> Int in
        let count = min(mb.count, outputCap)
        copyBytes(output, 0, mb.baseAddress!, count)
        return count
    }
}

private func runExecCommand(_ command: SSHStringView,
                            _ input: UnsafeRawPointer?,
                            _ inputLen: Int,
                            _ output: UnsafeMutableRawPointer,
                            _ outputCap: Int) -> (Int, UInt32, Bool) {
    guard command.len > 0, command.len <= maxExecCommandLen else {
        let n = copyStaticToOutput("sshd: unsupported exec command\n", output, outputCap)
        return (n, 127, false)
    }

    return withUnsafeTemporaryAllocation(byteCount: command.len + 1, alignment: 1) { commandRaw -> (Int, UInt32, Bool) in
      withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<CChar>?.self, capacity: maxExecArgs + 1) { argv -> (Int, UInt32, Bool) in
        let argc = parseExecArgv(command, commandRaw.baseAddress!, argv.baseAddress!)
        guard argc > 0,
              let path = argv[0],
              execCPathIsAllowed(path) else {
            let n = copyStaticToOutput("sshd: unsupported exec command\n", output, outputCap)
            return (n, 127, false)
        }

        _ = swiftos_unlink("/tmp/swos-sshd-output")
        let outFd = swiftos_open("/tmp/swos-sshd-output", oWriteOnly | oCreate | oTrunc)
        if outFd < 0 {
            let n = copyStaticToOutput("sshd: output capture failed\n", output, outputCap)
            return (n, 126, false)
        }

        var inFds = (Int32(0), Int32(0))
        let inPipeRc = withUnsafeMutablePointer(to: &inFds) { fp -> Int32 in
            swiftos_pipe(UnsafeMutableRawPointer(fp).assumingMemoryBound(to: Int32.self))
        }
        if inPipeRc != 0 {
            _ = swiftos_close(outFd)
            _ = swiftos_unlink("/tmp/swos-sshd-output")
            let n = copyStaticToOutput("sshd: pipe failed\n", output, outputCap)
            return (n, 126, false)
        }

        let inReadFd = inFds.0
        let inWriteFd = inFds.1
        var status: UInt32 = 126
        if inputLen > 0 {
            guard let input = input, writeExact(inWriteFd, input, inputLen) else {
                _ = swiftos_close(outFd)
                _ = swiftos_close(inReadFd)
                _ = swiftos_close(inWriteFd)
                _ = swiftos_unlink("/tmp/swos-sshd-output")
                let n = copyStaticToOutput("sshd: stdin pipe failed\n", output, outputCap)
                return (n, 126, false)
            }
        }
        _ = swiftos_close(inWriteFd)

        withUnsafeTemporaryAllocation(byteCount: 48, alignment: 4) { handles in
        let hp = handles.baseAddress!
        hp.storeBytes(of: inReadFd, toByteOffset: 0, as: Int32.self)
        hp.storeBytes(of: Int32(0), toByteOffset: 4, as: Int32.self)
        hp.storeBytes(of: spawnRightRead, toByteOffset: 8, as: UInt32.self)
        hp.storeBytes(of: UInt32(0), toByteOffset: 12, as: UInt32.self)
        hp.storeBytes(of: outFd, toByteOffset: 16, as: Int32.self)
        hp.storeBytes(of: Int32(1), toByteOffset: 20, as: Int32.self)
        hp.storeBytes(of: spawnRightWrite, toByteOffset: 24, as: UInt32.self)
        hp.storeBytes(of: UInt32(0), toByteOffset: 28, as: UInt32.self)
        hp.storeBytes(of: outFd, toByteOffset: 32, as: Int32.self)
        hp.storeBytes(of: Int32(2), toByteOffset: 36, as: Int32.self)
        hp.storeBytes(of: spawnRightWrite, toByteOffset: 40, as: UInt32.self)
        hp.storeBytes(of: UInt32(0), toByteOffset: 44, as: UInt32.self)

        let rc = swiftos_spawn_handles_raw(
            argv[0]!,
            UnsafeMutableRawPointer(argv.baseAddress!),
            handles.baseAddress!,
            3
        )
        status = rc >= 0 ? UInt32(rc) : 126
        }

        _ = swiftos_close(outFd)
        _ = swiftos_close(inReadFd)

        let readFd = swiftos_open("/tmp/swos-sshd-output", oReadOnly)
        if readFd < 0 {
            _ = swiftos_unlink("/tmp/swos-sshd-output")
            let n = copyStaticToOutput("sshd: output readback failed\n", output, outputCap)
            return (n, 126, false)
        }
        var used = 0
        while used < outputCap {
            let r = swiftos_read(readFd, output + used, UInt(outputCap - used))
            if r <= 0 { break }
            used += Int(r)
        }
        let truncated = withUnsafeTemporaryAllocation(byteCount: 1, alignment: 1) { extra -> Bool in
            swiftos_read(readFd, extra.baseAddress!, 1) > 0
        }
        _ = swiftos_close(readFd)
        _ = swiftos_unlink("/tmp/swos-sshd-output")
        return (used, status, truncated)
      }
    }
}

private func sendExecResult(_ fd: Int32,
                            _ packet: UnsafeMutableRawPointer, _ cap: Int,
                            _ serverKey: UnsafeRawPointer,
                            _ serverSeq: inout UInt32,
                            _ clientChannel: UInt32,
                            _ command: SSHStringView,
                            _ input: UnsafeRawPointer?,
                            _ inputLen: Int) -> Bool {
    withUnsafeTemporaryAllocation(byteCount: maxExecOutputLen, alignment: 8) { out -> Bool in
        if inputLen > 0 {
            swiftos_puts("sshd: exec stdin bytes ")
            printUInt(UInt(inputLen))
            swiftos_puts("\n")
        }
        let result = runExecCommand(command, input, inputLen, out.baseAddress!, out.count)
        if result.0 > 0 {
            var dataWriter = SSHWriter(p: packet, cap: cap)
            guard dataWriter.u8(msgChannelData),
                  dataWriter.u32(clientChannel),
                  dataWriter.string(out.baseAddress!, result.0),
                  sendEncryptedChachaPacket(fd, packet, dataWriter.len,
                                            serverKey, &serverSeq) else {
                    return false
            }
        }
        swiftos_puts("sshd: exec output bytes ")
        printUInt(UInt(result.0))
        swiftos_puts("\n")
        if result.2 {
            swiftos_puts("sshd: exec output truncated\n")
        }

        var eofWriter = SSHWriter(p: packet, cap: cap)
        guard eofWriter.u8(msgChannelEof),
              eofWriter.u32(clientChannel),
              sendEncryptedChachaPacket(fd, packet, eofWriter.len, serverKey, &serverSeq) else {
            return false
        }

        var statusWriter = SSHWriter(p: packet, cap: cap)
        guard statusWriter.u8(msgChannelRequest),
              statusWriter.u32(clientChannel),
              writerStringStatic(&statusWriter, "exit-status"),
              statusWriter.u8(0),
              statusWriter.u32(result.1),
              sendEncryptedChachaPacket(fd, packet, statusWriter.len, serverKey, &serverSeq) else {
            return false
        }

        var closeWriter = SSHWriter(p: packet, cap: cap)
        guard closeWriter.u8(msgChannelClose),
              closeWriter.u32(clientChannel),
              sendEncryptedChachaPacket(fd, packet, closeWriter.len, serverKey, &serverSeq) else {
            return false
        }

        swiftos_puts("sshd: session exec completed status ")
        printUInt(UInt(result.1))
        swiftos_puts("\n")
        return true
    }
}

private func signatureView(_ sigBlob: SSHStringView) -> SSHStringView? {
    var r = SSHReader(p: sigBlob.p, len: sigBlob.len)
    guard let alg = r.string(),
          stringEquals(alg, "ssh-ed25519"),
          let sig = r.string(),
          sig.len == 64,
          r.remaining == 0 else {
        return nil
    }
    return sig
}

private func verifyUserauthSignature(sessionId: UnsafeRawPointer,
                                     requestPayload: UnsafeRawPointer,
                                     signedLen: Int,
                                     keyBlob: SSHStringView,
                                     sigBlob: SSHStringView) -> Bool {
    guard let sig = signatureView(sigBlob),
          let pub = ed25519PublicKeyFromBlob(keyBlob) else {
        return false
    }
    return withUnsafeTemporaryAllocation(byteCount: 4 + 32 + signedLen, alignment: 8) { raw -> Bool in
        var w = SSHWriter(p: raw.baseAddress!, cap: raw.count)
        guard w.string(sessionId, 32),
              w.bytes(requestPayload, signedLen) else {
            return false
        }
        return ed25519Verify(message: raw.baseAddress!, w.len,
                             signature: sig.p,
                             publicKey: pub.p)
    }
}

private func sendUserauthFailure(_ fd: Int32, _ packet: UnsafeMutableRawPointer, _ cap: Int,
                                 _ key: UnsafeRawPointer, _ seq: inout UInt32) -> Bool {
    var w = SSHWriter(p: packet, cap: cap)
    guard w.u8(msgUserauthFailure),
          writerStringStatic(&w, "publickey"),
          w.u8(0) else {
        return false
    }
    return sendEncryptedChachaPacket(fd, packet, w.len, key, &seq)
}

private func sendChannelRequestResult(_ fd: Int32, _ packet: UnsafeMutableRawPointer, _ cap: Int,
                                      _ key: UnsafeRawPointer, _ seq: inout UInt32,
                                      _ recipient: UInt32, _ ok: Bool) -> Bool {
    var w = SSHWriter(p: packet, cap: cap)
    guard w.u8(ok ? msgChannelSuccess : msgChannelFailure),
          w.u32(recipient) else {
        return false
    }
    return sendEncryptedChachaPacket(fd, packet, w.len, key, &seq)
}

private func sendGlobalRequestResult(_ fd: Int32, _ packet: UnsafeMutableRawPointer, _ cap: Int,
                                     _ key: UnsafeRawPointer, _ seq: inout UInt32,
                                     _ ok: Bool) -> Bool {
    var w = SSHWriter(p: packet, cap: cap)
    guard w.u8(ok ? msgRequestSuccess : msgRequestFailure) else { return false }
    return sendEncryptedChachaPacket(fd, packet, w.len, key, &seq)
}

private func handleSSHSession(_ fd: Int32,
                              _ packet: UnsafeMutableRawPointer, _ cap: Int,
                              _ clientKey: UnsafeRawPointer, _ serverKey: UnsafeRawPointer,
                              _ sessionId: UnsafeRawPointer,
                              _ clientSeq: inout UInt32, _ serverSeq: inout UInt32) -> Bool {
    var n = readEncryptedChachaPacket(fd, packet, cap, clientKey, &clientSeq)
    guard n > 0 else { swiftos_puts("sshd: encrypted service read failed\n"); return false }
    var r = SSHReader(p: packet, len: n)
    guard r.u8() == msgServiceRequest,
          let service = r.string(),
          stringEquals(service, "ssh-userauth") else {
        swiftos_puts("sshd: expected ssh-userauth service\n")
        return false
    }

    var w = SSHWriter(p: packet, cap: cap)
    guard w.u8(msgServiceAccept),
          writerStringStatic(&w, "ssh-userauth"),
          sendEncryptedChachaPacket(fd, packet, w.len, serverKey, &serverSeq) else {
        swiftos_puts("sshd: service accept failed\n")
        return false
    }

    var authed = false
    var attempts = 0
    while !authed && attempts < 8 {
        attempts += 1
        n = readEncryptedChachaPacket(fd, packet, cap, clientKey, &clientSeq)
        guard n > 0 else { swiftos_puts("sshd: encrypted auth read failed\n"); return false }
        r = SSHReader(p: packet, len: n)
        guard r.u8() == msgUserauthRequest,
              let user = r.string(),
              let authService = r.string(),
              let method = r.string(),
              stringEquals(user, "root"),
              stringEquals(authService, "ssh-connection"),
              stringEquals(method, "publickey"),
              let signed = r.bool(),
              let alg = r.string(),
              stringEquals(alg, "ssh-ed25519"),
              let keyBlob = r.string(),
              authorizedKeyBlobMatches(keyBlob) else {
            if !sendUserauthFailure(fd, packet, cap, serverKey, &serverSeq) { return false }
            continue
        }

        let signedLen = r.off
        if !signed {
            let sentPkOk = withUnsafeTemporaryAllocation(byteCount: 128, alignment: 8) { saved -> Bool in
                if keyBlob.len > saved.count { return false }
                copyBytes(saved.baseAddress!, 0, keyBlob.p, keyBlob.len)
                w = SSHWriter(p: packet, cap: cap)
                guard w.u8(msgUserauthPkOk),
                      writerStringStatic(&w, "ssh-ed25519"),
                      w.string(saved.baseAddress!, keyBlob.len) else {
                    return false
                }
                return sendEncryptedChachaPacket(fd, packet, w.len, serverKey, &serverSeq)
            }
            if !sentPkOk {
                swiftos_puts("sshd: userauth pk-ok failed\n")
                return false
            }
            continue
        }

        guard let sigBlob = r.string(),
              r.remaining == 0,
              verifyUserauthSignature(sessionId: sessionId,
                                      requestPayload: packet,
                                      signedLen: signedLen,
                                      keyBlob: keyBlob,
                                      sigBlob: sigBlob) else {
            if !sendUserauthFailure(fd, packet, cap, serverKey, &serverSeq) { return false }
            continue
        }

        w = SSHWriter(p: packet, cap: cap)
        guard w.u8(msgUserauthSuccess),
              sendEncryptedChachaPacket(fd, packet, w.len, serverKey, &serverSeq) else {
            return false
        }
        authed = true
        swiftos_puts("sshd: publickey auth accepted for root\n")
    }
    if !authed { return false }

    var clientChannel: UInt32 = 0
    let serverChannel: UInt32 = 0
    var channelOpen = false
    var loops = 0
    while loops < 24 {
        loops += 1
        n = readEncryptedChachaPacket(fd, packet, cap, clientKey, &clientSeq)
        guard n > 0 else { swiftos_puts("sshd: encrypted channel read failed\n"); return false }
        r = SSHReader(p: packet, len: n)
        guard let msg = r.u8() else { return false }
        if msg == msgGlobalRequest {
            guard let name = r.string(), let wantReply = r.bool() else { return false }
            if wantReply {
                let ok = stringEquals(name, "no-more-sessions@openssh.com")
                if !sendGlobalRequestResult(fd, packet, cap, serverKey, &serverSeq, ok) {
                    return false
                }
            }
        } else if msg == msgChannelOpen {
            guard let ctype = r.string(),
                  let sender = r.u32(),
                  let _ = r.u32(),
                  let _ = r.u32() else {
                return false
            }
            if stringEquals(ctype, "session") {
                clientChannel = sender
                channelOpen = true
                w = SSHWriter(p: packet, cap: cap)
                guard w.u8(msgChannelOpenConfirmation),
                      w.u32(clientChannel),
                      w.u32(serverChannel),
                      w.u32(65536),
                      w.u32(32768),
                      sendEncryptedChachaPacket(fd, packet, w.len, serverKey, &serverSeq) else {
                    return false
                }
                swiftos_puts("sshd: session channel opened\n")
            } else {
                w = SSHWriter(p: packet, cap: cap)
                guard w.u8(msgChannelOpenFailure),
                      w.u32(sender),
                      w.u32(1),
                      writerStringStatic(&w, "channel type not supported"),
                      w.u32(0),
                      sendEncryptedChachaPacket(fd, packet, w.len, serverKey, &serverSeq) else {
                    return false
                }
            }
        } else if msg == msgChannelRequest {
            guard channelOpen,
                  let recipient = r.u32(),
                  recipient == serverChannel,
                  let req = r.string(),
                  let wantReply = r.bool() else {
                return false
            }
            if stringEquals(req, "env") {
                if wantReply &&
                    !sendChannelRequestResult(fd, packet, cap, serverKey, &serverSeq,
                                              clientChannel, false) {
                    return false
                }
                continue
            }
            guard stringEquals(req, "exec"),
                  let command = r.string() else {
                if wantReply &&
                    !sendChannelRequestResult(fd, packet, cap, serverKey, &serverSeq,
                                              clientChannel, false) {
                    return false
                }
                continue
            }
            if wantReply &&
                !sendChannelRequestResult(fd, packet, cap, serverKey, &serverSeq,
                                          clientChannel, true) {
                return false
            }

            return withUnsafeTemporaryAllocation(byteCount: command.len, alignment: 1) { cmdCopy -> Bool in
              withUnsafeTemporaryAllocation(byteCount: maxExecInputLen, alignment: 8) { input -> Bool in
                copyBytes(cmdCopy.baseAddress!, 0, command.p, command.len)
                let savedCommand = SSHStringView(p: cmdCopy.baseAddress!, len: command.len)
                var inputLen = 0
                var inputLoops = 0

                while inputLoops < 32 {
                    inputLoops += 1
                    let timeout = inputLen == 0 ? 1000 : 5000
                    if !pollReadable(fd, timeout) { break }
                    n = readEncryptedChachaPacket(fd, packet, cap, clientKey, &clientSeq)
                    guard n > 0 else {
                        swiftos_puts("sshd: encrypted post-exec read failed\n")
                        return false
                    }
                    r = SSHReader(p: packet, len: n)
                    guard let postMsg = r.u8() else { return false }
                    if postMsg == msgChannelData {
                        guard let recipient = r.u32(),
                              recipient == serverChannel,
                              let data = r.string() else {
                            return false
                        }
                        if inputLen + data.len > maxExecInputLen {
                            swiftos_puts("sshd: exec stdin too large\n")
                            return false
                        }
                        copyBytes(input.baseAddress!, inputLen, data.p, data.len)
                        inputLen += data.len
                    } else if postMsg == msgChannelEof {
                        guard let recipient = r.u32(), recipient == serverChannel else {
                            return false
                        }
                        break
                    } else if postMsg == msgChannelWindowAdjust {
                        guard let recipient = r.u32(), recipient == serverChannel,
                              let _ = r.u32() else {
                            return false
                        }
                    } else if postMsg == msgGlobalRequest {
                        guard let name = r.string(), let wantReply = r.bool() else { return false }
                        if wantReply {
                            let ok = stringEquals(name, "no-more-sessions@openssh.com")
                            if !sendGlobalRequestResult(fd, packet, cap, serverKey, &serverSeq, ok) {
                                return false
                            }
                        }
                    } else if postMsg == msgChannelRequest {
                        guard let recipient = r.u32(),
                              recipient == serverChannel,
                              let _ = r.string(),
                              let wantReply = r.bool() else {
                            return false
                        }
                        if wantReply &&
                            !sendChannelRequestResult(fd, packet, cap, serverKey, &serverSeq,
                                                      clientChannel, false) {
                            return false
                        }
                    } else if postMsg == msgChannelClose {
                        guard let recipient = r.u32(), recipient == serverChannel else {
                            return false
                        }
                        break
                    } else {
                        swiftos_puts("sshd: unsupported post-exec channel message\n")
                        return false
                    }
                }

                return sendExecResult(fd, packet, cap, serverKey, &serverSeq,
                                      clientChannel, savedCommand,
                                      input.baseAddress!, inputLen)
              }
            }
        } else if msg == msgChannelClose {
            return true
        }
    }
    swiftos_puts("sshd: session loop exhausted\n")
    return false
}

private func buildDisconnectPayload(_ out: UnsafeMutableRawPointer, _ cap: Int) -> Int {
    var w = SSHWriter(p: out, cap: cap)
    guard w.u8(msgDisconnect),
          w.u32(11) else { return -1 } // SSH_DISCONNECT_BY_APPLICATION
    let ok = disconnectText.withUTF8Buffer { desc -> Bool in
        w.string(desc.baseAddress!, desc.count) && w.u32(0)
    }
    return ok ? w.len : -1
}

private func serveOne(_ fd: Int32) {
    writeStr(fd, serverBanner)
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 256) { line in
      withUnsafeTemporaryAllocation(byteCount: maxPayloadLen, alignment: 8) { clientKex in
      withUnsafeTemporaryAllocation(byteCount: maxPayloadLen, alignment: 8) { serverKex in
      withUnsafeTemporaryAllocation(byteCount: maxPayloadLen, alignment: 8) { packet in
      withUnsafeTemporaryAllocation(byteCount: 256, alignment: 8) { hostKey in
      withUnsafeTemporaryAllocation(byteCount: 128, alignment: 8) { sigBlob in
      withUnsafeTemporaryAllocation(byteCount: 64, alignment: 8) { clientKey in
      withUnsafeTemporaryAllocation(byteCount: 64, alignment: 8) { serverKey in
        let clientVersionLen = readClientBanner(fd, line)
        guard clientVersionLen > 0 && isSSHBanner(UnsafePointer(line.baseAddress!), clientVersionLen) else {
            swiftos_puts("sshd: invalid client banner\n")
            return
        }
        swiftos_puts("sshd: client ")
        _ = swiftos_write(1, line.baseAddress, UInt(clientVersionLen))
        swiftos_puts("\n")

        var clientSeq: UInt32 = 0
        var serverSeq: UInt32 = 0

        let clientKexLen = readPlainPacket(fd, clientKex.baseAddress!, clientKex.count, &clientSeq)
        guard clientKexLen > 0 && clientKex.baseAddress!.load(fromByteOffset: 0, as: UInt8.self) == 20 else {
            swiftos_puts("sshd: expected client KEXINIT\n")
            return
        }
        let serverKexLen = buildKexInit(serverKex.baseAddress!, serverKex.count)
        guard serverKexLen > 0,
              sendPlainPacket(fd, serverKex.baseAddress!, serverKexLen, &serverSeq) else {
            swiftos_puts("sshd: could not send KEXINIT\n")
            return
        }

        let ecdhInitLen = readPlainPacket(fd, packet.baseAddress!, packet.count, &clientSeq)
        guard ecdhInitLen >= 37,
              packet.baseAddress!.load(fromByteOffset: 0, as: UInt8.self) == 30,
              getU32BE(packet.baseAddress!, 1) == 32 else {
            swiftos_puts("sshd: expected curve25519 init\n")
            return
        }
        let clientPub = packet.baseAddress! + 5

        var hostSeed = (
            UInt64(0), UInt64(0), UInt64(0), UInt64(0)
        )
        var serverPriv = (
            UInt64(0), UInt64(0), UInt64(0), UInt64(0)
        )
        var serverPub = (
            UInt64(0), UInt64(0), UInt64(0), UInt64(0)
        )
        var shared = (
            UInt64(0), UInt64(0), UInt64(0), UInt64(0)
        )
        var exchangeHash = (
            UInt64(0), UInt64(0), UInt64(0), UInt64(0)
        )
        var signature = (
            UInt64(0), UInt64(0), UInt64(0), UInt64(0),
            UInt64(0), UInt64(0), UInt64(0), UInt64(0)
        )

        let hostSeedOK = withUnsafeMutableBytes(of: &hostSeed) { hs in
            readHostKeySeed(hs.baseAddress!)
        }
        guard hostSeedOK else { return }
        withUnsafeMutableBytes(of: &serverPriv) { sp in
            fillPseudoRandom(sp.baseAddress!, 32, 0x535348445f4b4558)
        }
        var basePoint = (
            UInt64(9), UInt64(0), UInt64(0), UInt64(0)
        )
        withUnsafeBytes(of: &serverPriv) { sk in
            withUnsafeBytes(of: &basePoint) { bp in
                withUnsafeMutableBytes(of: &serverPub) { pub in
                    x25519(sk.baseAddress!, bp.baseAddress!, pub.baseAddress!)
                }
            }
        }
        withUnsafeBytes(of: &serverPriv) { sk in
            withUnsafeMutableBytes(of: &shared) { sh in
                x25519(sk.baseAddress!, clientPub, sh.baseAddress!)
            }
        }
        let sharedAllZero = withUnsafeBytes(of: &shared) { sh -> Bool in
            var acc: UInt8 = 0
            for i in 0..<32 { acc |= sh.load(fromByteOffset: i, as: UInt8.self) }
            return acc == 0
        }
        if sharedAllZero {
            swiftos_puts("sshd: all-zero shared secret\n")
            return
        }

        let hostKeyLen = withUnsafeBytes(of: &hostSeed) { hs in
            buildHostKeyBlob(hostKey.baseAddress!, hostKey.count, hs.baseAddress!)
        }
        guard hostKeyLen > 0 else {
            swiftos_puts("sshd: host key failed\n")
            return
        }
        let hashOK = withUnsafeBytes(of: &serverPub) { spub in
            withUnsafeBytes(of: &shared) { sh in
                withUnsafeMutableBytes(of: &exchangeHash) { hh in
                    buildExchangeHash(hh.baseAddress!,
                                      line.baseAddress!, clientVersionLen,
                                      clientKex.baseAddress!, clientKexLen,
                                      serverKex.baseAddress!, serverKexLen,
                                      hostKey.baseAddress!, hostKeyLen,
                                      clientPub, spub.baseAddress!,
                                      sh.baseAddress!)
                }
            }
        }
        guard hashOK else {
            swiftos_puts("sshd: exchange hash failed\n")
            return
        }
        withUnsafeBytes(of: &exchangeHash) { hh in
            withUnsafeBytes(of: &hostSeed) { hs in
                withUnsafeMutableBytes(of: &signature) { sig in
                    ed25519Sign(message: hh.baseAddress!, 32, seed: hs.baseAddress!,
                                signature: sig.baseAddress!)
                }
            }
        }
        let sigLen = withUnsafeBytes(of: &signature) { sig in
            buildSignatureBlob(sigBlob.baseAddress!, sigBlob.count, sig.baseAddress!)
        }
        guard sigLen > 0 else {
            swiftos_puts("sshd: signature blob failed\n")
            return
        }

        var reply = SSHWriter(p: packet.baseAddress!, cap: packet.count)
        guard reply.u8(31),
              reply.string(hostKey.baseAddress!, hostKeyLen) else {
            swiftos_puts("sshd: reply build failed\n")
            return
        }
        let replyOK = withUnsafeBytes(of: &serverPub) { spub -> Bool in
            reply.string(spub.baseAddress!, 32) &&
            reply.string(sigBlob.baseAddress!, sigLen)
        }
        guard replyOK,
              sendPlainPacket(fd, packet.baseAddress!, reply.len, &serverSeq) else {
            swiftos_puts("sshd: could not send ECDH reply\n")
            return
        }

        packet.baseAddress!.storeBytes(of: UInt8(21), toByteOffset: 0, as: UInt8.self)
        guard sendPlainPacket(fd, packet.baseAddress!, 1, &serverSeq) else {
            swiftos_puts("sshd: could not send NEWKEYS\n")
            return
        }
        let newKeysLen = readPlainPacket(fd, packet.baseAddress!, packet.count, &clientSeq)
        guard newKeysLen == 1 && packet.baseAddress!.load(fromByteOffset: 0, as: UInt8.self) == 21 else {
            swiftos_puts("sshd: expected client NEWKEYS\n")
            return
        }

        // The preflight advertises OpenSSH strict KEX and expects the matching
        // modern client extension, which resets sequence numbers after NEWKEYS.
        clientSeq = 0
        serverSeq = 0

        let clientKeyOK = withUnsafeBytes(of: &shared) { sh in
            withUnsafeBytes(of: &exchangeHash) { hh in
                deriveSSHKey(clientKey.baseAddress!, 64, 0x43, sh.baseAddress!, hh.baseAddress!)
            }
        }
        let serverKeyOK = withUnsafeBytes(of: &shared) { sh in
            withUnsafeBytes(of: &exchangeHash) { hh in
                deriveSSHKey(serverKey.baseAddress!, 64, 0x44, sh.baseAddress!, hh.baseAddress!)
            }
        }
        guard clientKeyOK && serverKeyOK else {
            swiftos_puts("sshd: key derivation failed\n")
            return
        }

        let sessionOK = withUnsafeBytes(of: &exchangeHash) { hh in
            handleSSHSession(fd, packet.baseAddress!, packet.count,
                             clientKey.baseAddress!, serverKey.baseAddress!,
                             hh.baseAddress!, &clientSeq, &serverSeq)
        }
        if !sessionOK {
            let discLen = buildDisconnectPayload(packet.baseAddress!, packet.count)
            if discLen > 0 {
                _ = sendEncryptedChachaPacket(fd, packet.baseAddress!, discLen,
                                              serverKey.baseAddress!, &serverSeq)
            }
            swiftos_puts("sshd: session failed\n")
            return
        }
        swiftos_puts("sshd: session complete\n")
      }}}}}}}}
    }

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp
    var config = parseConfig(argc, argv)
    if fileRequestsOnceMode() {
        config.once = true
    }
    let port = config.port
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
    swiftos_puts(" (session exec preflight)\n")
    if config.once {
        swiftos_puts("sshd: once mode enabled\n")
    }

    while true {
        let cfd = swiftos_accept(lfd)
        if cfd < 0 {
            swiftos_puts("sshd: accept failed\n")
            _ = swiftos_close(lfd)
            return 1
        }
        serveOne(cfd)
        _ = swiftos_close(cfd)
        if config.once {
            swiftos_puts("sshd: once mode complete; exiting\n")
            _ = swiftos_close(lfd)
            return 0
        }
    }
}
