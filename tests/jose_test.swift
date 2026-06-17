// SPDX-License-Identifier: Apache-2.0
//
// jose_test.swift — host unit test for userland/lib/jose.swift and
// userland/lib/asn1.swift (the ACME JOSE/ASN.1 layer, A1).
//
// Pins base64url to RFC 4648 §5 examples, the EC JWK + RFC 7638 thumbprint to
// values precomputed for the RFC 6979 §A.2.5 public key, the flattened JWS to a
// sign→verify round-trip, and the PKCS#10 CSR to determinism + a valid self-
// signature over its request info plus structural checks (SPKI and SAN present).

import Foundation

@main
struct JoseTest {
    static var failed = false

    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failed = true
        }
    }

    static func hex(_ s: String) -> [UInt8] {
        let c = Array(s.utf8); var out = [UInt8](); var i = 0
        func nib(_ b: UInt8) -> UInt8 {
            if b >= 0x30 && b <= 0x39 { return b - 0x30 }
            if b >= 0x61 && b <= 0x66 { return b - 0x61 + 10 }
            return b - 0x41 + 10
        }
        while i + 1 < c.count { out.append((nib(c[i]) << 4) | nib(c[i + 1])); i += 2 }
        return out
    }

    static func str(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
    static func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// Is `needle` a contiguous subsequence of `haystack`?
    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        if needle.isEmpty || needle.count > haystack.count { return needle.isEmpty }
        var i = 0
        while i + needle.count <= haystack.count {
            var j = 0
            while j < needle.count && haystack[i + j] == needle[j] { j += 1 }
            if j == needle.count { return true }
            i += 1
        }
        return false
    }

    static func sha(_ data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { dp in out.withUnsafeMutableBytes { op in
            sha256(dp.baseAddress!, data.count, op.baseAddress!) } }
        return out
    }

    static func verifySig(_ px: [UInt8], _ py: [UInt8], _ h: [UInt8],
                          _ r: [UInt8], _ s: [UInt8]) -> Bool {
        var ok = false
        px.withUnsafeBytes { xp in py.withUnsafeBytes { yp in h.withUnsafeBytes { hp in
        r.withUnsafeBytes { rp in s.withUnsafeBytes { sp in
            ok = p256Verify(xp.baseAddress!, yp.baseAddress!, hp.baseAddress!,
                            rp.baseAddress!, sp.baseAddress!) } } } } }
        return ok
    }

    static func main() {
        // RFC 6979 §A.2.5 public key.
        let pubX = hex("60FED4BA255A9D31C961EB74C6356D68C049B8923B61FA6CE669622E60F29FB6")
        let pubY = hex("7903FE1008B8BC99A41AE9E95628BC64F2F1B20C2D7E9F5177A3C294D4462299")
        let priv = hex("C9AFA9D845BA75166B5C215767B1D6934E50C3DB36E89B127B8A622B120F6721")

        // ---- 1. base64url (RFC 4648 §5) -----------------------------------
        check(str(base64urlEncode([])) == "", "b64u empty")
        check(str(base64urlEncode(bytes("foobar"))) == "Zm9vYmFy", "b64u foobar")
        check(str(base64urlEncode(hex("14fb9c03d97e"))) == "FPucA9l-", "b64u url-safe chars")
        check(base64urlDecode(bytes("Zm9vYmFy"))! == bytes("foobar"), "b64u decode")
        check(base64urlDecode(bytes("FPucA9l-"))! == hex("14fb9c03d97e"), "b64u decode url-safe")

        // ---- 2. EC JWK + RFC 7638 thumbprint ------------------------------
        let jwk = str(jwkES256JSON(pubX, pubY))
        let wantJWK = "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"YP7UuiVanTHJYet0xjVtaMBJuJI7Yfps5mliLmDyn7Y\",\"y\":\"eQP-EAi4vJmkGunpVii8ZPLxsgwtfp9Rd6PClNRGIpk\"}"
        check(jwk == wantJWK, "canonical JWK (got \(jwk))")
        let tp = str(base64urlEncode(jwkThumbprint(pubX, pubY)))
        check(tp == "DOvxvJiAdIqVWIkFt5hDtCunXLF0BV4-JGv4f-ALSm0", "RFC 7638 thumbprint (got \(tp))")
        // key authorization = token "." b64u(thumbprint)
        let ka = str(acmeKeyAuthorization(bytes("tok123"), pubX, pubY))
        check(ka == "tok123.DOvxvJiAdIqVWIkFt5hDtCunXLF0BV4-JGv4f-ALSm0", "key authorization (got \(ka))")

        // ---- 3. flattened JWS ES256 round-trip ----------------------------
        let prot = bytes("{\"alg\":\"ES256\",\"nonce\":\"abc\",\"url\":\"https://acme/new\"}")
        let payload = bytes("{\"termsOfServiceAgreed\":true}")
        let jws = jwsFlattenedES256(protectedJSON: prot, payloadJSON: payload, priv32: priv)!
        let jwsStr = str(jws)
        check(jwsStr.hasPrefix("{\"protected\":\""), "JWS shape")
        check(jwsStr.contains("\"payload\":\"") && jwsStr.contains("\"signature\":\""), "JWS members")
        // Recompute the signing input, extract r‖s, and verify with p256.
        let p64 = str(base64urlEncode(prot))
        let pl64 = str(base64urlEncode(payload))
        let signingInput = bytes(p64 + "." + pl64)
        let sigField = field(jwsStr, "signature")
        let sigRaw = base64urlDecode(bytes(sigField))!
        check(sigRaw.count == 64, "JWS signature is raw r‖s (64 bytes)")
        let r = Array(sigRaw[0..<32]); let s = Array(sigRaw[32..<64])
        check(verifySig(pubX, pubY, sha(signingInput), r, s), "JWS ES256 verifies")

        // ---- 4. PKCS#10 CSR ------------------------------------------------
        let names = [bytes("example.com"), bytes("www.example.com")]
        let csr = acmeCSR(dnsNames: names, pubX: pubX, pubY: pubY, priv32: priv)!
        // Deterministic: rebuild and compare.
        let csr2 = acmeCSR(dnsNames: names, pubX: pubX, pubY: pubY, priv32: priv)!
        check(csr == csr2, "CSR is deterministic")
        check(csr[0] == 0x30, "CSR is a SEQUENCE")
        // Embeds the SPKI and both dNSNames.
        check(contains(csr, spkiP256(pubX, pubY)), "CSR embeds the P-256 SPKI")
        check(contains(csr, bytes("example.com")), "CSR embeds example.com")
        check(contains(csr, bytes("www.example.com")), "CSR embeds www.example.com")
        // The self-signature over the request info is valid.
        let tbs = csrInfoDER(dnsNames: names, pubX: pubX, pubY: pubY)
        check(contains(csr, tbs), "CSR contains its request info")
        var cr = [UInt8](repeating: 0, count: 32); var cs = [UInt8](repeating: 0, count: 32)
        var ok = false
        priv.withUnsafeBytes { dp in sha(tbs).withUnsafeBytes { hp in
        cr.withUnsafeMutableBytes { rp in cs.withUnsafeMutableBytes { sp in
            ok = p256SignDeterministic(dp.baseAddress!, hp.baseAddress!,
                                       rp.baseAddress!, sp.baseAddress!) } } } }
        check(ok && verifySig(pubX, pubY, sha(tbs), cr, cs), "CSR self-signature valid")
        check(contains(csr, derBitString(ecdsaSigValueDER(cr, cs))), "CSR carries the DER signature")

        // ---- 5. standard base64 + EC private key PEM ----------------------
        check(str(base64StdEncode(bytes("foobar"))) == "Zm9vYmFy", "b64std foobar")
        check(str(base64StdEncode(bytes("fo"))) == "Zm8=", "b64std pad1")
        check(str(base64StdEncode(bytes("f"))) == "Zg==", "b64std pad2")
        let pem = str(ecPrivateKeyPEM(priv32: priv, pubX: pubX, pubY: pubY))
        check(pem.hasPrefix("-----BEGIN EC PRIVATE KEY-----\n"), "EC key PEM header")
        check(pem.hasSuffix("-----END EC PRIVATE KEY-----\n"), "EC key PEM footer")
        let kder = ecPrivateKeyDER(priv32: priv, pubX: pubX, pubY: pubY)
        check(kder[0] == 0x30, "EC key DER is a SEQUENCE")
        check(contains(kder, derTLV(0x04, priv)), "EC key DER carries the scalar")
        var point: [UInt8] = [0x04]; point += pubX; point += pubY
        check(contains(kder, point), "EC key DER carries the public point")

        // ---- 6. PEM certificate reader round-trip ----
        let der1 = hex("3003010203"); let der2 = hex("300602010102017f")
        var pemBundle = pemWrap(der1, "CERTIFICATE")
        pemBundle += pemWrap(der2, "CERTIFICATE")
        let read = pemReadCertificates(pemBundle)
        check(read.count == 2, "pemReadCertificates found both blocks (got \(read.count))")
        check(read.first == der1 && read.count > 1 && read[1] == der2, "pemReadCertificates round-trips DER")

        if failed {
            FileHandle.standardError.write(Data("jose_test: FAILED\n".utf8))
            exit(1)
        }
        print("jose_test: all vectors OK")
    }

    /// Extract the string value of a top-level "name":"value" member.
    static func field(_ json: String, _ name: String) -> String {
        guard let r = json.range(of: "\"\(name)\":\"") else { return "" }
        let rest = json[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return "" }
        return String(rest[rest.startIndex..<end])
    }
}
