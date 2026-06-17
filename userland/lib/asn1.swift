// SPDX-License-Identifier: Apache-2.0
//
// asn1.swift — the minimal ASN.1 DER an ACME (RFC 8555) client emits: a
// SubjectPublicKeyInfo for an EC P-256 key, an ECDSA-Sig-Value, and a PKCS#10
// (RFC 2986) CertificationRequest carrying subjectAltName dNSName entries and a
// self-signature over the request info, using ECDSA from kernel/crypto/p256.swift.
//
// Embedded-compatible (heap byte arrays, no Foundation). Only the DER *writing*
// primitives needed for these structures are implemented — no general parser.
// Pinned by tests/jose_test.swift (structure + valid self-signature) and cross-
// checked against `openssl req -verify`.

// MARK: - DER primitives

/// Definite-length octets (DER, minimal encoding).
private func derLen(_ n: Int) -> [UInt8] {
    if n < 0x80 { return [UInt8(n)] }
    var tmp = [UInt8]()
    var x = n
    while x > 0 { tmp.insert(UInt8(x & 0xff), at: 0); x >>= 8 }
    return [UInt8(0x80 | tmp.count)] + tmp
}

/// tag ‖ length ‖ content.
func derTLV(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
    var o: [UInt8] = [tag]
    o += derLen(content.count)
    o += content
    return o
}

/// SEQUENCE of the concatenated items (tag 0x30).
func derSequence(_ items: [[UInt8]]) -> [UInt8] {
    var c = [UInt8]()
    for it in items { c += it }
    return derTLV(0x30, c)
}

/// INTEGER from a big-endian magnitude: strip leading zeros, prepend 0x00 when
/// the high bit would otherwise make the value negative.
func derInteger(_ be: [UInt8]) -> [UInt8] {
    var i = 0
    while i < be.count - 1 && be[i] == 0 { i += 1 }
    var v = Array(be[i...])
    if v.isEmpty { v = [0] }
    if v[0] & 0x80 != 0 { v.insert(0, at: 0) }
    return derTLV(0x02, v)
}

/// BIT STRING with zero unused bits (tag 0x03, leading 0x00).
func derBitString(_ content: [UInt8]) -> [UInt8] {
    derTLV(0x03, [0x00] + content)
}

/// OBJECT IDENTIFIER from its pre-encoded body octets (tag 0x06).
func derOID(_ body: [UInt8]) -> [UInt8] { derTLV(0x06, body) }

// OID bodies (the bytes after tag/length).
private let OID_EC_PUBKEY: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]        // 1.2.840.10045.2.1
private let OID_P256: [UInt8]      = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]  // 1.2.840.10045.3.1.7
private let OID_ECDSA_SHA256: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02] // 1.2.840.10045.4.3.2
private let OID_EXT_REQUEST: [UInt8]  = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x0E] // 1.2.840.113549.1.9.14
private let OID_SAN: [UInt8] = [0x55, 0x1D, 0x11]                                       // 2.5.29.17

// MARK: - structures

/// SubjectPublicKeyInfo for an uncompressed EC P-256 point.
func spkiP256(_ x32: [UInt8], _ y32: [UInt8]) -> [UInt8] {
    let alg = derSequence([derOID(OID_EC_PUBKEY), derOID(OID_P256)])
    var point: [UInt8] = [0x04]   // uncompressed point
    point += x32
    point += y32
    return derSequence([alg, derBitString(point)])
}

/// ECDSA-Sig-Value ::= SEQUENCE { r INTEGER, s INTEGER }, from raw 32-byte r,s.
func ecdsaSigValueDER(_ r32: [UInt8], _ s32: [UInt8]) -> [UInt8] {
    derSequence([derInteger(r32), derInteger(s32)])
}

/// CertificationRequestInfo (the to-be-signed body of a PKCS#10 CSR): version 0,
/// empty subject, the EC SPKI, and an extensionRequest attribute holding a
/// subjectAltName with the given dNSName entries (each as raw UTF-8 bytes).
func csrInfoDER(dnsNames: [[UInt8]], pubX: [UInt8], pubY: [UInt8]) -> [UInt8] {
    let version = derTLV(0x02, [0x00])         // INTEGER 0
    let subject = derSequence([])              // empty Name (RFC requires SANs)
    let spki = spkiP256(pubX, pubY)

    var gnItems = [[UInt8]]()
    for d in dnsNames { gnItems.append(derTLV(0x82, d)) }   // [2] IMPLICIT IA5String dNSName
    let generalNames = derSequence(gnItems)
    let sanExtnValue = derTLV(0x04, generalNames)           // OCTET STRING wraps GeneralNames
    let sanExtension = derSequence([derOID(OID_SAN), sanExtnValue])
    let extensions = derSequence([sanExtension])
    let attrValues = derTLV(0x31, extensions)               // SET
    let extReqAttr = derSequence([derOID(OID_EXT_REQUEST), attrValues])
    let attributes = derTLV(0xA0, extReqAttr)               // [0] IMPLICIT (single attribute)

    return derSequence([version, subject, spki, attributes])
}

/// A complete, self-signed PKCS#10 CSR (DER bytes), ready for the base64url of
/// an ACME finalize payload. `priv32` is the certificate key's private scalar
/// (big-endian); `pubX`/`pubY` its public point. Returns nil on a signing
/// failure (degenerate key).
func acmeCSR(dnsNames: [[UInt8]], pubX: [UInt8], pubY: [UInt8], priv32: [UInt8]) -> [UInt8]? {
    let tbs = csrInfoDER(dnsNames: dnsNames, pubX: pubX, pubY: pubY)

    var h = [UInt8](repeating: 0, count: 32)
    tbs.withUnsafeBytes { tp in
        h.withUnsafeMutableBytes { hp in sha256(tp.baseAddress!, tbs.count, hp.baseAddress!) }
    }
    var r = [UInt8](repeating: 0, count: 32)
    var s = [UInt8](repeating: 0, count: 32)
    var ok = false
    priv32.withUnsafeBytes { dp in
        h.withUnsafeBytes { hp in
            r.withUnsafeMutableBytes { rp in
                s.withUnsafeMutableBytes { sp in
                    ok = p256SignDeterministic(dp.baseAddress!, hp.baseAddress!,
                                               rp.baseAddress!, sp.baseAddress!)
                }
            }
        }
    }
    if !ok { return nil }

    let sigAlg = derSequence([derOID(OID_ECDSA_SHA256)])
    let signature = derBitString(ecdsaSigValueDER(r, s))
    return derSequence([tbs, sigAlg, signature])
}

// MARK: - EC private key (SEC1) + PEM

private let B64_STD: [UInt8] =
    Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

/// Standard base64 with '=' padding (RFC 4648 §4).
func base64StdEncode(_ data: [UInt8]) -> [UInt8] {
    var out = [UInt8]()
    var i = 0
    while i + 3 <= data.count {
        let n = (UInt32(data[i]) << 16) | (UInt32(data[i + 1]) << 8) | UInt32(data[i + 2])
        out.append(B64_STD[Int((n >> 18) & 0x3f)]); out.append(B64_STD[Int((n >> 12) & 0x3f)])
        out.append(B64_STD[Int((n >> 6) & 0x3f)]);  out.append(B64_STD[Int(n & 0x3f)])
        i += 3
    }
    let rem = data.count - i
    if rem == 1 {
        let n = UInt32(data[i]) << 16
        out.append(B64_STD[Int((n >> 18) & 0x3f)]); out.append(B64_STD[Int((n >> 12) & 0x3f)])
        out.append(0x3D); out.append(0x3D)
    } else if rem == 2 {
        let n = (UInt32(data[i]) << 16) | (UInt32(data[i + 1]) << 8)
        out.append(B64_STD[Int((n >> 18) & 0x3f)]); out.append(B64_STD[Int((n >> 12) & 0x3f)])
        out.append(B64_STD[Int((n >> 6) & 0x3f)]); out.append(0x3D)
    }
    return out
}

/// Wrap DER in a PEM block ("-----BEGIN <label>-----" … 64-col base64 … END).
func pemWrap(_ der: [UInt8], _ label: StaticString) -> [UInt8] {
    var lbl = [UInt8](); label.withUTF8Buffer { bp in for b in bp { lbl.append(b) } }
    let b64 = base64StdEncode(der)
    var out: [UInt8] = []
    out += Array("-----BEGIN ".utf8); out += lbl; out += Array("-----\n".utf8)
    var i = 0
    while i < b64.count {
        let end = min(i + 64, b64.count)
        out += Array(b64[i..<end]); out.append(0x0A)
        i = end
    }
    out += Array("-----END ".utf8); out += lbl; out += Array("-----\n".utf8)
    return out
}

/// SEC1 ECPrivateKey (RFC 5915) DER for a P-256 key: version 1, the 32-byte
/// scalar, the namedCurve parameters, and the public point.
func ecPrivateKeyDER(priv32: [UInt8], pubX: [UInt8], pubY: [UInt8]) -> [UInt8] {
    let version = derTLV(0x02, [0x01])
    let pk = derTLV(0x04, priv32)                 // OCTET STRING, the raw scalar
    let params = derTLV(0xA0, derOID(OID_P256))   // [0] EXPLICIT namedCurve
    var point: [UInt8] = [0x04]; point += pubX; point += pubY
    let pub = derTLV(0xA1, derBitString(point))   // [1] EXPLICIT publicKey
    return derSequence([version, pk, params, pub])
}

/// PEM-encoded SEC1 EC private key (nginx's ssl_certificate_key form).
func ecPrivateKeyPEM(priv32: [UInt8], pubX: [UInt8], pubY: [UInt8]) -> [UInt8] {
    pemWrap(ecPrivateKeyDER(priv32: priv32, pubX: pubX, pubY: pubY), "EC PRIVATE KEY")
}
