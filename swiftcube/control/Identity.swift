// SPDX-License-Identifier: Apache-2.0
// Identity.swift — SwiftCube node identity & the controller CA (SC2).
//
// All control traffic is mTLS under a single controller CA. This file is the
// identity half: a local CA that issues short-lived bootstrap-free, long-lived
// node certificates by building an X.509 v3 TBSCertificate (DER) and signing it
// with ECDSA-P256 (RFC 6979 deterministic), reusing the existing primitives —
// the asn1.swift DER *writer* (SPKI, ECDSA-Sig-Value, INTEGER/SEQUENCE),
// kernel/crypto/p256.swift (sign/verify/derive), and kernel/crypto/sha256.swift.
// Nothing here is new crypto: it is DER encoding around the existing P-256 stack,
// chosen because that is exactly what x509_verify.swift's chain check and the TLS
// CertificateVerify path already accept (ecdsa-with-SHA256 leaves).
//
// Foundation-free and Embedded-compatible: heap byte arrays + Unsafe* into the
// crypto modules, no stdlib beyond Array/String. The same source compiles for the
// host control-test and into the sctld/slet userland ELFs.
//
// Scheme actually used (recorded for FORMAT.md):
//   - keys:      EC P-256, SEC1 raw scalar (32B BE) + uncompressed point (65B).
//   - signature: ecdsa-with-SHA256 (1.2.840.10045.4.3.2) over SHA-256(TBS).
//   - subject:   one RDN, commonName = the identity string (node id / "controller").
//   - identity:  carried in subjectAltName dNSName (so x509VerifyChain SAN logic
//                and hostnameMatchesSAN apply unchanged for the server cert; the
//                controller reads the node id from the client cert's SAN).
//   - CA cert:   self-signed, basicConstraints cA=TRUE (critical); leaves omit it.

// MARK: - OID bodies (post tag/length)

private let OID_ECDSA_SHA256: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02] // 1.2.840.10045.4.3.2
private let OID_COMMON_NAME: [UInt8]  = [0x55, 0x04, 0x03]                                // 2.5.4.3
private let OID_BASIC_CONSTRAINTS: [UInt8] = [0x55, 0x1D, 0x13]                           // 2.5.29.19
private let OID_SAN_ID: [UInt8] = [0x55, 0x1D, 0x11]                                      // 2.5.29.17

/// AlgorithmIdentifier for ecdsa-with-SHA256 (no parameters).
private func algEcdsaSha256() -> [UInt8] { derSequence([derOID(OID_ECDSA_SHA256)]) }

// MARK: - EC P-256 key pair

/// An EC P-256 key pair: the 32-byte big-endian private scalar plus its affine
/// public point (X‖Y, 32 bytes each). `point65` is the uncompressed SEC1 form.
struct ECKeyPair {
    var priv: [UInt8]    // 32 bytes, big-endian scalar
    var pubX: [UInt8]    // 32 bytes
    var pubY: [UInt8]    // 32 bytes

    var point65: [UInt8] { [0x04] + pubX + pubY }
    var spki: [UInt8] { spkiP256(pubX, pubY) }

    /// SEC1 EC private key PEM (the form an agent persists to disk for reuse).
    var privatePEM: [UInt8] { ecPrivateKeyPEM(priv32: priv, pubX: pubX, pubY: pubY) }
}

/// Derive the public point for a private scalar; nil if the scalar is degenerate.
func ecPublicForScalar(_ priv32: [UInt8]) -> ECKeyPair? {
    if priv32.count != 32 { return nil }
    var x = [UInt8](repeating: 0, count: 32)
    var y = [UInt8](repeating: 0, count: 32)
    var ok = false
    priv32.withUnsafeBytes { p in
        x.withUnsafeMutableBytes { xp in y.withUnsafeMutableBytes { yp in
            ok = p256DerivePublic(p.baseAddress!, xp.baseAddress!, yp.baseAddress!)
        } }
    }
    return ok ? ECKeyPair(priv: priv32, pubX: x, pubY: y) : nil
}

/// Generate a fresh P-256 key pair, drawing 32 random bytes from `rng` and
/// retrying until the scalar is a valid public-key generator. `rng` fills the
/// buffer in place (host test: deterministic PRNG; on-device: swiftos_random).
func generateECKeyPair(_ rng: (inout [UInt8]) -> Void) -> ECKeyPair? {
    var scalar = [UInt8](repeating: 0, count: 32)
    var tries = 0
    while tries < 64 {
        tries += 1
        rng(&scalar)
        if let kp = ecPublicForScalar(scalar) { return kp }
    }
    return nil
}

// MARK: - Name + Validity DER

/// RDNSequence with a single commonName attribute (UTF8String value).
private func derName(commonName: String) -> [UInt8] {
    let value = derTLV(0x0C, Array(commonName.utf8))            // UTF8String
    let atv = derSequence([derOID(OID_COMMON_NAME), value])    // AttributeTypeAndValue
    let rdn = derTLV(0x31, atv)                                 // SET OF (one)
    return derSequence([rdn])                                  // RDNSequence
}

/// Decompose Unix seconds into civil (y, mo, d, hh, mm, ss) — Hinnant's algorithm,
/// matching x509_verify.swift's unixToYYYYMMDDHHMMSS so issued and parsed times
/// line up.
private func civilFromUnix(_ t: UInt64) -> (Int, Int, Int, Int, Int, Int) {
    let days = Int(t / 86400)
    let sod = Int(t % 86400)
    let hh = sod / 3600, mm = (sod % 3600) / 60, ss = sod % 60
    let z = days + 719468
    let era = (z >= 0 ? z : z - 146096) / 146097
    let doe = z - era * 146097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    var y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    if m <= 2 { y += 1 }
    return (y, m, d, hh, mm, ss)
}

/// ASN.1 Time for `unixSeconds`: UTCTime (YYMMDDHHMMSSZ) for years < 2050,
/// GeneralizedTime otherwise (RFC 5280 §4.1.2.5).
private func derTime(_ unixSeconds: UInt64) -> [UInt8] {
    let (y, mo, d, hh, mm, ss) = civilFromUnix(unixSeconds)
    func d2(_ v: Int) -> [UInt8] { [UInt8(0x30 + (v / 10) % 10), UInt8(0x30 + v % 10)] }
    if y < 2050 {
        var s = d2(y % 100); s += d2(mo); s += d2(d); s += d2(hh); s += d2(mm); s += d2(ss)
        s.append(0x5A)                                         // 'Z'
        return derTLV(0x17, s)                                 // UTCTime
    } else {
        func d4(_ v: Int) -> [UInt8] { [UInt8(0x30 + (v/1000)%10), UInt8(0x30 + (v/100)%10),
                                        UInt8(0x30 + (v/10)%10), UInt8(0x30 + v%10)] }
        var s = d4(y); s += d2(mo); s += d2(d); s += d2(hh); s += d2(mm); s += d2(ss)
        s.append(0x5A)
        return derTLV(0x18, s)                                 // GeneralizedTime
    }
}

private func derValidity(notBefore: UInt64, notAfter: UInt64) -> [UInt8] {
    derSequence([derTime(notBefore), derTime(notAfter)])
}

// MARK: - Extensions

/// basicConstraints cA=TRUE, marked critical.
private func extBasicConstraintsCA() -> [UInt8] {
    let value = derSequence([derTLV(0x01, [0xFF])])            // SEQUENCE { cA BOOLEAN TRUE }
    let octet = derTLV(0x04, value)                           // extnValue OCTET STRING
    return derSequence([derOID(OID_BASIC_CONSTRAINTS), derTLV(0x01, [0xFF]), octet]) // critical
}

/// subjectAltName with one dNSName.
private func extSAN(dnsName: String) -> [UInt8] {
    let gn = derTLV(0x82, Array(dnsName.utf8))                // [2] IMPLICIT dNSName
    let names = derSequence([gn])                            // GeneralNames
    let octet = derTLV(0x04, names)
    return derSequence([derOID(OID_SAN_ID), octet])
}

// MARK: - Certificate issuance

/// Build and sign an X.509 v3 certificate. `subjectKeyPoint` is the subject's
/// uncompressed EC point (65B); `issuerKey` is the CA's key pair (self-signed if
/// it equals the subject). `serial` is a positive big-endian magnitude. Times are
/// Unix seconds. Returns the DER certificate, or nil on a signing failure.
func issueCertificate(subjectCN: String,
                      sanDNS: String,
                      isCA: Bool,
                      subjectKeyPoint65: [UInt8],
                      serial: [UInt8],
                      issuerCN: String,
                      issuerPriv32: [UInt8],
                      notBefore: UInt64,
                      notAfter: UInt64) -> [UInt8]? {
    if subjectKeyPoint65.count != 65 || subjectKeyPoint65[0] != 0x04 { return nil }
    let pubX = Array(subjectKeyPoint65[1..<33])
    let pubY = Array(subjectKeyPoint65[33..<65])

    let version = derTLV(0xA0, derInteger([0x02]))            // [0] EXPLICIT v3(2)
    let serialDER = derInteger(serial.isEmpty ? [0x01] : serial)
    let inner = algEcdsaSha256()                             // signature AlgorithmIdentifier
    let issuer = derName(commonName: issuerCN)
    let validity = derValidity(notBefore: notBefore, notAfter: notAfter)
    let subject = derName(commonName: subjectCN)
    let spki = spkiP256(pubX, pubY)

    var exts: [[UInt8]] = []
    if isCA { exts.append(extBasicConstraintsCA()) }
    exts.append(extSAN(dnsName: sanDNS))
    let extensions = derTLV(0xA3, derSequence(exts))         // [3] EXPLICIT Extensions

    let tbs = derSequence([version, serialDER, inner, issuer, validity, subject, spki, extensions])

    // Sign SHA-256(TBS) with the issuer's P-256 key.
    var h = [UInt8](repeating: 0, count: 32)
    tbs.withUnsafeBytes { tp in h.withUnsafeMutableBytes { hp in sha256(tp.baseAddress!, tbs.count, hp.baseAddress!) } }
    var r = [UInt8](repeating: 0, count: 32)
    var s = [UInt8](repeating: 0, count: 32)
    var ok = false
    issuerPriv32.withUnsafeBytes { dp in h.withUnsafeBytes { hp in
        r.withUnsafeMutableBytes { rp in s.withUnsafeMutableBytes { sp in
            ok = p256SignDeterministic(dp.baseAddress!, hp.baseAddress!, rp.baseAddress!, sp.baseAddress!)
        } } } }
    if !ok { return nil }

    let sigAlg = algEcdsaSha256()
    let signature = derBitString(ecdsaSigValueDER(r, s))
    return derSequence([tbs, sigAlg, signature])
}

// MARK: - Controller CA

/// The controller's certificate authority: its key pair and self-signed CA cert.
/// The CA never leaves the controller; only `caCertDER` (the trust anchor) is
/// distributed, baked into agents as the root they verify the server against and
/// the controller verifies client certs against.
struct ControllerCA {
    var key: ECKeyPair
    var caCertDER: [UInt8]
    let commonName: String

    /// Create a CA: generate a key, self-sign a CA cert valid [notBefore, notAfter].
    static func create(commonName: String, notBefore: UInt64, notAfter: UInt64,
                       serial: [UInt8], _ rng: (inout [UInt8]) -> Void) -> ControllerCA? {
        guard let key = generateECKeyPair(rng) else { return nil }
        guard let cert = issueCertificate(subjectCN: commonName, sanDNS: commonName, isCA: true,
                                          subjectKeyPoint65: key.point65, serial: serial,
                                          issuerCN: commonName, issuerPriv32: key.priv,
                                          notBefore: notBefore, notAfter: notAfter) else { return nil }
        return ControllerCA(key: key, caCertDER: cert, commonName: commonName)
    }

    /// Sign an entity cert (leaf) binding `subjectCN`/`sanDNS` to `subjectKeyPoint65`.
    func sign(subjectCN: String, sanDNS: String, subjectKeyPoint65: [UInt8],
              serial: [UInt8], notBefore: UInt64, notAfter: UInt64) -> [UInt8]? {
        issueCertificate(subjectCN: subjectCN, sanDNS: sanDNS, isCA: false,
                         subjectKeyPoint65: subjectKeyPoint65, serial: serial,
                         issuerCN: commonName, issuerPriv32: key.priv,
                         notBefore: notBefore, notAfter: notAfter)
    }
}

// MARK: - CSR parsing (the join request carries a PKCS#10 CSR)

/// The public key extracted from a verified PKCS#10 CSR.
struct CSRPublicKey {
    var point65: [UInt8]      // uncompressed EC point (0x04‖X‖Y)
    var spki: [UInt8]         // full SubjectPublicKeyInfo TLV
}

/// Parse a PKCS#10 CSR (DER), verify its self-signature (proof of possession),
/// and return the subject's EC public key. Only EC P-256 + ecdsa-with-SHA256 is
/// accepted (the one scheme our identity uses). Returns nil on any failure.
func parseAndVerifyCSR(_ der: [UInt8]) -> CSRPublicKey? {
    // CertificationRequest ::= SEQUENCE { info, signatureAlgorithm, signature }
    guard let req = derAt(der, 0), req.tag == 0x30 else { return nil }
    let top = derChildren(der, req)
    guard top.count >= 3 else { return nil }
    let info = top[0], sigAlg = top[1], sig = top[2]
    guard info.tag == 0x30 else { return nil }

    // signatureAlgorithm must be ecdsa-with-SHA256.
    let sigAlgKids = derChildren(der, sigAlg)
    guard let sigOID = sigAlgKids.first, sigOID.tag == 0x06,
          derContentBytes(der, sigOID) == OID_ECDSA_SHA256 else { return nil }

    // info = { version, subject, SPKI, [attributes] } — SPKI is the 3rd child.
    let infoKids = derChildren(der, info)
    guard infoKids.count >= 3 else { return nil }
    let spkiT = infoKids[2]
    guard spkiT.tag == 0x30 else { return nil }
    let spkiKids = derChildren(der, spkiT)
    guard spkiKids.count >= 2, spkiKids[1].tag == 0x03 else { return nil }
    // subjectPublicKey BIT STRING content, drop the unused-bits octet → EC point.
    let bs = spkiKids[1]
    guard bs.clen >= 2 else { return nil }
    let point = Array(der[(bs.cstart + 1)..<bs.end])
    guard point.count == 65, point[0] == 0x04 else { return nil }

    // Verify the self-signature: SHA-256 over the certificationRequestInfo TLV.
    let infoBytes = derElementBytes(der, info)
    var h = [UInt8](repeating: 0, count: 32)
    infoBytes.withUnsafeBytes { ip in h.withUnsafeMutableBytes { hp in sha256(ip.baseAddress!, infoBytes.count, hp.baseAddress!) } }
    let sigBytes = bitStringContent(der, sig)
    if !ecdsaP256VerifyDER(point65: point, hash32: h, derSig: sigBytes) { return nil }

    return CSRPublicKey(point65: point, spki: derElementBytes(der, spkiT))
}

/// BIT STRING content with the leading unused-bits octet removed.
private func bitStringContent(_ b: [UInt8], _ t: DERTLV) -> [UInt8] {
    if t.tag != 0x03 || t.clen <= 1 { return [] }
    return Array(b[(t.cstart + 1)..<t.end])
}

// MARK: - Client-cert chain verification (no hostname; identity from SAN)

/// Verify a presented client/leaf cert chains to one of `roots`, is time-valid at
/// `now` (YYYYMMDDHHMMSS), and return the identity carried in its SAN dNSName.
/// Unlike x509VerifyChain this does NOT match a hostname — a client cert's
/// identity is its node id, which the controller reads out and authorizes.
func verifyClientIdentity(leafDER: [UInt8], intermediatesDER: [[UInt8]],
                          roots: [X509Cert], now: UInt64) -> String? {
    guard let leaf = parseX509(leafDER) else { return nil }
    var inters: [X509Cert] = []
    for d in intermediatesDER { if let c = parseX509(d) { inters.append(c) } }
    if !chainAnchored(leaf: leaf, intermediates: inters, roots: roots, now: now) { return nil }
    return leaf.dnsNames.first
}

/// Chain/validity/CA-anchor walk without the host check (mirrors x509VerifyChain's
/// link logic, used for client certs whose identity is not a hostname).
private func chainAnchored(leaf: X509Cert, intermediates: [X509Cert],
                           roots: [X509Cert], now: UInt64) -> Bool {
    var cur = leaf
    var depth = 0
    while depth < 10 {
        depth += 1
        if now < cur.notBefore || now > cur.notAfter { return false }
        for root in roots where root.subject == cur.issuer {
            if now >= root.notBefore && now <= root.notAfter && root.isCA
               && x509VerifyChainLink(child: cur, issuer: root) { return true }
        }
        var stepped = false
        for inter in intermediates where inter.isCA && inter.subject == cur.issuer {
            if x509VerifyChainLink(child: cur, issuer: inter) { cur = inter; stepped = true; break }
        }
        if !stepped { return false }
    }
    return false
}
