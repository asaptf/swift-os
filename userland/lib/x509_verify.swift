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
