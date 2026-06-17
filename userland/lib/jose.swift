// SPDX-License-Identifier: Apache-2.0
//
// jose.swift — the JOSE pieces a native ACME (RFC 8555) client needs: base64url
// (RFC 4648 §5, unpadded), an EC JWK and its RFC 7638 thumbprint, the ACME
// key-authorization string, and a flattened JWS signed with ES256 (P-256 +
// SHA-256) from kernel/crypto/p256.swift.
//
// Embedded-compatible like userland/lib/tls13.swift: heap arrays of bytes, no
// Foundation. JSON is emitted as raw UTF-8 bytes in the canonical member order
// RFC 7638 mandates (crv, kty, x, y) so the thumbprint is reproducible. Pinned
// to computed reference values by tests/jose_test.swift.

private let B64URL_ALPHABET: [UInt8] =
    Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

/// Append the UTF-8 bytes of a string literal (Embedded-safe).
private func asc(_ s: StaticString) -> [UInt8] {
    var out = [UInt8]()
    s.withUTF8Buffer { bp in for b in bp { out.append(b) } }
    return out
}

/// base64url without padding (RFC 4648 §5).
func base64urlEncode(_ data: [UInt8]) -> [UInt8] {
    var out = [UInt8]()
    var i = 0
    while i + 3 <= data.count {
        let n = (UInt32(data[i]) << 16) | (UInt32(data[i + 1]) << 8) | UInt32(data[i + 2])
        out.append(B64URL_ALPHABET[Int((n >> 18) & 0x3f)])
        out.append(B64URL_ALPHABET[Int((n >> 12) & 0x3f)])
        out.append(B64URL_ALPHABET[Int((n >> 6) & 0x3f)])
        out.append(B64URL_ALPHABET[Int(n & 0x3f)])
        i += 3
    }
    let rem = data.count - i
    if rem == 1 {
        let n = UInt32(data[i]) << 16
        out.append(B64URL_ALPHABET[Int((n >> 18) & 0x3f)])
        out.append(B64URL_ALPHABET[Int((n >> 12) & 0x3f)])
    } else if rem == 2 {
        let n = (UInt32(data[i]) << 16) | (UInt32(data[i + 1]) << 8)
        out.append(B64URL_ALPHABET[Int((n >> 18) & 0x3f)])
        out.append(B64URL_ALPHABET[Int((n >> 12) & 0x3f)])
        out.append(B64URL_ALPHABET[Int((n >> 6) & 0x3f)])
    }
    return out
}

/// base64url decode, tolerant of optional '=' padding. Returns nil on a bad char.
func base64urlDecode(_ s: [UInt8]) -> [UInt8]? {
    func val(_ c: UInt8) -> Int {
        if c >= 0x41 && c <= 0x5A { return Int(c - 0x41) }       // A-Z
        if c >= 0x61 && c <= 0x7A { return Int(c - 0x61 + 26) }  // a-z
        if c >= 0x30 && c <= 0x39 { return Int(c - 0x30 + 52) }  // 0-9
        if c == 0x2D { return 62 }                               // -
        if c == 0x5F { return 63 }                               // _
        return -1
    }
    var acc = 0
    var bits = 0
    var out = [UInt8]()
    for c in s {
        if c == 0x3D { break }   // '=' terminates
        let v = val(c)
        if v < 0 { return nil }
        acc = (acc << 6) | v
        bits += 6
        if bits >= 8 {
            bits -= 8
            out.append(UInt8((acc >> bits) & 0xff))
        }
    }
    return out
}

/// SHA-256 of an arbitrary byte buffer (32-byte digest).
private func sha256Bytes(_ data: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 32)
    data.withUnsafeBytes { dp in
        out.withUnsafeMutableBytes { op in
            sha256(dp.baseAddress!, data.count, op.baseAddress!)
        }
    }
    return out
}

/// Canonical EC P-256 public JWK (RFC 7638 member order, no whitespace):
/// {"crv":"P-256","kty":"EC","x":"<b64u(X)>","y":"<b64u(Y)>"}
func jwkES256JSON(_ x32: [UInt8], _ y32: [UInt8]) -> [UInt8] {
    var o = asc("{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"")
    o += base64urlEncode(x32)
    o += asc("\",\"y\":\"")
    o += base64urlEncode(y32)
    o += asc("\"}")
    return o
}

/// RFC 7638 JWK thumbprint: SHA-256 of the canonical JWK (32 raw bytes).
func jwkThumbprint(_ x32: [UInt8], _ y32: [UInt8]) -> [UInt8] {
    sha256Bytes(jwkES256JSON(x32, y32))
}

/// ACME key authorization: token "." base64url(thumbprint).
func acmeKeyAuthorization(_ token: [UInt8], _ x32: [UInt8], _ y32: [UInt8]) -> [UInt8] {
    var o = token
    o.append(0x2E)   // '.'
    o += base64urlEncode(jwkThumbprint(x32, y32))
    return o
}

/// Flattened JWS (RFC 7515 §7.2.2) signed with ES256. `protectedJSON` is the
/// raw protected-header JSON; `payloadJSON` is the raw payload (empty for an
/// ACME POST-as-GET). Returns the flattened JSON object bytes, or nil on a
/// signing failure (degenerate key).
func jwsFlattenedES256(protectedJSON: [UInt8],
                       payloadJSON: [UInt8],
                       priv32: [UInt8]) -> [UInt8]? {
    let p = base64urlEncode(protectedJSON)
    let pl = base64urlEncode(payloadJSON)
    var signingInput = p
    signingInput.append(0x2E)   // '.'
    signingInput += pl
    let h = sha256Bytes(signingInput)

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

    var sig = r
    sig += s                          // JWS ES256 signature is raw r‖s, not DER
    var o = asc("{\"protected\":\"")
    o += p
    o += asc("\",\"payload\":\"")
    o += pl
    o += asc("\",\"signature\":\"")
    o += base64urlEncode(sig)
    o += asc("\"}")
    return o
}
