// SPDX-License-Identifier: Apache-2.0
// tls13.swift — a minimal, sans-IO TLS 1.3 client (RFC 8446) for swift-os.
//
// ⚠️  SECURITY WARNING — NO CERTIFICATE VERIFICATION.
//     This client accepts ANY server certificate without validating the chain,
//     the signature in CertificateVerify, the server name, or expiry. It is
//     therefore vulnerable to active man-in-the-middle attacks and provides
//     confidentiality only against a passive eavesdropper. Certificate
//     verification (X.509 parsing + an Ed25519/ECDSA/RSA-PSS verifier + a trust
//     store) is deliberately DEFERRED to a later track. DO NOT use this for
//     anything that must be authenticated. It exists to bring up the TLS 1.3
//     record/handshake machinery end-to-end over our socket layer.
//
// Pure, sans-IO, allocator-light Swift: it never touches a socket itself. The
// caller pumps bytes in (`feedTLS`) and drains bytes out (`takeTLS`), so the
// exact same source compiles for the host unit test (tests/tls_handshake_test
// .swift) and into the /bin/tlsget userland ELF. It links the pure crypto
// modules kernel/crypto/{sha256,x25519,chacha20poly1305}.swift.
//
// Scope (single, opinionated cipher suite — "modern over legacy", CLAUDE.md):
//   - key exchange:   X25519 only (RFC 7748)
//   - AEAD:           TLS_CHACHA20_POLY1305_SHA256 only (RFC 8439)
//   - hash:           SHA-256
//   - no session resumption / PSK / early-data / HelloRetryRequest / 0-RTT.
// The key schedule is RFC 8446 §7.1 (HKDF-Expand-Label / Derive-Secret) built on
// the A1 HKDF. The record layer is §5 (per-record nonce = iv XOR seq, AAD = the
// 5-byte record header, inner plaintext carries a trailing content-type byte).

// MARK: - Small byte helpers (self-contained, no Foundation)

@inline(__always) private func tb(_ p: UnsafeRawPointer, _ off: Int) -> UInt8 {
    p.load(fromByteOffset: off, as: UInt8.self)
}
@inline(__always) private func tbset(_ p: UnsafeMutableRawPointer, _ off: Int, _ v: UInt8) {
    p.storeBytes(of: v, toByteOffset: off, as: UInt8.self)
}

// MARK: - Constants

private let recordHeaderLen = 5
let tlsMaxRecord = 16384 + 256            // RFC 8446 §5.2 plaintext bound + AEAD overhead
private let hashLen = 32                  // SHA-256
private let keyLen = 32                   // ChaCha20 key
private let ivLen = 12                    // AEAD nonce
private let tagLen = 16                   // Poly1305 tag

// Content types (RFC 8446 §5.1) and handshake types (§4).
private let ctChangeCipherSpec: UInt8 = 20
private let ctAlert: UInt8 = 21
private let ctHandshake: UInt8 = 22
private let ctApplicationData: UInt8 = 23

private let hsClientHello: UInt8 = 1
private let hsServerHello: UInt8 = 2
private let hsNewSessionTicket: UInt8 = 4
private let hsEncryptedExtensions: UInt8 = 8
private let hsCertificate: UInt8 = 11
private let hsCertificateVerify: UInt8 = 15
private let hsFinished: UInt8 = 20

// MARK: - Key schedule (RFC 8446 §7.1)

/// HKDF-Expand-Label (RFC 8446 §7.1): builds the structured `HkdfLabel` and runs
/// HKDF-Expand from the A1 module. `label` is the suffix after the "tls13 "
/// prefix; `context` is a transcript hash (or empty). Writes `outLen` bytes.
func hkdfExpandLabel(secret: UnsafeRawPointer,
                     label: UnsafeRawPointer, labelLen: Int,
                     context: UnsafeRawPointer, contextLen: Int,
                     out: UnsafeMutableRawPointer, outLen: Int) {
    // HkdfLabel = length(2) || "tls13 "+label as opaque<7..255> || context opaque<0..255>.
    let prefix: [UInt8] = [0x74, 0x6c, 0x73, 0x31, 0x33, 0x20]   // "tls13 "
    let fullLabelLen = prefix.count + labelLen
    let infoLen = 2 + 1 + fullLabelLen + 1 + contextLen
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: infoLen) { ib in
        let info = ib.baseAddress!
        var w = 0
        tbset(info, w, UInt8((outLen >> 8) & 0xFF)); w += 1
        tbset(info, w, UInt8(outLen & 0xFF)); w += 1
        tbset(info, w, UInt8(fullLabelLen)); w += 1
        for i in 0..<prefix.count { tbset(info, w + i, prefix[i]) }; w += prefix.count
        for i in 0..<labelLen { tbset(info, w + i, tb(label, i)) }; w += labelLen
        tbset(info, w, UInt8(contextLen)); w += 1
        for i in 0..<contextLen { tbset(info, w + i, tb(context, i)) }; w += contextLen
        hkdfExpand(prk: secret, info: info, infoLen: w, out: out, outLen: outLen)
    }
}

/// Derive-Secret(secret, label, messages) = HKDF-Expand-Label(secret, label,
/// Hash(messages), Hash.length). `transcript`/`transcriptLen` is the *already
/// hashed* transcript when `transcriptIsHash` is true, else the raw messages.
private func deriveSecret(secret: UnsafeRawPointer,
                          label: UnsafeRawPointer, labelLen: Int,
                          transcriptHash: UnsafeRawPointer,
                          out32: UnsafeMutableRawPointer) {
    hkdfExpandLabel(secret: secret, label: label, labelLen: labelLen,
                    context: transcriptHash, contextLen: hashLen,
                    out: out32, outLen: hashLen)
}

// MARK: - Record protection primitives (RFC 8446 §5, shared by the engine + test)

/// Build the per-record nonce: the 12-byte `iv` XORed with the 64-bit sequence
/// number `seq`, right-aligned (RFC 8446 §5.3). Writes 12 bytes to `out`.
func tlsRecordNonce(iv: UnsafeRawPointer, seq: UInt64, out: UnsafeMutableRawPointer) {
    for i in 0..<ivLen { tbset(out, i, tb(iv, i)) }
    var s = seq
    var i = ivLen - 1
    while i >= ivLen - 8 {
        tbset(out, i, tb(out, i) ^ UInt8(s & 0xFF))
        s >>= 8
        i -= 1
    }
}

/// Seal one TLS 1.3 record. The inner plaintext is `plaintext[0..<plen]` followed
/// by the real `contentType` byte (TLSInnerPlaintext, RFC 8446 §5.2). The output
/// is the full wire record: a 5-byte application_data(23) header, the ciphertext,
/// then the 16-byte tag — appended to `out`. nonce = `key`'s IV XOR `seq`; the AAD
/// is the output header (its length covers ciphertext+tag).
func tlsRecordSeal(key: UnsafeRawPointer, iv: UnsafeRawPointer, seq: UInt64,
                   contentType: UInt8, plaintext: UnsafeRawPointer, plen: Int,
                   out: inout [UInt8]) {
    let innerLen = plen + 1
    let recLen = innerLen + tagLen
    let header: [UInt8] = [ctApplicationData, 0x03, 0x03,
                           UInt8((recLen >> 8) & 0xFF), UInt8(recLen & 0xFF)]
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: innerLen) { inb in
        let inner = inb.baseAddress!
        for i in 0..<plen { tbset(inner, i, tb(plaintext, i)) }
        tbset(inner, plen, contentType)
        var nonce = [UInt8](repeating: 0, count: ivLen)
        nonce.withUnsafeMutableBytes { tlsRecordNonce(iv: iv, seq: seq, out: $0.baseAddress!) }
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: innerLen) { ctb in
            let ct = ctb.baseAddress!
            var tag = [UInt8](repeating: 0, count: tagLen)
            let scratchLen = header.count + innerLen + 64
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: scratchLen) { scr in
                nonce.withUnsafeBytes { np in
                    header.withUnsafeBytes { ap in
                        tag.withUnsafeMutableBytes { tp in
                            aeadSeal(key: key, nonce: np.baseAddress!,
                                     aad: ap.baseAddress!, aadLen: header.count,
                                     plaintext: inner, ptLen: innerLen,
                                     ciphertext: ct, tagOut: tp.baseAddress!,
                                     scratch: scr.baseAddress!)
                        }
                    }
                }
            }
            out.append(contentsOf: header)
            for i in 0..<innerLen { out.append(tb(ct, i)) }
            out.append(contentsOf: tag)
        }
    }
}

/// Open one TLS 1.3 record fragment (`body[0..<bodyLen]` = ciphertext ‖ 16-byte
/// tag). On success returns the inner content type and writes the decrypted
/// payload (TLSInnerPlaintext with trailing type byte and zero padding stripped)
/// to `out`/`outLen`; returns nil on auth failure or malformed padding. The AAD
/// is reconstructed from the outer header as the engine received it.
func tlsRecordOpen(key: UnsafeRawPointer, iv: UnsafeRawPointer, seq: UInt64,
                   body: UnsafeRawPointer, bodyLen: Int,
                   out: UnsafeMutableRawPointer, outLen: inout Int) -> UInt8? {
    if bodyLen < tagLen { return nil }
    let ctLen = bodyLen - tagLen
    let aad: [UInt8] = [ctApplicationData, 0x03, 0x03,
                        UInt8((bodyLen >> 8) & 0xFF), UInt8(bodyLen & 0xFF)]
    var nonce = [UInt8](repeating: 0, count: ivLen)
    nonce.withUnsafeMutableBytes { tlsRecordNonce(iv: iv, seq: seq, out: $0.baseAddress!) }
    var resultType: UInt8? = nil
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: max(1, ctLen)) { ptb in
        let pt = ptb.baseAddress!
        let scratchLen = aad.count + ctLen + 64
        var ok = false
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: scratchLen) { scr in
            nonce.withUnsafeBytes { np in
                aad.withUnsafeBytes { ap in
                    ok = aeadOpen(key: key, nonce: np.baseAddress!,
                                  aad: ap.baseAddress!, aadLen: aad.count,
                                  ciphertext: body, ctLen: ctLen,
                                  tag: body.advanced(by: ctLen),
                                  plaintext: pt, scratch: scr.baseAddress!)
                }
            }
        }
        if !ok { return }
        var end = ctLen
        while end > 0 && tb(pt, end - 1) == 0 { end -= 1 }
        if end == 0 { return }      // all-zero: no content type, malformed
        resultType = tb(pt, end - 1)
        outLen = end - 1
        for i in 0..<outLen { tbset(out, i, tb(pt, i)) }
    }
    return resultType
}

// MARK: - Running transcript hash (SHA-256 over all handshake messages)

// We keep the concatenated handshake messages in a growable buffer and re-hash
// on demand. Handshake transcripts in our no-resumption flow are small (a few KB
// at most: ClientHello + ServerHello + EE + Cert + CertVerify + Finished), so a
// bounded buffer is fine and avoids implementing an incremental SHA-256.
private let transcriptCap = 16384

// MARK: - TLS 1.3 client engine

/// Result of pumping the handshake forward.
enum TLSProgress {
    case needMoreData          // not enough bytes yet; feed more
    case handshakeComplete     // ready for application data
    case failed                // protocol/decrypt error (see lastError)
}

/// A sans-IO TLS 1.3 client. Lifecycle:
///   1. `init(hostname:)`
///   2. `startHandshake()` → emits a ClientHello (drain via `takeTLS`)
///   3. loop: read socket → `feedTLS(_:)` → `advance()`; whenever `advance()`
///      returns `.needMoreData`, drain `takeTLS` and write it to the socket.
///   4. on `.handshakeComplete`: `sendAppData(_:)` / `receiveAppData(into:)`.
/// Single cipher suite (TLS_CHACHA20_POLY1305_SHA256), X25519 key share only.
final class TLS13Client {
    // Ephemeral X25519 key pair for the key share.
    private var ephSecret = [UInt8](repeating: 0, count: 32)
    private var ephPublic = [UInt8](repeating: 0, count: 32)

    // Handshake transcript (raw concatenated handshake messages) + length.
    private var transcript = [UInt8](repeating: 0, count: transcriptCap)
    private var transcriptLen = 0

    // Inbound TLS byte buffer (records may span multiple socket reads).
    private var inbuf = [UInt8](repeating: 0, count: tlsMaxRecord * 2)
    private var inlen = 0

    // Outbound TLS bytes the caller must write to the socket.
    private var outbuf = [UInt8]()

    // Decrypted application data waiting for the caller to read.
    private var appbuf = [UInt8]()

    // Key schedule secrets / traffic keys.
    private var handshakeSecret = [UInt8](repeating: 0, count: 32)
    private var masterSecret = [UInt8](repeating: 0, count: 32)
    private var clientHsTraffic = [UInt8](repeating: 0, count: 32)
    private var serverHsTraffic = [UInt8](repeating: 0, count: 32)
    private var clientAppTraffic = [UInt8](repeating: 0, count: 32)
    private var serverAppTraffic = [UInt8](repeating: 0, count: 32)

    // Active read/write keys, IVs and sequence numbers (handshake then app).
    private var rdKey = [UInt8](repeating: 0, count: keyLen)
    private var rdIV = [UInt8](repeating: 0, count: ivLen)
    private var rdSeq: UInt64 = 0
    private var wrKey = [UInt8](repeating: 0, count: keyLen)
    private var wrIV = [UInt8](repeating: 0, count: ivLen)
    private var wrSeq: UInt64 = 0
    private var encryptingOut = false      // are *outbound* records encrypted yet?

    // Handshake phase tracker.
    private enum Phase { case start, sentHello, gotServerHello, established, dead }
    private var phase: Phase = .start

    /// Last error code (for diagnostics); 0 == none.
    private(set) var lastError: Int = 0

    // Optional server-certificate verification (opt-in; default off preserves the
    // legacy unauthenticated behavior). Only ECDSA-P256 leaves are supported for
    // CertificateVerify; RSA-PSS leaves are not implemented.
    private var verifyEnabled = false
    private var trustRoots: [X509Cert] = []
    private var expectHostname: String = ""
    private var verifyNow: UInt64 = 0
    private var chainLeaf: X509Cert? = nil
    private var chainInters: [X509Cert] = []

    init() {}

    /// Enable certificate verification before the handshake reaches the server
    /// Certificate. `rootsDER` are trusted self-signed roots; the leaf must chain
    /// to one, be valid at `now` (YYYYMMDDHHMMSS), and carry `hostname` in its SAN.
    func enableVerification(rootsDER: [[UInt8]], hostname: String, now: UInt64) {
        trustRoots = []
        for d in rootsDER { if let c = parseX509(d) { trustRoots.append(c) } }
        expectHostname = hostname
        verifyNow = now
        verifyEnabled = true
    }

    // MARK: Public sans-IO surface

    /// Begin the handshake: generate the X25519 key pair and queue a ClientHello.
    /// Pass 32 bytes of randomness for the ephemeral private key in `randomSK`
    /// and 32 bytes for ClientHello.random in `randomCH` (the caller owns entropy;
    /// in /bin/tlsget these come from the kernel's getrandom-style source).
    func startHandshake(randomSK: UnsafeRawPointer, randomCH: UnsafeRawPointer) {
        for i in 0..<32 { ephSecret[i] = tb(randomSK, i) }
        // Public key = X25519(sk, basepoint 9).
        var basepoint = [UInt8](repeating: 0, count: 32); basepoint[0] = 9
        ephSecret.withUnsafeBytes { sk in
            basepoint.withUnsafeBytes { bp in
                ephPublic.withUnsafeMutableBytes { pk in
                    x25519(sk.baseAddress!, bp.baseAddress!, pk.baseAddress!)
                }
            }
        }
        emitClientHello(randomCH: randomCH)
        phase = .sentHello
    }

    /// Feed `n` bytes received from the socket into the engine.
    func feedTLS(_ src: UnsafeRawPointer, _ n: Int) {
        if inlen + n > inbuf.count {
            // Grow if a peer sends more than our default buffer (rare).
            inbuf.append(contentsOf: repeatElement(0, count: inlen + n - inbuf.count))
        }
        for i in 0..<n { inbuf[inlen + i] = tb(src, i) }
        inlen += n
    }

    /// Number of outbound bytes queued for the socket.
    var pendingOut: Int { outbuf.count }

    /// Copy up to `cap` queued outbound bytes into `dst`; returns the count and
    /// removes them from the queue.
    func takeTLS(_ dst: UnsafeMutableRawPointer, _ cap: Int) -> Int {
        let n = min(cap, outbuf.count)
        for i in 0..<n { tbset(dst, i, outbuf[i]) }
        if n > 0 { outbuf.removeFirst(n) }
        return n
    }

    /// Drive the state machine over whatever inbound bytes have arrived. After
    /// the handshake completes this also decrypts inbound application_data
    /// records into the `receiveAppData` buffer, so the caller keeps pumping
    /// read→`feedTLS`→`advance` and draining `receiveAppData` until EOF/alert.
    func advance() -> TLSProgress {
        if phase == .dead { return .failed }
        while true {
            guard let (ct, body, bodyLen, consumed) = peekRecord() else {
                return phase == .established ? .handshakeComplete : .needMoreData
            }
            // Skip legacy ChangeCipherSpec (RFC 8446 §5: middlebox compatibility).
            if ct == ctChangeCipherSpec {
                dropInbound(consumed)
                continue
            }
            if ct == ctAlert {
                lastError = 100
                phase = .dead
                return .failed
            }
            if !handleRecord(ct: ct, body: body, bodyLen: bodyLen) {
                phase = .dead
                return .failed
            }
            dropInbound(consumed)
            if phase == .dead { return .failed }
        }
    }

    /// Encrypt `n` plaintext bytes as one application-data record, queued for the
    /// socket (drain with `takeTLS`). Valid only after `.handshakeComplete`.
    func sendAppData(_ src: UnsafeRawPointer, _ n: Int) {
        if phase != .established { return }
        emitEncrypted(contentType: ctApplicationData, plaintext: src, plen: n)
    }

    /// Bytes of decrypted application data available to read.
    var pendingAppData: Int { appbuf.count }

    /// Copy up to `cap` decrypted application bytes into `dst`; returns count.
    func receiveAppData(_ dst: UnsafeMutableRawPointer, _ cap: Int) -> Int {
        let n = min(cap, appbuf.count)
        for i in 0..<n { tbset(dst, i, appbuf[i]) }
        if n > 0 { appbuf.removeFirst(n) }
        return n
    }

    // MARK: Transcript

    private func transcriptAppend(_ p: UnsafeRawPointer, _ n: Int) {
        if transcriptLen + n > transcript.count {
            transcript.append(contentsOf: repeatElement(0, count: transcriptLen + n - transcript.count))
        }
        for i in 0..<n { transcript[transcriptLen + i] = tb(p, i) }
        transcriptLen += n
    }

    /// SHA-256 over the current transcript into `out32`.
    private func transcriptHash(_ out32: UnsafeMutableRawPointer) {
        transcript.withUnsafeBytes { tp in
            sha256(tp.baseAddress!, transcriptLen, out32)
        }
    }

    // MARK: Record framing (plaintext side)

    /// Peek the next record without consuming it. Returns (contentType, pointer
    /// into `inbuf` at the record fragment, fragmentLen, totalRecordBytes) or nil
    /// if a full record has not arrived. For encrypted records the contentType is
    /// the outer one (application_data); decryption happens in handleRecord.
    private func peekRecord() -> (UInt8, UnsafeRawPointer, Int, Int)? {
        if inlen < recordHeaderLen { return nil }
        return inbuf.withUnsafeBytes { ib -> (UInt8, UnsafeRawPointer, Int, Int)? in
            let base = ib.baseAddress!
            let ct = tb(base, 0)
            let len = (Int(tb(base, 3)) << 8) | Int(tb(base, 4))
            if len > tlsMaxRecord { lastError = 101; return nil }
            if inlen < recordHeaderLen + len { return nil }
            let frag = base.advanced(by: recordHeaderLen)
            return (ct, frag, len, recordHeaderLen + len)
        }
    }

    private func dropInbound(_ n: Int) {
        let rem = inlen - n
        if rem > 0 {
            for i in 0..<rem { inbuf[i] = inbuf[n + i] }
        }
        inlen = rem
    }

    // MARK: ClientHello

    private func emitClientHello(randomCH: UnsafeRawPointer) {
        // Build the ClientHello body, then wrap it in a handshake header and a
        // plaintext record. Extensions: supported_versions(TLS1.3),
        // supported_groups(x25519), signature_algorithms(a permissive set),
        // key_share(x25519=ephPublic). No SNI by default (cert checks are off).
        var ch = [UInt8]()
        @inline(__always) func u8(_ v: UInt8) { ch.append(v) }
        @inline(__always) func u16(_ v: Int) { ch.append(UInt8((v >> 8) & 0xFF)); ch.append(UInt8(v & 0xFF)) }

        u16(0x0303)                                  // legacy_version = TLS 1.2
        for i in 0..<32 { ch.append(tb(randomCH, i)) } // 32-byte random
        u8(0)                                         // legacy_session_id (empty)
        // cipher_suites: just TLS_CHACHA20_POLY1305_SHA256 = {0x13,0x03}.
        u16(2); u8(0x13); u8(0x03)
        // legacy_compression_methods: { null }.
        u8(1); u8(0)

        // ---- Extensions ----
        var ext = [UInt8]()
        @inline(__always) func e8(_ v: UInt8) { ext.append(v) }
        @inline(__always) func e16(_ v: Int) { ext.append(UInt8((v >> 8) & 0xFF)); ext.append(UInt8(v & 0xFF)) }
        // supported_versions (43): list of one = 0x0304 (TLS 1.3).
        e16(43); e16(3); e8(2); e16(0x0304)
        // supported_groups (10): list of one = x25519 (0x001d).
        e16(10); e16(4); e16(2); e16(0x001d)
        // signature_algorithms (13): a permissive set (we don't verify, but the
        // server may require the extension to be present). Offer common schemes.
        let sigs: [Int] = [0x0403, 0x0804, 0x0401, 0x0805, 0x0501, 0x0806, 0x0601, 0x0203]
        e16(13); e16(2 + sigs.count * 2); e16(sigs.count * 2)
        for s in sigs { e16(s) }
        // key_share (51): one entry: group x25519, our 32-byte public key.
        e16(51); e16(2 + 2 + 2 + 32); e16(2 + 2 + 32); e16(0x001d); e16(32)
        for b in ephPublic { ext.append(b) }

        u16(ext.count)
        ch.append(contentsOf: ext)

        // Wrap as a handshake message: type(1)=client_hello, length(3), body.
        var hs = [UInt8]()
        hs.append(hsClientHello)
        hs.append(UInt8((ch.count >> 16) & 0xFF))
        hs.append(UInt8((ch.count >> 8) & 0xFF))
        hs.append(UInt8(ch.count & 0xFF))
        hs.append(contentsOf: ch)

        // Feed the handshake message to the transcript, then frame as a record.
        hs.withUnsafeBytes { transcriptAppend($0.baseAddress!, $0.count) }
        emitPlaintextRecord(contentType: ctHandshake, payload: hs)
    }

    // MARK: Outbound records

    private func emitPlaintextRecord(contentType: UInt8, payload: [UInt8]) {
        outbuf.append(contentType)
        outbuf.append(0x03); outbuf.append(0x03)            // legacy_record_version
        outbuf.append(UInt8((payload.count >> 8) & 0xFF))
        outbuf.append(UInt8(payload.count & 0xFF))
        outbuf.append(contentsOf: payload)
    }

    /// Encrypt one record (inner = plaintext ‖ contentType byte) under the write
    /// key/IV/seq and queue it for the socket. Delegates to the shared
    /// `tlsRecordSeal` so the engine and the host test exercise the same code.
    private func emitEncrypted(contentType: UInt8, plaintext: UnsafeRawPointer, plen: Int) {
        wrKey.withUnsafeBytes { kp in
            wrIV.withUnsafeBytes { ivp in
                tlsRecordSeal(key: kp.baseAddress!, iv: ivp.baseAddress!, seq: wrSeq,
                              contentType: contentType, plaintext: plaintext, plen: plen,
                              out: &outbuf)
            }
        }
        wrSeq &+= 1
    }

    // MARK: Inbound record handling

    private func handleRecord(ct: UInt8, body: UnsafeRawPointer, bodyLen: Int) -> Bool {
        if phase == .sentHello {
            // Expect a plaintext ServerHello (handshake record).
            if ct != ctHandshake { lastError = 102; return false }
            return handleServerHelloRecord(body: body, bodyLen: bodyLen)
        }
        // After ServerHello everything is encrypted under handshake keys; the
        // outer content type is application_data(23).
        if ct != ctApplicationData { lastError = 103; return false }
        return handleEncryptedRecord(body: body, bodyLen: bodyLen)
    }

    private func handleServerHelloRecord(body: UnsafeRawPointer, bodyLen: Int) -> Bool {
        // Add the raw handshake message to the transcript first.
        transcriptAppend(body, bodyLen)
        // Parse: type(1)=server_hello, len(3), then ServerHello body.
        if bodyLen < 4 || tb(body, 0) != hsServerHello { lastError = 104; return false }
        let hsLen = (Int(tb(body, 1)) << 16) | (Int(tb(body, 2)) << 8) | Int(tb(body, 3))
        if 4 + hsLen > bodyLen { lastError = 105; return false }
        // Walk to the extensions to find key_share (group x25519) -> server pubkey.
        var off = 4
        off += 2                                     // legacy_version
        off += 32                                    // random
        if off >= bodyLen { lastError = 106; return false }
        let sidLen = Int(tb(body, off)); off += 1 + sidLen   // legacy_session_id_echo
        off += 2                                     // cipher_suite (must be 0x1303)
        off += 1                                     // legacy_compression_method
        if off + 2 > bodyLen { lastError = 107; return false }
        let extLen = (Int(tb(body, off)) << 8) | Int(tb(body, off + 1)); off += 2
        let extEnd = off + extLen
        if extEnd > bodyLen { lastError = 108; return false }
        var serverPub = [UInt8](repeating: 0, count: 32)
        var haveKeyShare = false
        while off + 4 <= extEnd {
            let etype = (Int(tb(body, off)) << 8) | Int(tb(body, off + 1))
            let elen = (Int(tb(body, off + 2)) << 8) | Int(tb(body, off + 3))
            let edata = off + 4
            if edata + elen > extEnd { lastError = 109; return false }
            if etype == 51 {                         // key_share
                // group(2) || key_exchange<...>; expect x25519 + 32-byte pubkey.
                if elen >= 4 {
                    let group = (Int(tb(body, edata)) << 8) | Int(tb(body, edata + 1))
                    let klen = (Int(tb(body, edata + 2)) << 8) | Int(tb(body, edata + 3))
                    if group == 0x001d && klen == 32 && edata + 4 + 32 <= extEnd {
                        for i in 0..<32 { serverPub[i] = tb(body, edata + 4 + i) }
                        haveKeyShare = true
                    }
                }
            }
            off = edata + elen
        }
        if !haveKeyShare { lastError = 110; return false }

        // ECDHE shared secret = X25519(ephSecret, serverPub).
        var shared = [UInt8](repeating: 0, count: 32)
        ephSecret.withUnsafeBytes { sk in
            serverPub.withUnsafeBytes { pk in
                shared.withUnsafeMutableBytes { out in
                    x25519(sk.baseAddress!, pk.baseAddress!, out.baseAddress!)
                }
            }
        }
        deriveHandshakeKeys(sharedSecret: shared)
        phase = .gotServerHello
        return true
    }

    /// Derive the handshake traffic secrets and install the handshake read/write
    /// keys. Transcript at this point = ClientHello || ServerHello (RFC 8446
    /// §7.1: handshake secrets use Hash(CH..SH)).
    private func deriveHandshakeKeys(sharedSecret: [UInt8]) {
        let zeros = [UInt8](repeating: 0, count: 32)
        var earlySecret = [UInt8](repeating: 0, count: 32)
        // early_secret = HKDF-Extract(0, 0).
        zeros.withUnsafeBytes { z in
            earlySecret.withUnsafeMutableBytes { es in
                hkdfExtract(salt: z.baseAddress!, saltLen: 32,
                            ikm: z.baseAddress!, ikmLen: 32, prkOut: es.baseAddress!)
            }
        }
        // derived = Derive-Secret(early, "derived", "") — context is Hash("").
        var derived = [UInt8](repeating: 0, count: 32)
        var emptyHash = [UInt8](repeating: 0, count: 32)
        emptyHash.withUnsafeMutableBytes { eh in sha256(eh.baseAddress!, 0, eh.baseAddress!) }
        let derivedLabel: [UInt8] = Array("derived".utf8)
        earlySecret.withUnsafeBytes { es in
            derivedLabel.withUnsafeBytes { lb in
                emptyHash.withUnsafeBytes { eh in
                    derived.withUnsafeMutableBytes { d in
                        hkdfExpandLabel(secret: es.baseAddress!, label: lb.baseAddress!,
                                        labelLen: derivedLabel.count,
                                        context: eh.baseAddress!, contextLen: hashLen,
                                        out: d.baseAddress!, outLen: hashLen)
                    }
                }
            }
        }
        // handshake_secret = HKDF-Extract(derived, ECDHE).
        derived.withUnsafeBytes { d in
            sharedSecret.withUnsafeBytes { ss in
                handshakeSecret.withUnsafeMutableBytes { hsk in
                    hkdfExtract(salt: d.baseAddress!, saltLen: 32,
                                ikm: ss.baseAddress!, ikmLen: 32, prkOut: hsk.baseAddress!)
                }
            }
        }
        // c/s hs traffic = Derive-Secret(handshake_secret, "c/s hs traffic", CH..SH).
        var th = [UInt8](repeating: 0, count: 32)
        th.withUnsafeMutableBytes { transcriptHash($0.baseAddress!) }
        deriveLabeled(secret: handshakeSecret, label: "c hs traffic", th: th, out: &clientHsTraffic)
        deriveLabeled(secret: handshakeSecret, label: "s hs traffic", th: th, out: &serverHsTraffic)
        // Install handshake keys: we READ with server's, WRITE with client's.
        installKeys(readSecret: serverHsTraffic, writeSecret: clientHsTraffic)
    }

    private func deriveLabeled(secret: [UInt8], label: String, th: [UInt8], out: inout [UInt8]) {
        let lb: [UInt8] = Array(label.utf8)
        secret.withUnsafeBytes { s in
            lb.withUnsafeBytes { l in
                th.withUnsafeBytes { t in
                    out.withUnsafeMutableBytes { o in
                        deriveSecret(secret: s.baseAddress!, label: l.baseAddress!,
                                     labelLen: lb.count, transcriptHash: t.baseAddress!,
                                     out32: o.baseAddress!)
                    }
                }
            }
        }
    }

    /// From traffic secrets, derive {key,iv} via Expand-Label and reset sequence
    /// numbers to 0 (a key change always restarts the record sequence, §5.3).
    private func installKeys(readSecret: [UInt8], writeSecret: [UInt8]) {
        expandKeyIV(secret: readSecret, key: &rdKey, iv: &rdIV); rdSeq = 0
        expandKeyIV(secret: writeSecret, key: &wrKey, iv: &wrIV); wrSeq = 0
    }

    private func expandKeyIV(secret: [UInt8], key: inout [UInt8], iv: inout [UInt8]) {
        let kl: [UInt8] = Array("key".utf8)
        let il: [UInt8] = Array("iv".utf8)
        secret.withUnsafeBytes { s in
            kl.withUnsafeBytes { l in
                key.withUnsafeMutableBytes { o in
                    hkdfExpandLabel(secret: s.baseAddress!, label: l.baseAddress!, labelLen: kl.count,
                                    context: l.baseAddress!, contextLen: 0, out: o.baseAddress!, outLen: keyLen)
                }
            }
            il.withUnsafeBytes { l in
                iv.withUnsafeMutableBytes { o in
                    hkdfExpandLabel(secret: s.baseAddress!, label: l.baseAddress!, labelLen: il.count,
                                    context: l.baseAddress!, contextLen: 0, out: o.baseAddress!, outLen: ivLen)
                }
            }
        }
    }

    /// Decrypt an encrypted record and dispatch its inner content. Multiple
    /// handshake messages may be coalesced in one record; we walk them all.
    /// Delegates AEAD-open + unpadding to the shared `tlsRecordOpen`.
    private func handleEncryptedRecord(body: UnsafeRawPointer, bodyLen: Int) -> Bool {
        if bodyLen < tagLen { lastError = 111; return false }
        let ctLen = bodyLen - tagLen
        let usedSeq = rdSeq                  // the sequence we decrypt this record at
        var ok = false
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: max(1, ctLen)) { ptb in
            let pt = ptb.baseAddress!
            var plainLen = 0
            let innerType: UInt8? = rdKey.withUnsafeBytes { kp in
                rdIV.withUnsafeBytes { ivp in
                    tlsRecordOpen(key: kp.baseAddress!, iv: ivp.baseAddress!, seq: usedSeq,
                                  body: body, bodyLen: bodyLen, out: pt, outLen: &plainLen)
                }
            }
            guard let t = innerType else { return }
            ok = dispatchInner(type: t, data: pt, len: plainLen)
        }
        // Advance the record sequence within the current key epoch — but if
        // dispatch installed new read keys (server Finished → application keys
        // resets rdSeq to 0, RFC 8446 §5.3), leave that fresh counter alone.
        if rdSeq == usedSeq { rdSeq = usedSeq &+ 1 }
        if !ok && lastError == 0 { lastError = 112 }
        return ok
    }

    /// Handle the decrypted inner plaintext by its real content type.
    private func dispatchInner(type: UInt8, data: UnsafeRawPointer, len: Int) -> Bool {
        if type == ctApplicationData {
            for i in 0..<len { appbuf.append(tb(data, i)) }
            return true
        }
        if type == ctAlert { lastError = 113; return false }
        if type != ctHandshake { lastError = 114; return false }
        // Walk one or more handshake messages in this plaintext.
        var off = 0
        while off + 4 <= len {
            let mtype = tb(data, off)
            let mlen = (Int(tb(data, off + 1)) << 16) | (Int(tb(data, off + 2)) << 8) | Int(tb(data, off + 3))
            if off + 4 + mlen > len { lastError = 115; return false }
            let msg = data.advanced(by: off)
            let msgLen = 4 + mlen
            if !handleHandshakeMessage(type: mtype, full: msg, fullLen: msgLen) { return false }
            off += msgLen
        }
        return true
    }

    private func handleHandshakeMessage(type: UInt8, full: UnsafeRawPointer, fullLen: Int) -> Bool {
        switch type {
        case hsNewSessionTicket:
            // Post-handshake message (RFC 8446 §4.6.1). We do not do session
            // resumption, so ignore it. It arrives *after* the handshake (under
            // application keys) and is NOT part of the handshake transcript, so
            // we must not fold it in.
            _ = full; _ = fullLen
            return true
        case hsEncryptedExtensions:
            // Folded into the transcript so the server Finished verifies.
            transcriptAppend(full, fullLen)
            return true
        case hsCertificate:
            transcriptAppend(full, fullLen)
            if verifyEnabled && !parseCertificateMessage(full: full, fullLen: fullLen) {
                lastError = 120; return false
            }
            return true
        case hsCertificateVerify:
            // The signed content uses Hash(CH..Certificate), i.e. the transcript
            // BEFORE CertificateVerify is folded in — so verify, then append.
            if verifyEnabled && !verifyCertificateVerify(full: full, fullLen: fullLen) {
                return false   // verifyCertificateVerify set lastError
            }
            transcriptAppend(full, fullLen)
            return true
        case hsFinished:
            // Verify server Finished = HMAC(finished_key, Hash(transcript so far)),
            // where finished_key = Expand-Label(server_hs_traffic, "finished", "").
            var thBefore = [UInt8](repeating: 0, count: 32)
            thBefore.withUnsafeMutableBytes { transcriptHash($0.baseAddress!) }
            var finishedKey = [UInt8](repeating: 0, count: 32)
            let fl: [UInt8] = Array("finished".utf8)
            serverHsTraffic.withUnsafeBytes { s in
                fl.withUnsafeBytes { l in
                    finishedKey.withUnsafeMutableBytes { o in
                        hkdfExpandLabel(secret: s.baseAddress!, label: l.baseAddress!, labelLen: fl.count,
                                        context: l.baseAddress!, contextLen: 0,
                                        out: o.baseAddress!, outLen: hashLen)
                    }
                }
            }
            var expected = [UInt8](repeating: 0, count: 32)
            finishedKey.withUnsafeBytes { fk in
                thBefore.withUnsafeBytes { th in
                    expected.withUnsafeMutableBytes { o in
                        hmacSha256(fk.baseAddress!, hashLen, th.baseAddress!, hashLen, o.baseAddress!)
                    }
                }
            }
            // full = [hsFinished, len(3), verify_data(32)].
            if fullLen != 4 + hashLen { lastError = 116; return false }
            var diff: UInt8 = 0
            for i in 0..<hashLen { diff |= tb(full, 4 + i) ^ expected[i] }
            if diff != 0 { lastError = 117; return false }
            // Server Finished is now part of the transcript for the master secret
            // and the client Finished.
            transcriptAppend(full, fullLen)
            return finishHandshake()
        default:
            lastError = 118
            return false
        }
    }

    /// Parse a TLS 1.3 Certificate message (RFC 8446 §4.4.2) into the leaf and
    /// intermediate X.509 certs. `full` includes the 4-byte handshake header.
    private func parseCertificateMessage(full: UnsafeRawPointer, fullLen: Int) -> Bool {
        var p = [UInt8](); p.reserveCapacity(fullLen)
        for i in 0..<fullLen { p.append(tb(full, i)) }
        var idx = 4                                   // skip handshake header
        if idx >= p.count { return false }
        let ctxLen = Int(p[idx]); idx += 1 + ctxLen   // certificate_request_context
        if idx + 3 > p.count { return false }
        let listLen = (Int(p[idx]) << 16) | (Int(p[idx + 1]) << 8) | Int(p[idx + 2]); idx += 3
        let listEnd = idx + listLen
        if listEnd > p.count { return false }
        var certs: [X509Cert] = []
        while idx + 3 <= listEnd {
            let clen = (Int(p[idx]) << 16) | (Int(p[idx + 1]) << 8) | Int(p[idx + 2]); idx += 3
            if idx + clen > listEnd { return false }
            let der = Array(p[idx..<idx + clen]); idx += clen
            if idx + 2 > listEnd { return false }
            let extLen = (Int(p[idx]) << 8) | Int(p[idx + 1]); idx += 2 + extLen
            guard let c = parseX509(der) else { return false }
            certs.append(c)
        }
        if certs.isEmpty { return false }
        chainLeaf = certs[0]
        chainInters = Array(certs[1...])
        return true
    }

    /// Verify the server CertificateVerify (RFC 8446 §4.4.3) signature over the
    /// CH..Certificate transcript with the leaf key (ECDSA-P256 only), then run
    /// the full chain/host/date validation. Sets lastError and returns false on
    /// any failure.
    private func verifyCertificateVerify(full: UnsafeRawPointer, fullLen: Int) -> Bool {
        guard let leaf = chainLeaf else { lastError = 121; return false }
        if fullLen < 8 { lastError = 122; return false }
        let scheme = (Int(tb(full, 4)) << 8) | Int(tb(full, 5))
        let sigLen = (Int(tb(full, 6)) << 8) | Int(tb(full, 7))
        if 8 + sigLen > fullLen { lastError = 123; return false }
        var sig = [UInt8](); sig.reserveCapacity(sigLen)
        for i in 0..<sigLen { sig.append(tb(full, 8 + i)) }

        var th = [UInt8](repeating: 0, count: 32)
        th.withUnsafeMutableBytes { transcriptHash($0.baseAddress!) }   // Hash(CH..Certificate)

        // signed content = 0x20*64 ‖ "TLS 1.3, server CertificateVerify" ‖ 0x00 ‖ th
        var content = [UInt8](repeating: 0x20, count: 64)
        content += Array("TLS 1.3, server CertificateVerify".utf8)
        content.append(0x00)
        content += th
        var h = [UInt8](repeating: 0, count: 32)
        content.withUnsafeBytes { cp in
            h.withUnsafeMutableBytes { hp in sha256(cp.baseAddress!, content.count, hp.baseAddress!) }
        }

        if scheme != 0x0403 { lastError = 124; return false }   // ecdsa_secp256r1_sha256 only
        if !ecdsaP256VerifyDER(point65: leaf.spkiKey, hash32: h, derSig: sig) { lastError = 125; return false }

        if !x509VerifyChain(leaf: leaf, intermediates: chainInters, roots: trustRoots,
                            hostname: expectHostname, now: verifyNow) { lastError = 126; return false }
        return true
    }

    /// After verifying the server Finished: derive the master secret + app traffic
    /// secrets, send (encrypted, under handshake keys) the client Finished, then
    /// switch to application keys.
    private func finishHandshake() -> Bool {
        // master_secret = HKDF-Extract(Derive-Secret(handshake_secret,"derived",""), 0).
        var emptyHash = [UInt8](repeating: 0, count: 32)
        emptyHash.withUnsafeMutableBytes { sha256($0.baseAddress!, 0, $0.baseAddress!) }
        var derived = [UInt8](repeating: 0, count: 32)
        let dl: [UInt8] = Array("derived".utf8)
        handshakeSecret.withUnsafeBytes { hsk in
            dl.withUnsafeBytes { l in
                emptyHash.withUnsafeBytes { eh in
                    derived.withUnsafeMutableBytes { o in
                        hkdfExpandLabel(secret: hsk.baseAddress!, label: l.baseAddress!, labelLen: dl.count,
                                        context: eh.baseAddress!, contextLen: hashLen,
                                        out: o.baseAddress!, outLen: hashLen)
                    }
                }
            }
        }
        let zeros = [UInt8](repeating: 0, count: 32)
        derived.withUnsafeBytes { d in
            zeros.withUnsafeBytes { z in
                masterSecret.withUnsafeMutableBytes { ms in
                    hkdfExtract(salt: d.baseAddress!, saltLen: 32, ikm: z.baseAddress!, ikmLen: 32,
                                prkOut: ms.baseAddress!)
                }
            }
        }
        // App traffic secrets use Hash(CH..server Finished) (the current transcript).
        var th = [UInt8](repeating: 0, count: 32)
        th.withUnsafeMutableBytes { transcriptHash($0.baseAddress!) }
        deriveLabeled(secret: masterSecret, label: "c ap traffic", th: th, out: &clientAppTraffic)
        deriveLabeled(secret: masterSecret, label: "s ap traffic", th: th, out: &serverAppTraffic)

        // Client Finished = HMAC(client_finished_key, Hash(transcript incl. server
        // Finished)), sent encrypted under the *handshake* write key.
        var finishedKey = [UInt8](repeating: 0, count: 32)
        let fl: [UInt8] = Array("finished".utf8)
        clientHsTraffic.withUnsafeBytes { s in
            fl.withUnsafeBytes { l in
                finishedKey.withUnsafeMutableBytes { o in
                    hkdfExpandLabel(secret: s.baseAddress!, label: l.baseAddress!, labelLen: fl.count,
                                    context: l.baseAddress!, contextLen: 0, out: o.baseAddress!, outLen: hashLen)
                }
            }
        }
        var verify = [UInt8](repeating: 0, count: 32)
        finishedKey.withUnsafeBytes { fk in
            th.withUnsafeBytes { t in
                verify.withUnsafeMutableBytes { o in
                    hmacSha256(fk.baseAddress!, hashLen, t.baseAddress!, hashLen, o.baseAddress!)
                }
            }
        }
        var finMsg = [UInt8]()
        finMsg.append(hsFinished)
        finMsg.append(0); finMsg.append(0); finMsg.append(UInt8(hashLen))
        finMsg.append(contentsOf: verify)
        finMsg.withUnsafeBytes { emitEncrypted(contentType: ctHandshake, plaintext: $0.baseAddress!, plen: $0.count) }

        // Switch to application traffic keys for both directions.
        installKeys(readSecret: serverAppTraffic, writeSecret: clientAppTraffic)
        phase = .established
        return true
    }
}
