// SPDX-License-Identifier: Apache-2.0
//
// p256_test.swift — host unit test for kernel/crypto/p256.swift.
//
// Compiled with the host Swift toolchain against the same pure module a userland
// ELF links (no MMIO/syscalls/heap-per-op), then run with no arguments. It pins
// P-256 ECDSA to the RFC 6979 §A.2.5 vectors (deterministic nonce, SHA-256):
// public-key derivation, the "sample" and "test" message signatures, and a
// sign→verify round-trip plus a tamper-rejection check. Mirrors the style of
// tests/x25519_test.swift and tests/hkdf_test.swift.

import Foundation

@main
struct P256Test {
    static var failed = false

    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failed = true
        }
    }

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

    static func toHex(_ b: [UInt8]) -> String {
        var s = ""
        for x in b {
            let hi = x >> 4, lo = x & 0xF
            s.append(Character(UnicodeScalar(hi < 10 ? 0x30 + hi : 0x61 + hi - 10)))
            s.append(Character(UnicodeScalar(lo < 10 ? 0x30 + lo : 0x61 + lo - 10)))
        }
        return s
    }

    static func sha(_ s: String) -> [UInt8] {
        let msg = Array(s.utf8)
        var out = [UInt8](repeating: 0, count: 32)
        msg.withUnsafeBytes { mp in
            out.withUnsafeMutableBytes { op in
                sha256(mp.baseAddress!, msg.count, op.baseAddress!)
            }
        }
        return out
    }

    static func derive(_ priv: [UInt8]) -> (x: [UInt8], y: [UInt8], ok: Bool) {
        var x = [UInt8](repeating: 0, count: 32)
        var y = [UInt8](repeating: 0, count: 32)
        var ok = false
        priv.withUnsafeBytes { pp in
            x.withUnsafeMutableBytes { xp in
                y.withUnsafeMutableBytes { yp in
                    ok = p256DerivePublic(pp.baseAddress!, xp.baseAddress!, yp.baseAddress!)
                }
            }
        }
        return (x, y, ok)
    }

    static func sign(_ priv: [UInt8], _ hash: [UInt8]) -> (r: [UInt8], s: [UInt8], ok: Bool) {
        var r = [UInt8](repeating: 0, count: 32)
        var s = [UInt8](repeating: 0, count: 32)
        var ok = false
        priv.withUnsafeBytes { pp in
            hash.withUnsafeBytes { hp in
                r.withUnsafeMutableBytes { rp in
                    s.withUnsafeMutableBytes { sp in
                        ok = p256SignDeterministic(pp.baseAddress!, hp.baseAddress!,
                                                   rp.baseAddress!, sp.baseAddress!)
                    }
                }
            }
        }
        return (r, s, ok)
    }

    static func verify(_ px: [UInt8], _ py: [UInt8], _ hash: [UInt8],
                       _ r: [UInt8], _ s: [UInt8]) -> Bool {
        var ok = false
        px.withUnsafeBytes { xp in py.withUnsafeBytes { yp in
        hash.withUnsafeBytes { hp in r.withUnsafeBytes { rp in s.withUnsafeBytes { sp in
            ok = p256Verify(xp.baseAddress!, yp.baseAddress!, hp.baseAddress!,
                            rp.baseAddress!, sp.baseAddress!)
        } } } } }
        return ok
    }

    static func main() {
        // RFC 6979 §A.2.5 key.
        let priv = hex("C9AFA9D845BA75166B5C215767B1D6934E50C3DB36E89B127B8A622B120F6721")
        let pubX = hex("60FED4BA255A9D31C961EB74C6356D68C049B8923B61FA6CE669622E60F29FB6")
        let pubY = hex("7903FE1008B8BC99A41AE9E95628BC64F2F1B20C2D7E9F5177A3C294D4462299")

        // ---- 1. public-key derivation -------------------------------------
        let d = derive(priv)
        check(d.ok, "derive ok")
        check(d.x == pubX, "pub X (got \(toHex(d.x)))")
        check(d.y == pubY, "pub Y (got \(toHex(d.y)))")

        // ---- 2. RFC 6979 §A.2.5, message "sample", SHA-256 ----------------
        let hSample = sha("sample")
        let rSample = hex("EFD48B2AACB6A8FD1140DD9CD45E81D69D2C877B56AAF991C34D0EA84EAF3716")
        let sSample = hex("F7CB1C942D657C41D436C7A1B6E29F65F3E900DBB9AFF4064DC4AB2F843ACDA8")
        let sigA = sign(priv, hSample)
        check(sigA.ok, "sign sample ok")
        check(sigA.r == rSample, "sample r (got \(toHex(sigA.r)))")
        check(sigA.s == sSample, "sample s (got \(toHex(sigA.s)))")
        check(verify(pubX, pubY, hSample, sigA.r, sigA.s), "verify sample")

        // ---- 3. RFC 6979 §A.2.5, message "test", SHA-256 ------------------
        let hTest = sha("test")
        let rTest = hex("F1ABB023518351CD71D881567B1EA663ED3EFCF6C5132B354F28D3B0B7D38367")
        let sTest = hex("019F4113742A2B14BD25926B49C649155F267E60D3814B4C0CC84250E46F0083")
        let sigB = sign(priv, hTest)
        check(sigB.ok, "sign test ok")
        check(sigB.r == rTest, "test r (got \(toHex(sigB.r)))")
        check(sigB.s == sTest, "test s (got \(toHex(sigB.s)))")
        check(verify(pubX, pubY, hTest, sigB.r, sigB.s), "verify test")

        // ---- 4. tamper rejection ------------------------------------------
        var badHash = hTest
        badHash[0] ^= 0x01
        check(!verify(pubX, pubY, badHash, sigB.r, sigB.s), "verify rejects tampered hash")

        if failed {
            FileHandle.standardError.write(Data("p256_test: FAILED\n".utf8))
            exit(1)
        }
        print("p256_test: all vectors OK")
    }
}
