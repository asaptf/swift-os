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

/// Verify `child`'s signature against `issuer`'s public key. Does NOT check
/// names, validity, or basic constraints — that is the chain-walk's job (V2).
func x509VerifyChainLink(child: X509Cert, issuer: X509Cert) -> Bool {
    var h = [UInt8](repeating: 0, count: 32)
    child.tbs.withUnsafeBytes { tp in
        h.withUnsafeMutableBytes { hp in sha256(tp.baseAddress!, child.tbs.count, hp.baseAddress!) }
    }

    if child.sigAlgOID == OID_ECDSA_SHA256 {
        let key = issuer.spkiKey
        if key.count != 65 || key[0] != 0x04 { return false }   // uncompressed P-256 point
        let x = Array(key[1..<33]); let y = Array(key[33..<65])
        guard let seq = derAt(child.signature, 0), seq.tag == 0x30 else { return false }
        let kids = derChildren(child.signature, seq)
        guard kids.count >= 2 else { return false }
        let r = intTo32(child.signature, kids[0])
        let s = intTo32(child.signature, kids[1])
        if r.count != 32 || s.count != 32 { return false }
        var ok = false
        x.withUnsafeBytes { xp in y.withUnsafeBytes { yp in h.withUnsafeBytes { hp in
        r.withUnsafeBytes { rp in s.withUnsafeBytes { sp in
            ok = p256Verify(xp.baseAddress!, yp.baseAddress!, hp.baseAddress!,
                            rp.baseAddress!, sp.baseAddress!) } } } } }
        return ok
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
func x509VerifyChain(leaf: X509Cert, intermediates: [X509Cert],
                     roots: [X509Cert], hostname: String, now: UInt64) -> Bool {
    if !hostnameMatchesSAN(hostname, leaf.dnsNames) { return false }

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
