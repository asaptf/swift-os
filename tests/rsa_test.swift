// SPDX-License-Identifier: Apache-2.0
//
// rsa_test.swift — host unit test for userland/lib/rsa.swift (RSA PKCS#1 v1.5
// SHA-256 verification). Pinned to an openssl-produced RSA-2048 signature over
// a known message: accepts the valid signature and rejects a tampered message,
// a tampered signature, and a wrong exponent.

import Foundation

@main
struct RSATest {
    static var failed = false
    static func check(_ c: Bool, _ m: String) {
        if !c { FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)); failed = true }
    }
    static func hex(_ s: String) -> [UInt8] {
        let c = Array(s.utf8); var o = [UInt8](); var i = 0
        func n(_ b: UInt8) -> UInt8 {
            if b >= 0x30 && b <= 0x39 { return b - 0x30 }
            if b >= 0x61 && b <= 0x66 { return b - 0x61 + 10 }
            return b - 0x41 + 10
        }
        while i + 1 < c.count { o.append((n(c[i]) << 4) | n(c[i + 1])); i += 2 }
        return o
    }
    static func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    // openssl RSA-2048, `openssl dgst -sha256 -sign` over the message below.
    static let MOD = "D1A421CABFDF5ACE0EF9323B95CEC88C58B8E6828C3734461A191E502DCD1B266C57B26A782E4C0C7727A9E3F671156696BF9EA45588FBF54F78D9563DEA6C476FFB770B475A507E6571CAD55177AE05BBCF2D624CE03C0606793C67663CDA7F3C9E8E3B08167EF3AC377FE8AF2599B2BA7C7A25DB27765F6D7D43D0C62F58D948F6AADD402B35CA5F388861250AECA8F7A60DA26F906E3E403C805A84411CA1995DC57B32AB0F5DA6B673D0A53E44231D1B22CE8B270DF55BCBD3F04FBB39A8AACA56DA9B4B3AF4EB28048B674714F19AED931789E3B15D795BF6313593C5FB5A5D0F2197234CE8B9F1DE9DDF6CEFA936FF5C8EE71DA81A3FB599DD6AA4C42F"
    static let SIG = "61104194e4d9a3949b7cbf175799c4a87db4ef215baa354b5d852eea56cc5e8d9117eceedbafd7f3d3d7a3103b54db33eeeb610bd834366f861dc802ea625d5afd38759663111a41c99c91abd540d910ba35bec14118553617b1361d2e0b25382adf047579b3da52a53d4b2aaac808ce9fc42bc7c728151b120af2d09e4651304b4a462eb57d13a902c86cfc3cdb1b50f5e70415849db1486646f5c1f2be523abd2769572bf303b8120a12218393210c44e42d26327778c9554dfec53fe87a72964e2ad2d9a33881592c8746f15492103f8f98722b57e6c8f302cb16edefcfb3130fe13f2d7a765fad4d460654941a215ff219b0a74b77a02edd188e3c0eaebc"
    static let MSG = "hello swiftos acme"

    static func main() {
        let n = hex(MOD)
        let e = hex("010001")          // 65537
        let sig = hex(SIG)

        check(rsaVerifyPKCS1SHA256(modulusBE: n, exponentBE: e, message: bytes(MSG), signatureBE: sig),
              "valid RSA-2048 PKCS#1v1.5 SHA-256 signature accepted")

        check(!rsaVerifyPKCS1SHA256(modulusBE: n, exponentBE: e, message: bytes("hello swiftos acmf"), signatureBE: sig),
              "tampered message rejected")

        var badSig = sig; badSig[100] ^= 0x01
        check(!rsaVerifyPKCS1SHA256(modulusBE: n, exponentBE: e, message: bytes(MSG), signatureBE: badSig),
              "tampered signature rejected")

        check(!rsaVerifyPKCS1SHA256(modulusBE: n, exponentBE: hex("03"), message: bytes(MSG), signatureBE: sig),
              "wrong exponent rejected")

        if failed {
            FileHandle.standardError.write(Data("rsa_test: FAILED\n".utf8)); exit(1)
        }
        print("rsa_test: all vectors OK")
    }
}
