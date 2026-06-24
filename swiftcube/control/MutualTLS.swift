// SPDX-License-Identifier: Apache-2.0
// MutualTLS.swift — a sans-IO TLS 1.3 engine with mutual cert auth (SC2).
//
// The swift-os TLS stack (userland/lib/tls13.swift) is client-only and never
// authenticates the client; SC2's control plane needs both roles AND mutual
// authentication. This engine adds the TLS 1.3 *server* role and *client
// certificate* auth, built entirely by composing the existing primitives — it
// introduces NO new crypto:
//   - record layer:   tlsRecordSeal / tlsRecordOpen / tlsRecordNonce (tls13.swift)
//   - key schedule:   hkdfExpandLabel (tls13.swift) + hkdfExtract (sha256.swift)
//   - key exchange:   x25519 (kernel/crypto)
//   - AEAD/hash/mac:  ChaCha20-Poly1305, SHA-256, HMAC (kernel/crypto)
//   - signatures:     ECDSA-P256 sign/verify (p256.swift), DER via asn1/x509
//   - cert validation: parseX509 + x509VerifyChain + verifyClientIdentity (Identity.swift)
//
// Single, opinionated suite (matching the rest of the stack): X25519 key share,
// TLS_CHACHA20_POLY1305_SHA256, SHA-256, ecdsa_secp256r1_sha256 signatures. Full
// handshake only (no PSK/resumption/0-RTT/HRR). Both endpoints here are SwiftCube
// peers (sctld ⇄ slet), so the engine only needs to interoperate with itself; it
// follows RFC 8446 message order so the transcript and key schedule are correct.
//
// Sans-IO: the caller pumps bytes with feedTLS/takeTLS and drains app data with
// receiveAppData, identical to the existing client, so the same source runs in the
// host control-test and in the sctld/slet userland services. Foundation-free.

// MARK: - Local constants (the tls13.swift copies are private)

private let mRecordHeaderLen = 5
private let mHashLen = 32
private let mKeyLen = 32
private let mIVLen = 12
private let mTagLen = 16

private let mCTChangeCipherSpec: UInt8 = 20
private let mCTAlert: UInt8 = 21
private let mCTHandshake: UInt8 = 22
private let mCTAppData: UInt8 = 23

private let hsClientHello: UInt8 = 1
private let hsServerHello: UInt8 = 2
private let hsEncryptedExtensions: UInt8 = 8
private let hsCertificate: UInt8 = 11
private let hsCertificateRequest: UInt8 = 13
private let hsCertificateVerify: UInt8 = 15
private let hsFinished: UInt8 = 20

private let sigSchemeEcdsaP256: Int = 0x0403   // ecdsa_secp256r1_sha256

// MARK: - Configuration

/// Our own certificate chain (leaf DER first, then any intermediates) plus the
/// leaf's P-256 private scalar (32B). Presented to the peer and used to sign the
/// CertificateVerify.
struct TLSIdentity {
    var certChain: [[UInt8]]    // [leafDER, interDER, ...]
    var privateKey: [UInt8]     // 32-byte big-endian P-256 scalar of the leaf
}

/// TLS engine configuration. `caRoots` are the trust anchors used to verify the
/// peer's certificate. A client also checks the server leaf's SAN against
/// `verifyHostname`; a server reads the client leaf's SAN as the node identity.
/// `now` is YYYYMMDDHHMMSS for validity checks (from the injected clock).
struct TLSConfig {
    var identity: TLSIdentity
    var caRoots: [X509Cert]
    var verifyHostname: String      // client: expected server SAN; server: unused
    var now: UInt64
    var requireClientCert: Bool     // server: reject a handshake with no client cert

    init(identity: TLSIdentity, caRoots: [X509Cert], verifyHostname: String = "",
         now: UInt64, requireClientCert: Bool = true) {
        self.identity = identity; self.caRoots = caRoots
        self.verifyHostname = verifyHostname; self.now = now
        self.requireClientCert = requireClientCert
    }
}

enum TLSRole { case client, server }

/// Mirrors tls13.swift's TLSProgress so callers can share a pump loop.
enum MTLSProgress { case needMoreData, handshakeComplete, failed }

// MARK: - Engine

final class MutualTLS {
    let role: TLSRole
    private let cfg: TLSConfig
    private let rng: (inout [UInt8]) -> Void

    // X25519 ephemeral key pair for the key share.
    private var ephSecret = [UInt8](repeating: 0, count: 32)
    private var ephPublic = [UInt8](repeating: 0, count: 32)
    private var peerPublic = [UInt8](repeating: 0, count: 32)

    // Running handshake transcript (raw concatenated handshake messages).
    private var transcript = [UInt8]()

    // Stream buffers.
    private var inbuf = [UInt8]()
    private var outbuf = [UInt8]()
    private var appbuf = [UInt8]()

    // Key schedule secrets.
    private var handshakeSecret = [UInt8](repeating: 0, count: 32)
    private var masterSecret = [UInt8](repeating: 0, count: 32)
    private var cHsTraffic = [UInt8](repeating: 0, count: 32)
    private var sHsTraffic = [UInt8](repeating: 0, count: 32)
    private var cApTraffic = [UInt8](repeating: 0, count: 32)
    private var sApTraffic = [UInt8](repeating: 0, count: 32)

    // Active record keys.
    private var rdKey = [UInt8](repeating: 0, count: mKeyLen)
    private var rdIV  = [UInt8](repeating: 0, count: mIVLen)
    private var rdSeq: UInt64 = 0
    private var wrKey = [UInt8](repeating: 0, count: mKeyLen)
    private var wrIV  = [UInt8](repeating: 0, count: mIVLen)
    private var wrSeq: UInt64 = 0
    private var encryptingOut = false       // outbound records encrypted yet?
    private var encryptingIn = false        // inbound records expected encrypted?
    private var rdKeyChanged = false        // set by installReadKey during dispatch

    private enum Phase {
        case start
        case clientSentHello          // client: waiting for ServerHello
        case serverSentHello          // server: sent flight, awaiting client flight
        case clientGotServerFlight    // (transient)
        case established
        case dead
    }
    private var phase: Phase = .start

    // The verified identity (SAN) of the peer's leaf, once authenticated.
    private(set) var peerIdentity: String? = nil
    private(set) var lastError: Int = 0

    // Server-side: did the client send a (non-empty) certificate?
    private var clientCertSeen = false
    private var pendingCertReqContext = [UInt8]()  // echoed in the client Certificate

    init(role: TLSRole, config: TLSConfig, _ rng: @escaping (inout [UInt8]) -> Void) {
        self.role = role; self.cfg = config; self.rng = rng
    }

    var handshakeComplete: Bool { phase == .established }

    // MARK: Sans-IO surface

    /// Begin the handshake. The client emits ClientHello; the server only sets up
    /// its ephemeral key and waits for the client.
    func start() {
        var sk = [UInt8](repeating: 0, count: 32); rng(&sk)
        for i in 0..<32 { ephSecret[i] = sk[i] }
        var basepoint = [UInt8](repeating: 0, count: 32); basepoint[0] = 9
        ephSecret.withUnsafeBytes { s in basepoint.withUnsafeBytes { b in
            ephPublic.withUnsafeMutableBytes { p in x25519(s.baseAddress!, b.baseAddress!, p.baseAddress!) } } }
        if role == .client {
            emitClientHello()
            phase = .clientSentHello
        }
    }

    func feedTLS(_ src: UnsafeRawPointer, _ n: Int) {
        for i in 0..<n { inbuf.append(src.load(fromByteOffset: i, as: UInt8.self)) }
    }
    func feedTLS(_ bytes: [UInt8]) { inbuf.append(contentsOf: bytes) }

    var pendingOut: Int { outbuf.count }
    func takeTLS() -> [UInt8] { let o = outbuf; outbuf.removeAll(keepingCapacity: true); return o }

    /// Drive the state machine over buffered inbound bytes.
    func advance() -> MTLSProgress {
        if phase == .dead { return .failed }
        while true {
            guard let (ct, recStart, recLen, consumed) = peekRecord() else {
                return phase == .established ? .handshakeComplete : .needMoreData
            }
            let body = Array(inbuf[(recStart) ..< (recStart + recLen)])
            inbuf.removeFirst(consumed)
            if ct == mCTChangeCipherSpec { continue }      // tolerate (we never send it)
            if !handleRecord(ct: ct, body: body) { phase = .dead; return .failed }
            if phase == .dead { return .failed }
        }
    }

    func sendAppData(_ src: UnsafeRawPointer, _ n: Int) {
        if phase != .established { return }
        var pt = [UInt8](repeating: 0, count: n)
        for i in 0..<n { pt[i] = src.load(fromByteOffset: i, as: UInt8.self) }
        emitEncrypted(contentType: mCTAppData, plaintext: pt)
    }
    func sendAppData(_ bytes: [UInt8]) {
        if phase != .established { return }
        emitEncrypted(contentType: mCTAppData, plaintext: bytes)
    }

    var pendingAppData: Int { appbuf.count }
    func receiveAppData() -> [UInt8] { let a = appbuf; appbuf.removeAll(keepingCapacity: true); return a }

    // MARK: Record framing

    /// Returns (contentType, fragmentStartIndex, fragmentLen, totalRecordBytes).
    private func peekRecord() -> (UInt8, Int, Int, Int)? {
        if inbuf.count < mRecordHeaderLen { return nil }
        let ct = inbuf[0]
        let len = Int(inbuf[3]) << 8 | Int(inbuf[4])
        if len > tlsMaxRecord { lastError = 101; return nil }
        if inbuf.count < mRecordHeaderLen + len { return nil }
        return (ct, mRecordHeaderLen, len, mRecordHeaderLen + len)
    }

    private func emitPlaintextRecord(contentType: UInt8, payload: [UInt8]) {
        outbuf.append(contentType)
        outbuf.append(0x03); outbuf.append(0x03)
        outbuf.append(UInt8((payload.count >> 8) & 0xFF))
        outbuf.append(UInt8(payload.count & 0xFF))
        outbuf.append(contentsOf: payload)
    }

    private func emitEncrypted(contentType: UInt8, plaintext: [UInt8]) {
        plaintext.withUnsafeBytes { pp in
            wrKey.withUnsafeBytes { kp in wrIV.withUnsafeBytes { ivp in
                tlsRecordSeal(key: kp.baseAddress!, iv: ivp.baseAddress!, seq: wrSeq,
                              contentType: contentType, plaintext: pp.baseAddress!, plen: plaintext.count,
                              out: &outbuf)
            } }
        }
        wrSeq &+= 1
    }

    // MARK: Inbound dispatch

    private func handleRecord(ct: UInt8, body: [UInt8]) -> Bool {
        if !encryptingIn {
            if ct != mCTHandshake { lastError = 102; return false }
            // First plaintext handshake record: ClientHello (server) or ServerHello (client).
            return handlePlaintextHandshake(body)
        }
        if ct == mCTAlert { lastError = 100; return false }
        if ct != mCTAppData { lastError = 103; return false }
        return handleEncryptedRecord(body)
    }

    private func handlePlaintextHandshake(_ body: [UInt8]) -> Bool {
        if role == .server {
            transcriptAppend(body)
            return handleClientHello(body)
        } else {
            transcriptAppend(body)
            return handleServerHello(body)
        }
    }

    private func handleEncryptedRecord(_ body: [UInt8]) -> Bool {
        if body.count < mTagLen { lastError = 111; return false }
        let usedSeq = rdSeq
        var plainLen = 0
        var out = [UInt8](repeating: 0, count: body.count)
        let innerType: UInt8? = body.withUnsafeBytes { bp in
            rdKey.withUnsafeBytes { kp in rdIV.withUnsafeBytes { ivp in
                out.withUnsafeMutableBytes { op in
                    tlsRecordOpen(key: kp.baseAddress!, iv: ivp.baseAddress!, seq: usedSeq,
                                  body: bp.baseAddress!, bodyLen: body.count,
                                  out: op.baseAddress!, outLen: &plainLen)
                }
            } }
        }
        guard let t = innerType else { lastError = 112; return false }
        let plain = Array(out[0..<plainLen])
        rdKeyChanged = false
        let ok = dispatchInner(type: t, data: plain)
        // Advance the record sequence within the current key epoch — unless dispatch
        // installed a new read key (epoch change resets seq to 0). Robust even when a
        // whole flight, ending in Finished, arrives coalesced in a single record.
        if !rdKeyChanged { rdSeq = usedSeq &+ 1 }
        return ok
    }

    private func dispatchInner(type: UInt8, data: [UInt8]) -> Bool {
        if type == mCTAppData { appbuf.append(contentsOf: data); return true }
        if type == mCTAlert { lastError = 113; return false }
        if type != mCTHandshake { lastError = 114; return false }
        var off = 0
        while off + 4 <= data.count {
            let mtype = data[off]
            let mlen = Int(data[off+1]) << 16 | Int(data[off+2]) << 8 | Int(data[off+3])
            if off + 4 + mlen > data.count { lastError = 115; return false }
            let full = Array(data[off ..< off + 4 + mlen])
            if !handleHandshakeMessage(type: mtype, full: full) { return false }
            off += 4 + mlen
        }
        return true
    }

    // MARK: Transcript

    private func transcriptAppend(_ msg: [UInt8]) { transcript.append(contentsOf: msg) }
    private func transcriptHash() -> [UInt8] {
        var h = [UInt8](repeating: 0, count: 32)
        transcript.withUnsafeBytes { tp in h.withUnsafeMutableBytes { hp in sha256(tp.baseAddress!, transcript.count, hp.baseAddress!) } }
        return h
    }

    // MARK: Handshake message builders (big-endian length helpers)

    private func wrapHandshake(_ type: UInt8, _ body: [UInt8]) -> [UInt8] {
        var m: [UInt8] = [type]
        m.append(UInt8((body.count >> 16) & 0xFF))
        m.append(UInt8((body.count >> 8) & 0xFF))
        m.append(UInt8(body.count & 0xFF))
        m.append(contentsOf: body)
        return m
    }

    private func emitClientHello() {
        var ch = [UInt8]()
        func u16(_ v: Int) { ch.append(UInt8((v >> 8) & 0xFF)); ch.append(UInt8(v & 0xFF)) }
        u16(0x0303)
        var random = [UInt8](repeating: 0, count: 32); rng(&random); ch.append(contentsOf: random)
        ch.append(0)                                  // empty session id
        u16(2); ch.append(0x13); ch.append(0x03)      // cipher_suites = {TLS_CHACHA20_POLY1305_SHA256}
        ch.append(1); ch.append(0)                    // compression = {null}
        var ext = [UInt8]()
        func e16(_ v: Int) { ext.append(UInt8((v >> 8) & 0xFF)); ext.append(UInt8(v & 0xFF)) }
        e16(43); e16(3); ext.append(2); e16(0x0304)                       // supported_versions
        e16(10); e16(4); e16(2); e16(0x001d)                             // supported_groups x25519
        e16(13); e16(4); e16(2); e16(sigSchemeEcdsaP256)                 // signature_algorithms
        e16(51); e16(2 + 2 + 2 + 32); e16(2 + 2 + 32); e16(0x001d); e16(32) // key_share x25519
        ext.append(contentsOf: ephPublic)
        u16(ext.count); ch.append(contentsOf: ext)
        let msg = wrapHandshake(hsClientHello, ch)
        transcriptAppend(msg)
        emitPlaintextRecord(contentType: mCTHandshake, payload: msg)
    }

    // MARK: Server side

    private func handleClientHello(_ msg: [UInt8]) -> Bool {
        // Extract the client's x25519 key_share. msg = type(1)+len(3)+body.
        guard msg.count > 4, msg[0] == hsClientHello else { lastError = 104; return false }
        var off = 4
        off += 2 + 32                                  // version + random
        guard off < msg.count else { lastError = 105; return false }
        let sidLen = Int(msg[off]); off += 1 + sidLen
        guard off + 2 <= msg.count else { lastError = 105; return false }
        let csLen = Int(msg[off]) << 8 | Int(msg[off+1]); off += 2 + csLen
        guard off + 1 <= msg.count else { lastError = 105; return false }
        let compLen = Int(msg[off]); off += 1 + compLen
        guard off + 2 <= msg.count else { lastError = 105; return false }
        let extLen = Int(msg[off]) << 8 | Int(msg[off+1]); off += 2
        let extEnd = off + extLen
        guard extEnd <= msg.count else { lastError = 105; return false }
        var found = false
        while off + 4 <= extEnd {
            let etype = Int(msg[off]) << 8 | Int(msg[off+1])
            let elen = Int(msg[off+2]) << 8 | Int(msg[off+3])
            let edata = off + 4
            guard edata + elen <= extEnd else { lastError = 106; return false }
            if etype == 51 {                            // key_share (client list)
                var p = edata
                let listLen = Int(msg[p]) << 8 | Int(msg[p+1]); p += 2
                let listEnd = p + listLen
                while p + 4 <= listEnd {
                    let group = Int(msg[p]) << 8 | Int(msg[p+1])
                    let klen = Int(msg[p+2]) << 8 | Int(msg[p+3])
                    if group == 0x001d && klen == 32 && p + 4 + 32 <= listEnd {
                        for i in 0..<32 { peerPublic[i] = msg[p + 4 + i] }
                        found = true
                    }
                    p += 4 + klen
                }
            }
            off = edata + elen
        }
        if !found { lastError = 110; return false }

        emitServerHello()
        deriveHandshakeKeys()                          // installs hs read/write keys
        emitServerFlight()                             // EE, CertReq, Cert, CertVerify, Finished
        // Transcript is now CH..server Finished: pin the app traffic secrets there
        // and switch the WRITE side to the server app key (0.5-RTT capable). The
        // READ side stays on c_hs until the client Finished authenticates the peer.
        deriveAppSecrets()
        installWriteKey(sApTraffic)
        phase = .serverSentHello
        return true
    }

    private func emitServerHello() {
        var sh = [UInt8]()
        func u16(_ v: Int) { sh.append(UInt8((v >> 8) & 0xFF)); sh.append(UInt8(v & 0xFF)) }
        u16(0x0303)
        var random = [UInt8](repeating: 0, count: 32); rng(&random); sh.append(contentsOf: random)
        sh.append(0)                                   // session id echo (empty)
        sh.append(0x13); sh.append(0x03)               // chosen cipher suite
        sh.append(0)                                   // compression
        var ext = [UInt8]()
        func e16(_ v: Int) { ext.append(UInt8((v >> 8) & 0xFF)); ext.append(UInt8(v & 0xFF)) }
        e16(43); e16(2); e16(0x0304)                   // supported_versions
        e16(51); e16(2 + 2 + 32); e16(0x001d); e16(32) // key_share x25519 server pub
        ext.append(contentsOf: ephPublic)
        u16(ext.count); sh.append(contentsOf: ext)
        let msg = wrapHandshake(hsServerHello, sh)
        transcriptAppend(msg)
        emitPlaintextRecord(contentType: mCTHandshake, payload: msg)
    }

    private func emitServerFlight() {
        var flight = [UInt8]()
        // EncryptedExtensions: empty.
        let ee = wrapHandshake(hsEncryptedExtensions, [0x00, 0x00])
        transcriptAppend(ee); flight.append(contentsOf: ee)
        // CertificateRequest: empty context + signature_algorithms extension.
        var cr = [UInt8]([0x00])                       // certificate_request_context<0..255> = empty
        var crExt = [UInt8]()
        func e16(_ v: Int) { crExt.append(UInt8((v >> 8) & 0xFF)); crExt.append(UInt8(v & 0xFF)) }
        e16(13); e16(4); e16(2); e16(sigSchemeEcdsaP256)
        cr.append(UInt8((crExt.count >> 8) & 0xFF)); cr.append(UInt8(crExt.count & 0xFF))
        cr.append(contentsOf: crExt)
        let crMsg = wrapHandshake(hsCertificateRequest, cr)
        transcriptAppend(crMsg); flight.append(contentsOf: crMsg)
        // Certificate (server chain).
        let certMsg = buildCertificateMessage(context: [], chain: cfg.identity.certChain)
        transcriptAppend(certMsg); flight.append(contentsOf: certMsg)
        // CertificateVerify (server context string).
        guard let cv = buildCertificateVerify(contextString: "TLS 1.3, server CertificateVerify") else {
            lastError = 130; return
        }
        transcriptAppend(cv); flight.append(contentsOf: cv)
        // Finished (over transcript through CertVerify), with the server hs secret.
        let fin = buildFinished(baseSecret: sHsTraffic)
        transcriptAppend(fin); flight.append(contentsOf: fin)
        emitEncrypted(contentType: mCTHandshake, plaintext: flight)
    }

    // MARK: Client side

    private func handleServerHello(_ msg: [UInt8]) -> Bool {
        guard msg.count >= 4, msg[0] == hsServerHello else { lastError = 104; return false }
        var off = 4
        off += 2 + 32
        guard off < msg.count else { lastError = 105; return false }
        let sidLen = Int(msg[off]); off += 1 + sidLen
        off += 2 + 1                                   // cipher suite + compression
        guard off + 2 <= msg.count else { lastError = 105; return false }
        let extLen = Int(msg[off]) << 8 | Int(msg[off+1]); off += 2
        let extEnd = off + extLen
        guard extEnd <= msg.count else { lastError = 105; return false }
        var found = false
        while off + 4 <= extEnd {
            let etype = Int(msg[off]) << 8 | Int(msg[off+1])
            let elen = Int(msg[off+2]) << 8 | Int(msg[off+3])
            let edata = off + 4
            guard edata + elen <= extEnd else { lastError = 106; return false }
            if etype == 51 {
                if elen >= 4 {
                    let group = Int(msg[edata]) << 8 | Int(msg[edata+1])
                    let klen = Int(msg[edata+2]) << 8 | Int(msg[edata+3])
                    if group == 0x001d && klen == 32 && edata + 4 + 32 <= extEnd {
                        for i in 0..<32 { peerPublic[i] = msg[edata + 4 + i] }
                        found = true
                    }
                }
            }
            off = edata + elen
        }
        if !found { lastError = 110; return false }
        deriveHandshakeKeys()
        phase = .clientGotServerFlight
        return true
    }

    // MARK: Handshake message handlers (encrypted)

    private var seenCertReq = false
    private var peerChain: [[UInt8]] = []

    private func handleHandshakeMessage(type: UInt8, full: [UInt8]) -> Bool {
        switch type {
        case hsEncryptedExtensions:
            transcriptAppend(full); return true
        case hsCertificateRequest:
            // Client only. Capture the request context to echo it back.
            transcriptAppend(full)
            if full.count >= 5 {
                let ctxLen = Int(full[4])
                if 5 + ctxLen <= full.count { pendingCertReqContext = Array(full[5 ..< 5 + ctxLen]) }
            }
            seenCertReq = true
            return true
        case hsCertificate:
            // Parse the peer chain; fold into transcript regardless of role.
            transcriptAppend(full)
            return parseCertificateMessage(full)
        case hsCertificateVerify:
            // Verify the peer's signature over the transcript BEFORE folding CV in.
            let okSig = verifyCertificateVerify(full: full,
                contextString: role == .client ? "TLS 1.3, server CertificateVerify"
                                                : "TLS 1.3, client CertificateVerify")
            if !okSig { return false }
            transcriptAppend(full)
            return true
        case hsFinished:
            return handlePeerFinished(full)
        default:
            lastError = 118; return false
        }
    }

    private func handlePeerFinished(_ full: [UInt8]) -> Bool {
        // Peer Finished = HMAC(finished_key(peer hs secret), Hash(transcript so far)).
        let peerSecret = role == .client ? sHsTraffic : cHsTraffic
        let expected = finishedVerifyData(baseSecret: peerSecret, transcriptHash: transcriptHash())
        if full.count != 4 + mHashLen { lastError = 116; return false }
        var diff: UInt8 = 0
        for i in 0..<mHashLen { diff |= full[4 + i] ^ expected[i] }
        if diff != 0 { lastError = 117; return false }
        transcriptAppend(full)

        if role == .client {
            // Verify the server's identity now (chain + host + dates).
            if !verifyServerIdentity() { lastError = 126; return false }
            // Derive app secrets at CH..server Finished.
            deriveAppSecrets()
            // Send the client's second flight (Cert + CertVerify + Finished) under c_hs.
            emitClientFlight()
            // Switch both directions to application keys.
            installWriteKey(cApTraffic)
            installReadKey(sApTraffic)
            phase = .established
            return true
        } else {
            // Server has now received the client Finished → authenticate the client.
            if cfg.requireClientCert && !clientCertSeen { lastError = 140; return false }
            if clientCertSeen {
                guard let id = verifyClientIdentity(leafDER: peerChain.first ?? [],
                                                    intermediatesDER: Array(peerChain.dropFirst()),
                                                    roots: cfg.caRoots, now: cfg.now) else {
                    lastError = 141; return false
                }
                peerIdentity = id
            }
            // Switch read to client app key (write already on s_ap).
            installReadKey(cApTraffic)
            phase = .established
            return true
        }
    }

    /// The server's app traffic secrets are pinned at CH..server Finished, which on
    /// the server is exactly when it emitted its flight — but the server needs them
    /// for the WRITE key it installed there. We derive them at emit time instead;
    /// on the client we derive here. Kept as one helper.
    private func deriveAppSecrets() {
        // master_secret = HKDF-Extract(Derive-Secret(hs,"derived",""), 0).
        let emptyHash = sha256Empty()
        let derived = expandLabel(secret: handshakeSecret, label: "derived", context: emptyHash, len: 32)
        masterSecret = hkdfExtract32(salt: derived, ikm: [UInt8](repeating: 0, count: 32))
        let th = transcriptHash()                      // CH..server Finished
        cApTraffic = expandLabel(secret: masterSecret, label: "c ap traffic", context: th, len: 32)
        sApTraffic = expandLabel(secret: masterSecret, label: "s ap traffic", context: th, len: 32)
    }

    private func emitClientFlight() {
        var flight = [UInt8]()
        let certMsg = buildCertificateMessage(context: pendingCertReqContext, chain: cfg.identity.certChain)
        transcriptAppend(certMsg); flight.append(contentsOf: certMsg)
        // A client with a cert proves possession with CertificateVerify; a client
        // with no cert sends only the empty Certificate (RFC 8446 §4.4.2) and lets
        // the server's requireClientCert gate reject it.
        if !cfg.identity.certChain.isEmpty,
           let cv = buildCertificateVerify(contextString: "TLS 1.3, client CertificateVerify") {
            transcriptAppend(cv); flight.append(contentsOf: cv)
        }
        let fin = buildFinished(baseSecret: cHsTraffic)
        transcriptAppend(fin); flight.append(contentsOf: fin)
        emitEncrypted(contentType: mCTHandshake, plaintext: flight)
    }

    // MARK: Certificate message build/parse

    private func buildCertificateMessage(context: [UInt8], chain: [[UInt8]]) -> [UInt8] {
        var body = [UInt8]()
        body.append(UInt8(context.count)); body.append(contentsOf: context)   // context<0..255>
        var list = [UInt8]()
        for der in chain {
            list.append(UInt8((der.count >> 16) & 0xFF)); list.append(UInt8((der.count >> 8) & 0xFF)); list.append(UInt8(der.count & 0xFF))
            list.append(contentsOf: der)
            list.append(0); list.append(0)                                     // extensions<0..2^16> empty
        }
        body.append(UInt8((list.count >> 16) & 0xFF)); body.append(UInt8((list.count >> 8) & 0xFF)); body.append(UInt8(list.count & 0xFF))
        body.append(contentsOf: list)
        return wrapHandshake(hsCertificate, body)
    }

    private func parseCertificateMessage(_ full: [UInt8]) -> Bool {
        var idx = 4
        guard idx < full.count else { lastError = 120; return false }
        let ctxLen = Int(full[idx]); idx += 1 + ctxLen
        guard idx + 3 <= full.count else { lastError = 120; return false }
        let listLen = Int(full[idx]) << 16 | Int(full[idx+1]) << 8 | Int(full[idx+2]); idx += 3
        let listEnd = idx + listLen
        guard listEnd <= full.count else { lastError = 120; return false }
        var chain: [[UInt8]] = []
        while idx + 3 <= listEnd {
            let clen = Int(full[idx]) << 16 | Int(full[idx+1]) << 8 | Int(full[idx+2]); idx += 3
            guard idx + clen <= listEnd else { lastError = 120; return false }
            chain.append(Array(full[idx ..< idx + clen])); idx += clen
            guard idx + 2 <= listEnd else { lastError = 120; return false }
            let extLen = Int(full[idx]) << 8 | Int(full[idx+1]); idx += 2 + extLen
        }
        peerChain = chain
        if role == .server { clientCertSeen = !chain.isEmpty }
        return true
    }

    // MARK: CertificateVerify build/verify

    private func buildCertificateVerify(contextString: String) -> [UInt8]? {
        let th = transcriptHash()
        let signed = certVerifyContent(contextString: contextString, transcriptHash: th)
        var h = [UInt8](repeating: 0, count: 32)
        signed.withUnsafeBytes { sp in h.withUnsafeMutableBytes { hp in sha256(sp.baseAddress!, signed.count, hp.baseAddress!) } }
        var r = [UInt8](repeating: 0, count: 32)
        var s = [UInt8](repeating: 0, count: 32)
        var ok = false
        cfg.identity.privateKey.withUnsafeBytes { dp in h.withUnsafeBytes { hp in
            r.withUnsafeMutableBytes { rp in s.withUnsafeMutableBytes { sp in
                ok = p256SignDeterministic(dp.baseAddress!, hp.baseAddress!, rp.baseAddress!, sp.baseAddress!)
            } } } }
        if !ok { return nil }
        let derSig = ecdsaSigValueDER(r, s)
        var body = [UInt8]()
        body.append(UInt8((sigSchemeEcdsaP256 >> 8) & 0xFF)); body.append(UInt8(sigSchemeEcdsaP256 & 0xFF))
        body.append(UInt8((derSig.count >> 8) & 0xFF)); body.append(UInt8(derSig.count & 0xFF))
        body.append(contentsOf: derSig)
        return wrapHandshake(hsCertificateVerify, body)
    }

    private func verifyCertificateVerify(full: [UInt8], contextString: String) -> Bool {
        guard let leaf = peerChain.first.flatMap({ parseX509($0) }) else { lastError = 121; return false }
        if full.count < 8 { lastError = 122; return false }
        let scheme = Int(full[4]) << 8 | Int(full[5])
        let sigLen = Int(full[6]) << 8 | Int(full[7])
        if 8 + sigLen > full.count { lastError = 123; return false }
        if scheme != sigSchemeEcdsaP256 { lastError = 124; return false }
        let sig = Array(full[8 ..< 8 + sigLen])
        let signed = certVerifyContent(contextString: contextString, transcriptHash: transcriptHash())
        var h = [UInt8](repeating: 0, count: 32)
        signed.withUnsafeBytes { sp in h.withUnsafeMutableBytes { hp in sha256(sp.baseAddress!, signed.count, hp.baseAddress!) } }
        if !ecdsaP256VerifyDER(point65: leaf.spkiKey, hash32: h, derSig: sig) { lastError = 125; return false }
        return true
    }

    private func certVerifyContent(contextString: String, transcriptHash th: [UInt8]) -> [UInt8] {
        var c = [UInt8](repeating: 0x20, count: 64)
        c.append(contentsOf: Array(contextString.utf8))
        c.append(0x00)
        c.append(contentsOf: th)
        return c
    }

    // MARK: Identity verification

    private func verifyServerIdentity() -> Bool {
        guard let leaf = peerChain.first.flatMap({ parseX509($0) }) else { return false }
        var inters: [X509Cert] = []
        for d in peerChain.dropFirst() { if let c = parseX509(d) { inters.append(c) } }
        if !x509VerifyChain(leaf: leaf, intermediates: inters, roots: cfg.caRoots,
                            hostname: cfg.verifyHostname, now: cfg.now) { return false }
        peerIdentity = leaf.dnsNames.first
        return true
    }

    // MARK: Finished

    private func buildFinished(baseSecret: [UInt8]) -> [UInt8] {
        let vd = finishedVerifyData(baseSecret: baseSecret, transcriptHash: transcriptHash())
        return wrapHandshake(hsFinished, vd)
    }

    private func finishedVerifyData(baseSecret: [UInt8], transcriptHash th: [UInt8]) -> [UInt8] {
        let finishedKey = expandLabel(secret: baseSecret, label: "finished", context: [], len: 32)
        var out = [UInt8](repeating: 0, count: 32)
        finishedKey.withUnsafeBytes { fk in th.withUnsafeBytes { t in
            out.withUnsafeMutableBytes { o in hmacSha256(fk.baseAddress!, 32, t.baseAddress!, 32, o.baseAddress!) } } }
        return out
    }

    // MARK: Key schedule

    private func deriveHandshakeKeys() {
        // shared = X25519(ephSecret, peerPublic).
        var shared = [UInt8](repeating: 0, count: 32)
        ephSecret.withUnsafeBytes { sk in peerPublic.withUnsafeBytes { pk in
            shared.withUnsafeMutableBytes { o in x25519(sk.baseAddress!, pk.baseAddress!, o.baseAddress!) } } }
        let zeros = [UInt8](repeating: 0, count: 32)
        let earlySecret = hkdfExtract32(salt: zeros, ikm: zeros)
        let derived = expandLabel(secret: earlySecret, label: "derived", context: sha256Empty(), len: 32)
        handshakeSecret = hkdfExtract32(salt: derived, ikm: shared)
        let th = transcriptHash()                       // CH..SH
        cHsTraffic = expandLabel(secret: handshakeSecret, label: "c hs traffic", context: th, len: 32)
        sHsTraffic = expandLabel(secret: handshakeSecret, label: "s hs traffic", context: th, len: 32)
        if role == .client { installReadKey(sHsTraffic); installWriteKey(cHsTraffic) }
        else                { installReadKey(cHsTraffic); installWriteKey(sHsTraffic) }
        encryptingIn = true; encryptingOut = true
    }

    private func installReadKey(_ secret: [UInt8]) {
        rdKey = expandLabel(secret: secret, label: "key", context: [], len: mKeyLen)
        rdIV  = expandLabel(secret: secret, label: "iv",  context: [], len: mIVLen)
        rdSeq = 0
        rdKeyChanged = true
    }
    private func installWriteKey(_ secret: [UInt8]) {
        wrKey = expandLabel(secret: secret, label: "key", context: [], len: mKeyLen)
        wrIV  = expandLabel(secret: secret, label: "iv",  context: [], len: mIVLen)
        wrSeq = 0
    }

    // MARK: HKDF helpers (thin wrappers over the shared primitives)

    private func hkdfExtract32(salt: [UInt8], ikm: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        salt.withUnsafeBytes { s in ikm.withUnsafeBytes { k in
            out.withUnsafeMutableBytes { o in
                hkdfExtract(salt: s.baseAddress!, saltLen: salt.count, ikm: k.baseAddress!, ikmLen: ikm.count, prkOut: o.baseAddress!)
            } } }
        return out
    }

    private func expandLabel(secret: [UInt8], label: String, context: [UInt8], len: Int) -> [UInt8] {
        let lbl = Array(label.utf8)
        // A non-empty context needs a real pointer; for an empty context the pointer
        // is unused (contextLen 0) so any valid base address works.
        let ctx: [UInt8] = context.isEmpty ? [0] : context
        var out = [UInt8](repeating: 0, count: len)
        secret.withUnsafeBytes { s in lbl.withUnsafeBytes { l in ctx.withUnsafeBytes { c in
            out.withUnsafeMutableBytes { o in
                hkdfExpandLabel(secret: s.baseAddress!, label: l.baseAddress!, labelLen: lbl.count,
                                context: c.baseAddress!, contextLen: context.count,
                                out: o.baseAddress!, outLen: len)
            }
        } } }
        return out
    }

    private func sha256Empty() -> [UInt8] {
        var h = [UInt8](repeating: 0, count: 32)
        h.withUnsafeMutableBytes { hp in sha256(hp.baseAddress!, 0, hp.baseAddress!) }
        return h
    }
}
