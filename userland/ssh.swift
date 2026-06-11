// SPDX-License-Identifier: Apache-2.0
// ssh.swift — SSH client transport preflight for swift-os.
//
// This is not a full interactive SSH client yet. It proves the outbound client
// path needed for cloud bring-up: TCP connect, SSH identification, KEXINIT,
// curve25519-sha256, ssh-ed25519 host-key signature verification,
// chacha20-poly1305 keys, and an encrypted ssh-userauth service request.
// Host trust pinning, user authentication, exec/session channels, PTY, scp/sftp,
// known_hosts, and real entropy are separate milestones.

private let defaultIP: UInt32 = 0x0A00_0202     // 10.0.2.2 (QEMU slirp host)
private let defaultPort: UInt16 = 22
private let pollIn: Int16 = 0x001
private let clientVersion: StaticString = "SSH-2.0-swift-os_ssh-transport"
private let clientBanner: StaticString = "SSH-2.0-swift-os_ssh-transport\r\n"
private let disconnectText: StaticString =
    "swift-os ssh client transport preflight complete"

private let maxPacketLen = 8192
private let maxPayloadLen = 7800
private let sshBlockSize = 8

private let msgDisconnect: UInt8 = 1
private let msgServiceRequest: UInt8 = 5
private let msgServiceAccept: UInt8 = 6
private let msgKexInit: UInt8 = 20
private let msgNewKeys: UInt8 = 21
private let msgKexECDHInit: UInt8 = 30
private let msgKexECDHReply: UInt8 = 31

private func printUInt(_ v: UInt) {
    if v >= 10 { printUInt(v / 10) }
    swiftos_putc(UInt8(0x30 + (v % 10)))
}

private func cstrlen(_ p: UnsafePointer<CChar>) -> Int {
    var n = 0
    while p[n] != 0 { n += 1 }
    return n
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

private func parseIPv4(_ p: UnsafePointer<CChar>) -> UInt32? {
    var octets = (UInt32(0), UInt32(0), UInt32(0), UInt32(0))
    var idx = 0
    var cur: UInt32 = 0
    var digits = 0
    var i = 0
    while true {
        let ch = p[i]
        if ch >= 0x30 && ch <= 0x39 {
            cur = cur * 10 + UInt32(ch - 0x30)
            if cur > 255 { return nil }
            digits += 1
        } else if ch == 0x2E || ch == 0 {
            if digits == 0 || idx > 3 { return nil }
            if idx == 0 { octets.0 = cur }
            else if idx == 1 { octets.1 = cur }
            else if idx == 2 { octets.2 = cur }
            else { octets.3 = cur }
            idx += 1
            cur = 0
            digits = 0
            if ch == 0 { break }
        } else {
            return nil
        }
        i += 1
    }
    if idx != 4 { return nil }
    return (octets.0 << 24) | (octets.1 << 16) | (octets.2 << 8) | octets.3
}

private func parseArgs(_ argc: Int32,
                       _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?)
    -> (UInt32, UInt16) {
    var ip = defaultIP
    var port = defaultPort
    if argc >= 2, let a1 = argv?[1] {
        if let parsed = parseIPv4(a1) {
            ip = parsed
        } else if let parsedPort = parsePort(a1) {
            port = parsedPort
        }
    }
    if argc >= 3, let a2 = argv?[2], let parsedPort = parsePort(a2) {
        port = parsedPort
    }
    return (ip, port)
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

private func writeBanner(_ fd: Int32) -> Bool {
    clientBanner.withUTF8Buffer { writeExact(fd, $0.baseAddress!, $0.count) }
}

private func readServerBanner(_ fd: Int32,
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
    if x == 0 { x = 0xAF53_71D0_DA7A_5EED }
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

    mutating func u32() -> UInt32? {
        if off + 4 > len { return nil }
        let v = getU32BE(p, off)
        off += 4
        return v
    }

    mutating func skip(_ n: Int) -> Bool {
        if off + n > len { return false }
        off += n
        return true
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

private func nameListContains(_ view: SSHStringView, _ needle: StaticString) -> Bool {
    needle.withUTF8Buffer { nb -> Bool in
        var start = 0
        while start <= view.len {
            var end = start
            while end < view.len && view.p.load(fromByteOffset: end, as: UInt8.self) != 0x2C {
                end += 1
            }
            let segLen = end - start
            if segLen == nb.count && bytesEqual(view.p + start, nb.baseAddress!, segLen) {
                return true
            }
            if end == view.len { break }
            start = end + 1
        }
        return false
    }
}

private func kexInitHasName(_ payload: UnsafeRawPointer, _ len: Int,
                            _ name: StaticString) -> Bool {
    var r = SSHReader(p: payload, len: len)
    guard r.u8() == msgKexInit,
          r.skip(16),
          let kexNames = r.string() else {
        return false
    }
    return nameListContains(kexNames, name)
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

private func verifyHostSignature(exchangeHash: UnsafeRawPointer,
                                 hostKey: SSHStringView,
                                 sigBlob: SSHStringView) -> Bool {
    guard let pub = ed25519PublicKeyFromBlob(hostKey),
          let sig = signatureView(sigBlob) else {
        return false
    }
    return ed25519Verify(message: exchangeHash, 32,
                         signature: sig.p,
                         publicKey: pub.p)
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
        out.storeBytes(of: UInt8(0xC3 ^ UInt8((payloadLen + i) & 0xFF)),
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
        out.storeBytes(of: UInt8(0x3C ^ UInt8((payloadLen + i) & 0xFF)),
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
    guard w.u8(msgKexInit) else { return -1 }
    fillPseudoRandom(out + w.len, 16, 0x5353485f434b4558)
    w.len += 16

    guard writerStringStatic(&w, "curve25519-sha256,kex-strict-c-v00@openssh.com"),
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

private func buildExchangeHash(_ out32: UnsafeMutableRawPointer,
                               _ serverVersion: UnsafeRawPointer, _ serverVersionLen: Int,
                               _ clientKex: UnsafeRawPointer, _ clientKexLen: Int,
                               _ serverKex: UnsafeRawPointer, _ serverKexLen: Int,
                               _ hostKey: UnsafeRawPointer, _ hostKeyLen: Int,
                               _ clientPub: UnsafeRawPointer, _ serverPub: UnsafeRawPointer,
                               _ shared: UnsafeRawPointer) -> Bool {
    withUnsafeTemporaryAllocation(byteCount: 16384, alignment: 8) { raw -> Bool in
        var w = SSHWriter(p: raw.baseAddress!, cap: raw.count)
        let ok = clientVersion.withUTF8Buffer { cv -> Bool in
            w.string(cv.baseAddress!, cv.count) &&
            w.string(serverVersion, serverVersionLen) &&
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

private func sendServiceRequest(_ fd: Int32, _ packet: UnsafeMutableRawPointer, _ cap: Int,
                                _ key: UnsafeRawPointer, _ seq: inout UInt32) -> Bool {
    var w = SSHWriter(p: packet, cap: cap)
    guard w.u8(msgServiceRequest),
          writerStringStatic(&w, "ssh-userauth") else {
        return false
    }
    return sendEncryptedChachaPacket(fd, packet, w.len, key, &seq)
}

private func readServiceAccept(_ fd: Int32, _ packet: UnsafeMutableRawPointer, _ cap: Int,
                               _ key: UnsafeRawPointer, _ seq: inout UInt32) -> Bool {
    let n = readEncryptedChachaPacket(fd, packet, cap, key, &seq)
    if n <= 0 { return false }
    var r = SSHReader(p: packet, len: n)
    guard r.u8() == msgServiceAccept,
          let service = r.string(),
          stringEquals(service, "ssh-userauth") else {
        return false
    }
    return true
}

private func sendDisconnect(_ fd: Int32, _ packet: UnsafeMutableRawPointer, _ cap: Int,
                            _ key: UnsafeRawPointer, _ seq: inout UInt32) -> Bool {
    var w = SSHWriter(p: packet, cap: cap)
    guard w.u8(msgDisconnect),
          w.u32(11) else {
        return false
    }
    let ok = disconnectText.withUTF8Buffer { desc -> Bool in
        w.string(desc.baseAddress!, desc.count) && w.u32(0)
    }
    if !ok { return false }
    return sendEncryptedChachaPacket(fd, packet, w.len, key, &seq)
}

private func runTransport(_ fd: Int32) -> Bool {
    guard writeBanner(fd) else {
        swiftos_puts("ssh: banner write failed\n")
        return false
    }

    return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 256) { line in
      withUnsafeTemporaryAllocation(byteCount: maxPayloadLen, alignment: 8) { clientKex in
      withUnsafeTemporaryAllocation(byteCount: maxPayloadLen, alignment: 8) { serverKex in
      withUnsafeTemporaryAllocation(byteCount: maxPayloadLen, alignment: 8) { packet in
      withUnsafeTemporaryAllocation(byteCount: 64, alignment: 8) { clientKey in
      withUnsafeTemporaryAllocation(byteCount: 64, alignment: 8) { serverKey in
        let serverVersionLen = readServerBanner(fd, line)
        guard serverVersionLen > 0 && isSSHBanner(UnsafePointer(line.baseAddress!), serverVersionLen) else {
            swiftos_puts("ssh: invalid server banner\n")
            return false
        }
        swiftos_puts("ssh: server ")
        _ = swiftos_write(1, line.baseAddress, UInt(serverVersionLen))
        swiftos_puts("\n")

        var clientSeq: UInt32 = 0
        var serverSeq: UInt32 = 0
        let clientKexLen = buildKexInit(clientKex.baseAddress!, clientKex.count)
        guard clientKexLen > 0,
              sendPlainPacket(fd, clientKex.baseAddress!, clientKexLen, &clientSeq) else {
            swiftos_puts("ssh: could not send KEXINIT\n")
            return false
        }

        let serverKexLen = readPlainPacket(fd, serverKex.baseAddress!, serverKex.count, &serverSeq)
        guard serverKexLen > 0 &&
              serverKex.baseAddress!.load(fromByteOffset: 0, as: UInt8.self) == msgKexInit else {
            swiftos_puts("ssh: expected server KEXINIT\n")
            return false
        }
        let strictKex = kexInitHasName(serverKex.baseAddress!, serverKexLen,
                                       "kex-strict-s-v00@openssh.com")

        var clientPriv = (UInt64(0), UInt64(0), UInt64(0), UInt64(0))
        var clientPub = (UInt64(0), UInt64(0), UInt64(0), UInt64(0))
        withUnsafeMutableBytes(of: &clientPriv) { cp in
            fillPseudoRandom(cp.baseAddress!, 32, 0x5353485f434c4945)
        }
        var basePoint = (UInt64(9), UInt64(0), UInt64(0), UInt64(0))
        withUnsafeBytes(of: &clientPriv) { sk in
            withUnsafeBytes(of: &basePoint) { bp in
                withUnsafeMutableBytes(of: &clientPub) { pub in
                    x25519(sk.baseAddress!, bp.baseAddress!, pub.baseAddress!)
                }
            }
        }

        var w = SSHWriter(p: packet.baseAddress!, cap: packet.count)
        let initOK = withUnsafeBytes(of: &clientPub) { cpub -> Bool in
            w.u8(msgKexECDHInit) && w.string(cpub.baseAddress!, 32)
        }
        guard initOK,
              sendPlainPacket(fd, packet.baseAddress!, w.len, &clientSeq) else {
            swiftos_puts("ssh: could not send curve25519 init\n")
            return false
        }

        let replyLen = readPlainPacket(fd, packet.baseAddress!, packet.count, &serverSeq)
        guard replyLen > 0 else {
            swiftos_puts("ssh: ECDH reply read failed\n")
            return false
        }
        var r = SSHReader(p: packet.baseAddress!, len: replyLen)
        guard r.u8() == msgKexECDHReply,
              let hostKey = r.string(),
              let serverPub = r.string(),
              serverPub.len == 32,
              let sigBlob = r.string(),
              r.remaining == 0 else {
            swiftos_puts("ssh: malformed ECDH reply\n")
            return false
        }

        var shared = (UInt64(0), UInt64(0), UInt64(0), UInt64(0))
        withUnsafeBytes(of: &clientPriv) { sk in
            withUnsafeMutableBytes(of: &shared) { sh in
                x25519(sk.baseAddress!, serverPub.p, sh.baseAddress!)
            }
        }
        let sharedAllZero = withUnsafeBytes(of: &shared) { sh -> Bool in
            var acc: UInt8 = 0
            for i in 0..<32 { acc |= sh.load(fromByteOffset: i, as: UInt8.self) }
            return acc == 0
        }
        if sharedAllZero {
            swiftos_puts("ssh: all-zero shared secret\n")
            return false
        }

        var exchangeHash = (UInt64(0), UInt64(0), UInt64(0), UInt64(0))
        let hashOK = withUnsafeBytes(of: &clientPub) { cpub in
            withUnsafeBytes(of: &shared) { sh in
                withUnsafeMutableBytes(of: &exchangeHash) { hh in
                    buildExchangeHash(hh.baseAddress!,
                                      line.baseAddress!, serverVersionLen,
                                      clientKex.baseAddress!, clientKexLen,
                                      serverKex.baseAddress!, serverKexLen,
                                      hostKey.p, hostKey.len,
                                      cpub.baseAddress!, serverPub.p,
                                      sh.baseAddress!)
                }
            }
        }
        guard hashOK else {
            swiftos_puts("ssh: exchange hash failed\n")
            return false
        }
        let sigOK = withUnsafeBytes(of: &exchangeHash) { hh in
            verifyHostSignature(exchangeHash: hh.baseAddress!,
                                hostKey: hostKey,
                                sigBlob: sigBlob)
        }
        guard sigOK else {
            swiftos_puts("ssh: host key signature failed\n")
            return false
        }
        swiftos_puts("ssh: host key signature verified\n")

        let newKeysLen = readPlainPacket(fd, packet.baseAddress!, packet.count, &serverSeq)
        guard newKeysLen == 1 && packet.baseAddress!.load(fromByteOffset: 0, as: UInt8.self) == msgNewKeys else {
            swiftos_puts("ssh: expected server NEWKEYS\n")
            return false
        }
        packet.baseAddress!.storeBytes(of: msgNewKeys, toByteOffset: 0, as: UInt8.self)
        guard sendPlainPacket(fd, packet.baseAddress!, 1, &clientSeq) else {
            swiftos_puts("ssh: could not send NEWKEYS\n")
            return false
        }

        if strictKex {
            clientSeq = 0
            serverSeq = 0
            swiftos_puts("ssh: strict KEX sequence reset\n")
        }

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
            swiftos_puts("ssh: key derivation failed\n")
            return false
        }
        swiftos_puts("ssh: negotiated curve25519-sha256 ssh-ed25519 chacha20-poly1305@openssh.com\n")

        guard sendServiceRequest(fd, packet.baseAddress!, packet.count,
                                 clientKey.baseAddress!, &clientSeq),
              readServiceAccept(fd, packet.baseAddress!, packet.count,
                                serverKey.baseAddress!, &serverSeq) else {
            swiftos_puts("ssh: encrypted service request failed\n")
            return false
        }
        swiftos_puts("ssh: encrypted service accepted\n")
        _ = sendDisconnect(fd, packet.baseAddress!, packet.count,
                           clientKey.baseAddress!, &clientSeq)
        swiftos_puts("ssh: transport ready (preauth)\n")
        return true
      }}}}}}
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp
    let target = parseArgs(argc, argv)
    let fd = swiftos_socket_stream()
    if fd < 0 {
        swiftos_puts("ssh: socket failed\n")
        return 1
    }
    if swiftos_connect(fd, target.0, target.1) != 0 {
        swiftos_puts("ssh: connect failed\n")
        _ = swiftos_close(fd)
        return 1
    }
    swiftos_puts("ssh: connected to port ")
    printUInt(UInt(target.1))
    swiftos_puts("\n")

    let ok = runTransport(fd)
    _ = swiftos_close(fd)
    return ok ? 0 : 1
}
