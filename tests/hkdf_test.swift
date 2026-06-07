// hkdf_test.swift — host unit test for kernel/crypto/sha256.swift.
//
// Compiled with the host Swift toolchain against the same pure module a userland
// ELF links (no MMIO/syscalls/heap-per-op), then run with no arguments. It checks
// SHA-256 against a FIPS 180-4 example, HMAC-SHA256 against an RFC 4231 vector,
// and HKDF-Extract/Expand against the RFC 5869 Appendix A SHA-256 test cases
// (1, 2, 3). Mirrors tests/crypto_test.swift's style and its check(_:_:) helper.

import Foundation

@main
struct HkdfTest {
    static var failed = false

    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failed = true
        }
    }

    /// Run `body` with raw pointers to fresh copies of the given byte arrays.
    static func withBufs(_ arrays: [[UInt8]],
                         _ body: ([UnsafeMutableRawPointer]) -> Void) {
        var bufs: [UnsafeMutableRawPointer] = []
        for a in arrays {
            let p = UnsafeMutableRawPointer.allocate(byteCount: max(1, a.count), alignment: 16)
            for i in 0..<a.count { p.storeBytes(of: a[i], toByteOffset: i, as: UInt8.self) }
            bufs.append(p)
        }
        body(bufs)
        for p in bufs { p.deallocate() }
    }

    static func bytesEqual(_ p: UnsafeRawPointer, _ expected: [UInt8]) -> Bool {
        for i in 0..<expected.count {
            if p.load(fromByteOffset: i, as: UInt8.self) != expected[i] { return false }
        }
        return true
    }

    /// Parse a contiguous hex string ("0a1b…") into bytes.
    static func hex(_ s: String) -> [UInt8] {
        let c = Array(s.utf8)
        var out = [UInt8]()
        var i = 0
        func nib(_ b: UInt8) -> UInt8 {
            if b >= 0x30 && b <= 0x39 { return b - 0x30 }
            if b >= 0x61 && b <= 0x66 { return b - 0x61 + 10 }
            return b - 0x41 + 10
        }
        while i + 1 < c.count {
            out.append((nib(c[i]) << 4) | nib(c[i + 1]))
            i += 2
        }
        return out
    }

    static func main() {
        // ---- 1. SHA-256 — FIPS 180-4 "abc" example -----------------------
        let abc: [UInt8] = Array("abc".utf8)
        let abcDigest = hex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        withBufs([abc, Array(repeating: 0, count: 32)]) { b in
            sha256(b[0], abc.count, b[1])
            check(bytesEqual(b[1], abcDigest), "SHA-256(\"abc\")")
        }
        // Empty-message digest (well-known constant).
        let emptyDigest = hex("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        withBufs([[], Array(repeating: 0, count: 32)]) { b in
            sha256(b[0], 0, b[1])
            check(bytesEqual(b[1], emptyDigest), "SHA-256(\"\")")
        }
        // Hex wrapper agrees with the raw digest for "abc".
        withBufs([abc, Array(repeating: 0, count: 64)]) { b in
            sha256Hex(b[0], abc.count, b[1])
            let want = Array("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad".utf8)
            check(bytesEqual(b[1], want), "sha256Hex(\"abc\")")
        }

        // ---- 2. HMAC-SHA256 — RFC 4231 Test Case 2 -----------------------
        // key = "Jefe", data = "what do ya want for nothing?".
        let hmKey: [UInt8] = Array("Jefe".utf8)
        let hmMsg: [UInt8] = Array("what do ya want for nothing?".utf8)
        let hmTag = hex("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        withBufs([hmKey, hmMsg, Array(repeating: 0, count: 32)]) { b in
            hmacSha256(b[0], hmKey.count, b[1], hmMsg.count, b[2])
            check(bytesEqual(b[2], hmTag), "HMAC-SHA256 RFC 4231 §4.3")
        }

        // ---- 3. HKDF-SHA256 — RFC 5869 Appendix A.1 (Test Case 1) --------
        let ikm1  = hex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")   // 22 bytes
        let salt1 = hex("000102030405060708090a0b0c")                       // 13 bytes
        let info1 = hex("f0f1f2f3f4f5f6f7f8f9")                             // 10 bytes
        let prk1  = hex("077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5")
        let okm1  = hex("3cb25f25faacd57a90434f64d0362f2a" +
                        "2d2d0a90cf1a5a4c5db02d56ecc4c5bf" +
                        "34007208d5b887185865")               // 42 bytes
        withBufs([salt1, ikm1, info1,
                  Array(repeating: 0, count: 32),     // prk out
                  Array(repeating: 0, count: 42)]) { b in
            hkdfExtract(salt: b[0], saltLen: salt1.count, ikm: b[1], ikmLen: ikm1.count, prkOut: b[3])
            check(bytesEqual(b[3], prk1), "HKDF RFC 5869 A.1 PRK")
            hkdfExpand(prk: b[3], info: b[2], infoLen: info1.count, out: b[4], outLen: 42)
            check(bytesEqual(b[4], okm1), "HKDF RFC 5869 A.1 OKM")
        }

        // ---- 4. HKDF-SHA256 — RFC 5869 Appendix A.2 (Test Case 2) --------
        // Longer inputs and a 82-byte OKM (exercises multi-block T() expansion).
        let ikm2 = hex("000102030405060708090a0b0c0d0e0f" +
                       "101112131415161718191a1b1c1d1e1f" +
                       "202122232425262728292a2b2c2d2e2f" +
                       "303132333435363738393a3b3c3d3e3f" +
                       "404142434445464748494a4b4c4d4e4f")   // 80 bytes
        let salt2 = hex("606162636465666768696a6b6c6d6e6f" +
                        "707172737475767778797a7b7c7d7e7f" +
                        "808182838485868788898a8b8c8d8e8f" +
                        "909192939495969798999a9b9c9d9e9f" +
                        "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf")  // 80 bytes
        let info2 = hex("b0b1b2b3b4b5b6b7b8b9babbbcbdbebf" +
                        "c0c1c2c3c4c5c6c7c8c9cacbcccdcecf" +
                        "d0d1d2d3d4d5d6d7d8d9dadbdcdddedf" +
                        "e0e1e2e3e4e5e6e7e8e9eaebecedeeef" +
                        "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")  // 80 bytes
        let prk2 = hex("06a6b88c5853361a06104c9ceb35b45cef760014904671014a193f40c15fc244")
        let okm2 = hex("b11e398dc80327a1c8e7f78c596a4934" +
                       "4f012eda2d4efad8a050cc4c19afa97c" +
                       "59045a99cac7827271cb41c65e590e09" +
                       "da3275600c2f09b8367793a9aca3db71" +
                       "cc30c58179ec3e87c14c01d5c1f3434f" +
                       "1d87")                                // 82 bytes
        withBufs([salt2, ikm2, info2,
                  Array(repeating: 0, count: 32),
                  Array(repeating: 0, count: 82)]) { b in
            hkdfExtract(salt: b[0], saltLen: salt2.count, ikm: b[1], ikmLen: ikm2.count, prkOut: b[3])
            check(bytesEqual(b[3], prk2), "HKDF RFC 5869 A.2 PRK")
            hkdfExpand(prk: b[3], info: b[2], infoLen: info2.count, out: b[4], outLen: 82)
            check(bytesEqual(b[4], okm2), "HKDF RFC 5869 A.2 OKM (multi-block)")
        }

        // ---- 5. HKDF-SHA256 — RFC 5869 Appendix A.3 (Test Case 3) --------
        // Zero-length salt and info.
        let ikm3 = hex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")
        let prk3 = hex("19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04")
        let okm3 = hex("8da4e775a563c18f715f802a063c5a31" +
                       "b8a11f5c5ee1879ec3454e5f3c738d2d" +
                       "9d201395faa4b61a96c8")               // 42 bytes
        withBufs([[], ikm3, [],
                  Array(repeating: 0, count: 32),
                  Array(repeating: 0, count: 42)]) { b in
            hkdfExtract(salt: b[0], saltLen: 0, ikm: b[1], ikmLen: ikm3.count, prkOut: b[3])
            check(bytesEqual(b[3], prk3), "HKDF RFC 5869 A.3 PRK (empty salt)")
            hkdfExpand(prk: b[3], info: b[2], infoLen: 0, out: b[4], outLen: 42)
            check(bytesEqual(b[4], okm3), "HKDF RFC 5869 A.3 OKM (empty info)")
        }

        if failed {
            FileHandle.standardError.write(Data("hkdf_test: FAILURES\n".utf8))
            exit(1)
        }
        print("hkdf_test: PASS (SHA-256 / HMAC-SHA256 / HKDF RFC 5869 vectors)")
    }
}
