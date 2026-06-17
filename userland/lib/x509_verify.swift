// SPDX-License-Identifier: Apache-2.0
//
// x509_verify.swift — verify that a certificate's signature was produced by a
// given issuer's public key (one link of a chain). Dispatches on the child's
// signatureAlgorithm: ecdsa-with-SHA256 → p256.swift, sha256WithRSAEncryption →
// rsa.swift, both over SHA-256(tbsCertificate). This is the V1 building block;
// V2 walks the chain to a trust anchor and adds host/date checks.
//
// Embedded-compatible. Pinned by tests/x509_verify_test.swift against openssl
// ECDSA and RSA CA→leaf fixtures.

private let OID_ECDSA_SHA256: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]      // 1.2.840.10045.4.3.2
private let OID_RSA_SHA256: [UInt8]   = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B] // 1.2.840.113549.1.1.11

/// An ASN.1 INTEGER's magnitude, leading zeros stripped, left-padded to 32 bytes
/// (for an ECDSA P-256 r/s component). Returns [] if it does not fit.
private func intTo32(_ b: [UInt8], _ t: DERTLV) -> [UInt8] {
    var v = Array(b[t.cstart..<t.end])
    while v.count > 1 && v[0] == 0 { v.removeFirst() }
    if v.count > 32 { return [] }
    while v.count < 32 { v.insert(0, at: 0) }
    return v
}

/// Verify an ECDSA-P256 signature (DER ECDSA-Sig-Value) over `hash32` under the
/// uncompressed public point `point65` (0x04‖X‖Y). Shared by chain-link checks
/// and the TLS CertificateVerify path.
func ecdsaP256VerifyDER(point65: [UInt8], hash32: [UInt8], derSig: [UInt8]) -> Bool {
    if point65.count != 65 || point65[0] != 0x04 || hash32.count != 32 { return false }
    let x = Array(point65[1..<33]); let y = Array(point65[33..<65])
    guard let seq = derAt(derSig, 0), seq.tag == 0x30 else { return false }
    let kids = derChildren(derSig, seq)
    guard kids.count >= 2 else { return false }
    let r = intTo32(derSig, kids[0])
    let s = intTo32(derSig, kids[1])
    if r.count != 32 || s.count != 32 { return false }
    var ok = false
    x.withUnsafeBytes { xp in y.withUnsafeBytes { yp in hash32.withUnsafeBytes { hp in
    r.withUnsafeBytes { rp in s.withUnsafeBytes { sp in
        ok = p256Verify(xp.baseAddress!, yp.baseAddress!, hp.baseAddress!,
                        rp.baseAddress!, sp.baseAddress!) } } } } }
    return ok
}

/// Verify `child`'s signature against `issuer`'s public key. Does NOT check
/// names, validity, or basic constraints — that is the chain-walk's job (V2).
func x509VerifyChainLink(child: X509Cert, issuer: X509Cert) -> Bool {
    var h = [UInt8](repeating: 0, count: 32)
    child.tbs.withUnsafeBytes { tp in
        h.withUnsafeMutableBytes { hp in sha256(tp.baseAddress!, child.tbs.count, hp.baseAddress!) }
    }

    if child.sigAlgOID == OID_ECDSA_SHA256 {
        return ecdsaP256VerifyDER(point65: issuer.spkiKey, hash32: h, derSig: child.signature)
    }

    if child.sigAlgOID == OID_RSA_SHA256 {
        // issuer.spkiKey = RSAPublicKey ::= SEQUENCE { modulus INTEGER, exponent INTEGER }
        guard let seq = derAt(issuer.spkiKey, 0), seq.tag == 0x30 else { return false }
        let kids = derChildren(issuer.spkiKey, seq)
        guard kids.count >= 2 else { return false }
        var n = Array(issuer.spkiKey[kids[0].cstart..<kids[0].end])
        while n.count > 1 && n[0] == 0 { n.removeFirst() }      // strip the sign byte
        let e = Array(issuer.spkiKey[kids[1].cstart..<kids[1].end])
        return rsaVerifyPKCS1SHA256(modulusBE: n, exponentBE: e,
                                    message: child.tbs, signatureBE: child.signature)
    }

    return false
}

// MARK: - chain / host / date validation

/// Unix seconds → a comparable YYYYMMDDHHMMSS (same shape parseX509 produces),
/// via Howard Hinnant's civil-from-days algorithm. Valid for dates ≥ 1970.
func unixToYYYYMMDDHHMMSS(_ t: UInt64) -> UInt64 {
    let days = Int(t / 86400)
    let sod = Int(t % 86400)
    let hh = sod / 3600, mm = (sod % 3600) / 60, ss = sod % 60
    let z = days + 719468
    let era = (z >= 0 ? z : z - 146096) / 146097
    let doe = z - era * 146097                                  // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    var y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)           // [0, 365]
    let mp = (5 * doy + 2) / 153                                 // [0, 11]
    let d = doy - (153 * mp + 2) / 5 + 1                         // [1, 31]
    let m = mp < 10 ? mp + 3 : mp - 9                            // [1, 12]
    if m <= 2 { y += 1 }
    return UInt64(y) * 10_000_000_000 + UInt64(m) * 100_000_000 + UInt64(d) * 1_000_000
         + UInt64(hh) * 10_000 + UInt64(mm) * 100 + UInt64(ss)
}

private func asciiLower(_ b: [UInt8]) -> [UInt8] {
    var o = b
    for i in 0..<o.count where o[i] >= 0x41 && o[i] <= 0x5A { o[i] += 32 }
    return o
}

/// Match a hostname against a SAN dNSName, supporting a single leftmost `*`
/// wildcard label (`*.example.com` matches `a.example.com`, not the bare apex
/// or `a.b.example.com`). Case-insensitive.
func hostnameMatchesSAN(_ host: String, _ sans: [String]) -> Bool {
    let h = asciiLower(Array(host.utf8))
    for san in sans {
        let s = asciiLower(Array(san.utf8))
        if s == h { return true }
        // wildcard: s == "*." + suffix ; host == label + "." + suffix
        if s.count >= 2 && s[0] == 0x2A && s[1] == 0x2E {
            let suffix = Array(s[2...])                          // after "*."
            guard let dot = h.firstIndex(of: 0x2E) else { continue }
            let hostSuffix = Array(h[(dot + 1)...])
            if !suffix.isEmpty && hostSuffix == suffix { return true }
        }
    }
    return false
}

/// Verify a server certificate: the leaf chains (via the presented
/// intermediates) to a trusted self-signed root, every cert is within its
/// validity window at `now` (YYYYMMDDHHMMSS), CAs carry basicConstraints CA:TRUE,
/// and the leaf's SAN matches `hostname`. Returns true only if all hold.
private func isDottedIPv4(_ s: [UInt8]) -> Bool {
    var dots = 0, digits = 0, any = false
    for c in s {
        if c == 0x2E { if digits == 0 { return false }; dots += 1; digits = 0 }
        else if c >= 0x30 && c <= 0x39 { digits += 1; any = true }
        else { return false }
    }
    return any && dots == 3 && digits > 0
}

func x509VerifyChain(leaf: X509Cert, intermediates: [X509Cert],
                     roots: [X509Cert], hostname: String, now: UInt64) -> Bool {
    let hb = Array(hostname.utf8)
    let hostOK: Bool
    if isDottedIPv4(hb) {
        hostOK = leaf.ipSANs.contains { Array($0.utf8) == hb }   // exact iPAddress SAN
    } else {
        hostOK = hostnameMatchesSAN(hostname, leaf.dnsNames)
    }
    if !hostOK { return false }

    var cur = leaf
    var depth = 0
    while depth < 10 {
        depth += 1
        if now < cur.notBefore || now > cur.notAfter { return false }

        // Anchored at a trusted root?
        for root in roots where root.subject == cur.issuer {
            if now >= root.notBefore && now <= root.notAfter && root.isCA
               && x509VerifyChainLink(child: cur, issuer: root) {
                return true
            }
        }
        // Otherwise step up through a presented intermediate CA.
        var stepped = false
        for inter in intermediates where inter.isCA && inter.subject == cur.issuer {
            if x509VerifyChainLink(child: cur, issuer: inter) {
                cur = inter; stepped = true; break
            }
        }
        if !stepped { return false }
    }
    return false
}
