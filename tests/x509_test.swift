// SPDX-License-Identifier: Apache-2.0
//
// x509_test.swift — host unit test for userland/lib/x509.swift (V0: the X.509
// DER reader). Parses two openssl-generated fixtures (a P-256 CA and a leaf it
// signed, with two SANs and a 2026→2126 validity window that exercises both
// UTCTime and GeneralizedTime) and checks every extracted field against what
// `openssl x509 -text` reported, including the issuer==subject chain link.

import Foundation

@main
struct X509Test {
    static var failed = false
    static func check(_ c: Bool, _ m: String) {
        if !c { FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)); failed = true }
    }
    static func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    static func b64d(_ s: String) -> [UInt8] {
        func v(_ c: UInt8) -> Int {
            if c >= 65 && c <= 90 { return Int(c - 65) }
            if c >= 97 && c <= 122 { return Int(c - 97 + 26) }
            if c >= 48 && c <= 57 { return Int(c - 48 + 52) }
            if c == 43 { return 62 }; if c == 47 { return 63 }; return -1
        }
        var acc = 0, bits = 0, out = [UInt8]()
        for c in s.utf8 { if c == 61 { break }; let d = v(c); if d < 0 { continue }
            acc = (acc << 6) | d; bits += 6
            if bits >= 8 { bits -= 8; out.append(UInt8((acc >> bits) & 0xff)) } }
        return out
    }

    static func contains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        if needle.isEmpty || needle.count > hay.count { return needle.isEmpty }
        var i = 0
        while i + needle.count <= hay.count {
            var j = 0
            while j < needle.count && hay[i + j] == needle[j] { j += 1 }
            if j == needle.count { return true }
            i += 1
        }
        return false
    }

    // openssl-generated fixtures (P-256). leaf is signed by ca; see the test header.
    static let LEAF_B64 = "MIIBrDCCAVOgAwIBAgIUOEQrJemUPH9qhLcmZHKYlSiZc7QwCgYIKoZIzj0EAwIwGjEYMBYGA1UEAwwPU3dpZnRPUyBUZXN0IENBMCAXDTI2MDYxNzEzMTk0OFoYDzIxMjYwNTI0MTMxOTQ4WjAXMRUwEwYDVQQDDAxzaXRlLmV4YW1wbGUwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQNuCe3Un409foKM3WDzIPH8atQ56WxrwYTipFdLN547s/y7CZITkwX2xJ6yiYu7iDNMxUAPO/WGZ5w9Od9nttTo3gwdjAJBgNVHRMEAjAAMCkGA1UdEQQiMCCCDHNpdGUuZXhhbXBsZYIQd3d3LnNpdGUuZXhhbXBsZTAdBgNVHQ4EFgQUurdCi4PloX/LPfOSyTSZlgwlVl0wHwYDVR0jBBgwFoAUstY09DjYBaguWFbrJWtz6Y6XTPIwCgYIKoZIzj0EAwIDRwAwRAIgI720Exch3spkkPPvD0Nv7qpyo49vU/Q1VN2ih0+BEEkCIH7eXbOiYkuKUIou44ey7/aejgvoFUPll3bwSfKk6K51"
    static let CA_B64 = "MIIBjDCCATGgAwIBAgIUS9nX08rUJxLEEq3ZUSmErvoBTrUwCgYIKoZIzj0EAwIwGjEYMBYGA1UEAwwPU3dpZnRPUyBUZXN0IENBMCAXDTI2MDYxNzEzMTk0OFoYDzIxMjYwNTI0MTMxOTQ4WjAaMRgwFgYDVQQDDA9Td2lmdE9TIFRlc3QgQ0EwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAARSzWLEZqdSJdrPzOzQp4Yzb1RqIWPsz6VT6c5Fg3CB+mNAvMuFis0OXHyqH4NhFuX+rbkfl0nRODtZJOCVAwwXo1MwUTAdBgNVHQ4EFgQUstY09DjYBaguWFbrJWtz6Y6XTPIwHwYDVR0jBBgwFoAUstY09DjYBaguWFbrJWtz6Y6XTPIwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNJADBGAiEAqvEpOjUNmTXRZygu9IbMeUEiE1whTqRdko4JgWiPdB0CIQCaLFJFCcolHDuMcPiGJCFD8+Q0dP4f1g3WJeW/St9cjw=="

    static func main() {
        let ecPubKeyOID: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]

        guard let leaf = parseX509(b64d(LEAF_B64)) else {
            FileHandle.standardError.write(Data("FAIL: leaf did not parse\n".utf8)); exit(1)
        }
        guard let ca = parseX509(b64d(CA_B64)) else {
            FileHandle.standardError.write(Data("FAIL: CA did not parse\n".utf8)); exit(1)
        }

        // ---- leaf fields ----
        check(leaf.dnsNames.count == 2, "leaf 2 SANs (got \(leaf.dnsNames.count))")
        check(leaf.dnsNames.first == "site.example", "leaf SAN[0] (got \(leaf.dnsNames.first ?? "nil"))")
        check(leaf.dnsNames.count > 1 && leaf.dnsNames[1] == "www.site.example", "leaf SAN[1]")
        check(leaf.isCA == false, "leaf is not a CA")
        check(leaf.spkiAlgOID == ecPubKeyOID, "leaf SPKI alg is id-ecPublicKey")
        check(leaf.spkiKey.count == 65 && leaf.spkiKey.first == 0x04, "leaf SPKI is an uncompressed point")
        check(leaf.notBefore == 20260617131948, "leaf notBefore (UTCTime) (got \(leaf.notBefore))")
        check(leaf.notAfter == 21260524131948, "leaf notAfter (GeneralizedTime) (got \(leaf.notAfter))")
        check(contains(leaf.subject, bytes("site.example")), "leaf subject carries CN")
        check(contains(leaf.issuer, bytes("SwiftOS Test CA")), "leaf issuer carries CA CN")
        check(leaf.tbs.first == 0x30, "leaf TBS is a SEQUENCE")
        check(!leaf.signature.isEmpty, "leaf signature present")

        // ---- CA fields + chain link ----
        check(ca.isCA == true, "CA basicConstraints CA:TRUE")
        check(ca.subject == leaf.issuer, "leaf.issuer == ca.subject (chain link)")
        check(ca.subject == ca.issuer, "CA is self-signed (subject == issuer)")

        if failed {
            FileHandle.standardError.write(Data("x509_test: FAILED\n".utf8)); exit(1)
        }
        print("x509_test: all fields OK")
    }
}
