// SPDX-License-Identifier: Apache-2.0
// sshd.swift — SSH server transport preflight for swift-os.
//
// This is still not a complete SSH login daemon. It proves the modern transport
// path that Hetzner-style remote access needs next: TCP/22, SSH identification,
// KEXINIT negotiation, curve25519-sha256 key exchange, ssh-ed25519 host-key
// signature, NEWKEYS, and an encrypted pre-auth disconnect. User auth, PTY,
// session channels, scp/sftp, service supervision, and real host-key storage are
// separate milestones.

private let defaultPort: UInt16 = 22
private let pollIn: Int16 = 0x001
private let serverVersion: StaticString = "SSH-2.0-swift-os_sshd-kex"
private let serverBanner: StaticString = "SSH-2.0-swift-os_sshd-kex\r\n"
private let disconnectText: StaticString =
    "swift-os sshd kex preflight: userauth/session not enabled yet"

private let maxPacketLen = 8192
private let maxPayloadLen = 7800
private let sshBlockSize = 8

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

private func fillDevHostSeed(_ p: UnsafeMutableRawPointer) {
    let bytes: (UInt64, UInt64, UInt64, UInt64) = (
        0x4b45_5831_5f53_574f, 0x5353_4844_5f44_4556,
        0x4845_545a_4e45_525f, 0x484f_5354_4b45_5931
    )
    withUnsafeBytes(of: bytes) { raw in copyBytes(p, 0, raw.baseAddress!, 32) }
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

private func writerStatic(_ w: inout SSHWriter, _ s: StaticString) -> Bool {
    s.withUTF8Buffer { w.bytes($0.baseAddress!, $0.count) }
}

private func writerStringStatic(_ w: inout SSHWriter, _ s: StaticString) -> Bool {
    s.withUTF8Buffer { w.string($0.baseAddress!, $0.count) }
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

private func buildDisconnectPayload(_ out: UnsafeMutableRawPointer, _ cap: Int) -> Int {
    var w = SSHWriter(p: out, cap: cap)
    guard w.u8(1),
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
      withUnsafeTemporaryAllocation(byteCount: 64, alignment: 8) { keyOut in
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

        withUnsafeMutableBytes(of: &hostSeed) { hs in fillDevHostSeed(hs.baseAddress!) }
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

        let keyOK = withUnsafeBytes(of: &shared) { sh in
            withUnsafeBytes(of: &exchangeHash) { hh in
                deriveSSHKey(keyOut.baseAddress!, 64, 0x44, sh.baseAddress!, hh.baseAddress!)
            }
        }
        guard keyOK else {
            swiftos_puts("sshd: key derivation failed\n")
            return
        }
        let discLen = buildDisconnectPayload(packet.baseAddress!, packet.count)
        guard discLen > 0,
              sendEncryptedChachaPacket(fd, packet.baseAddress!, discLen,
                                        keyOut.baseAddress!, &serverSeq) else {
            swiftos_puts("sshd: encrypted disconnect failed\n")
            return
        }
        _ = clientSeq
        swiftos_puts("sshd: kex complete; sent encrypted preauth disconnect\n")
      }}}}}}}
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
    swiftos_puts(" (transport kex preflight)\n")

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
