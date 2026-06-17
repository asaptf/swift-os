// SPDX-License-Identifier: Apache-2.0
//
// x509.swift — a minimal X.509 (RFC 5280) certificate DER *reader* for the TLS
// client's certificate verification. asn1.swift only writes DER; this adds the
// reading side: a small TLV walker and a parser that pulls out the fields chain
// validation needs — the TBSCertificate bytes (what the signature covers), the
// signature and its algorithm, issuer/subject names (for chain linking), the
// validity window, the SubjectPublicKeyInfo, the subjectAltName dNSNames, and
// the basicConstraints CA flag.
//
// Embedded-compatible (heap byte arrays, no Foundation). It does not yet verify
// anything — that is V1 (signature) and V2 (chain/host/dates). Pinned by
// tests/x509_test.swift against openssl-generated fixtures.

// MARK: - DER reader

struct DERTLV {
    var tag: UInt8
    var start: Int      // index of the tag byte
    var cstart: Int     // index of the first content byte
    var clen: Int       // content length
    var end: Int { cstart + clen }
}

/// Parse the TLV at `off`. Definite-length only (DER); rejects > 4-byte lengths.
func derAt(_ b: [UInt8], _ off: Int) -> DERTLV? {
    if off + 1 >= b.count { return nil }
    let tag = b[off]
    var i = off + 1
    let l0 = b[i]; i += 1
    var clen = 0
    if l0 < 0x80 {
        clen = Int(l0)
    } else {
        let n = Int(l0 & 0x7f)
        if n == 0 || n > 4 { return nil }
        for _ in 0..<n { if i >= b.count { return nil }; clen = (clen << 8) | Int(b[i]); i += 1 }
    }
    if i + clen > b.count { return nil }
    return DERTLV(tag: tag, start: off, cstart: i, clen: clen)
}

/// Immediate children of a constructed TLV, in order.
func derChildren(_ b: [UInt8], _ t: DERTLV) -> [DERTLV] {
    var out: [DERTLV] = []
    var off = t.cstart
    while off < t.end {
        guard let c = derAt(b, off) else { break }
        out.append(c)
        off = c.end
    }
    return out
}

/// The full TLV bytes (tag‖len‖content) of an element.
func derElementBytes(_ b: [UInt8], _ t: DERTLV) -> [UInt8] { Array(b[t.start..<t.end]) }
/// Just the content bytes of an element.
func derContentBytes(_ b: [UInt8], _ t: DERTLV) -> [UInt8] { Array(b[t.cstart..<t.end]) }

// MARK: - certificate

struct X509Cert {
    var tbs: [UInt8]          // full TBSCertificate TLV — what the signature covers
    var sigAlgOID: [UInt8]
    var signature: [UInt8]    // signature BIT STRING content (unused-bits byte removed)
    var issuer: [UInt8]       // full Name TLV
    var subject: [UInt8]      // full Name TLV
    var notBefore: UInt64     // normalized YYYYMMDDHHMMSS
    var notAfter: UInt64
    var spkiAlgOID: [UInt8]
    var spkiKey: [UInt8]      // subjectPublicKey BIT STRING content (unused-bits byte removed)
    var spki: [UInt8]         // full SubjectPublicKeyInfo TLV (for key reuse)
    var dnsNames: [String]
    var isCA: Bool
}

private let OID_SAN: [UInt8] = [0x55, 0x1D, 0x11]              // 2.5.29.17
private let OID_BASIC_CONSTRAINTS: [UInt8] = [0x55, 0x1D, 0x13] // 2.5.29.19

/// Normalize an ASN.1 time element to a comparable YYYYMMDDHHMMSS integer.
private func parseTime(_ b: [UInt8], _ t: DERTLV) -> UInt64 {
    var d: [Int] = []
    for k in t.cstart..<t.end where b[k] >= 0x30 && b[k] <= 0x39 { d.append(Int(b[k] - 0x30)) }
    var year = 0, mon = 0, day = 0, hh = 0, mm = 0, ss = 0
    if t.tag == 0x17 {           // UTCTime: YYMMDDHHMM[SS]
        guard d.count >= 10 else { return 0 }
        let yy = d[0] * 10 + d[1]
        year = yy < 50 ? 2000 + yy : 1900 + yy
        mon = d[2] * 10 + d[3]; day = d[4] * 10 + d[5]
        hh = d[6] * 10 + d[7]; mm = d[8] * 10 + d[9]
        ss = d.count >= 12 ? d[10] * 10 + d[11] : 0
    } else {                     // GeneralizedTime: YYYYMMDDHHMM[SS]
        guard d.count >= 12 else { return 0 }
        year = d[0] * 1000 + d[1] * 100 + d[2] * 10 + d[3]
        mon = d[4] * 10 + d[5]; day = d[6] * 10 + d[7]
        hh = d[8] * 10 + d[9]; mm = d[10] * 10 + d[11]
        ss = d.count >= 14 ? d[12] * 10 + d[13] : 0
    }
    return UInt64(year) * 10_000_000_000 + UInt64(mon) * 100_000_000 + UInt64(day) * 1_000_000
         + UInt64(hh) * 10_000 + UInt64(mm) * 100 + UInt64(ss)
}

/// BIT STRING content with the leading unused-bits octet stripped.
private func bitStringBytes(_ b: [UInt8], _ t: DERTLV) -> [UInt8] {
    if t.clen <= 1 { return [] }
    return Array(b[(t.cstart + 1)..<t.end])
}

/// Parse a DER certificate. Returns nil on a structural error.
func parseX509(_ der: [UInt8]) -> X509Cert? {
    guard let cert = derAt(der, 0), cert.tag == 0x30 else { return nil }
    let top = derChildren(der, cert)
    guard top.count >= 3 else { return nil }
    let tbsT = top[0], sigAlgT = top[1], sigT = top[2]
    guard tbsT.tag == 0x30 else { return nil }

    // signatureAlgorithm OID
    let sigAlgKids = derChildren(der, sigAlgT)
    guard let sigOID = sigAlgKids.first, sigOID.tag == 0x06 else { return nil }
    let sigAlgOID = derContentBytes(der, sigOID)
    let signature = bitStringBytes(der, sigT)

    // TBSCertificate fields
    let k = derChildren(der, tbsT)
    var i = 0
    if i < k.count && k[i].tag == 0xA0 { i += 1 }   // [0] version (optional)
    guard i + 5 < k.count else { return nil }
    i += 1                                          // serialNumber
    i += 1                                          // signature (inner AlgorithmIdentifier)
    let issuerT = k[i]; i += 1
    let validityT = k[i]; i += 1
    let subjectT = k[i]; i += 1
    let spkiT = k[i]; i += 1

    let validityKids = derChildren(der, validityT)
    guard validityKids.count >= 2 else { return nil }
    let notBefore = parseTime(der, validityKids[0])
    let notAfter = parseTime(der, validityKids[1])

    // SubjectPublicKeyInfo
    let spkiKids = derChildren(der, spkiT)
    guard spkiKids.count >= 2 else { return nil }
    let algKids = derChildren(der, spkiKids[0])
    guard let spkiOIDT = algKids.first, spkiOIDT.tag == 0x06 else { return nil }
    let spkiAlgOID = derContentBytes(der, spkiOIDT)
    let spkiKey = bitStringBytes(der, spkiKids[1])

    // extensions: the [3] EXPLICIT element among the remaining TBS children
    var dnsNames: [String] = []
    var isCA = false
    while i < k.count {
        if k[i].tag == 0xA3 {
            let extSeqKids = derChildren(der, k[i])
            if let extSeq = extSeqKids.first {       // SEQUENCE OF Extension
                for ext in derChildren(der, extSeq) {
                    let ec = derChildren(der, ext)
                    guard let oidT = ec.first, oidT.tag == 0x06 else { continue }
                    let oid = derContentBytes(der, oidT)
                    guard let valT = ec.last, valT.tag == 0x04 else { continue }  // extnValue OCTET STRING
                    if oid == OID_SAN {
                        if let names = derAt(der, valT.cstart) {                  // GeneralNames SEQUENCE
                            for gn in derChildren(der, names) where gn.tag == 0x82 {
                                dnsNames.append(String(decoding: der[gn.cstart..<gn.end], as: UTF8.self))
                            }
                        }
                    } else if oid == OID_BASIC_CONSTRAINTS {
                        if let bc = derAt(der, valT.cstart) {                      // SEQUENCE
                            if let first = derChildren(der, bc).first, first.tag == 0x01 {
                                if first.clen >= 1 && der[first.cstart] != 0 { isCA = true }
                            }
                        }
                    }
                }
            }
        }
        i += 1
    }

    return X509Cert(
        tbs: derElementBytes(der, tbsT),
        sigAlgOID: sigAlgOID,
        signature: signature,
        issuer: derElementBytes(der, issuerT),
        subject: derElementBytes(der, subjectT),
        notBefore: notBefore,
        notAfter: notAfter,
        spkiAlgOID: spkiAlgOID,
        spkiKey: spkiKey,
        spki: derElementBytes(der, spkiT),
        dnsNames: dnsNames,
        isCA: isCA)
}
