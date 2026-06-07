// x25519_test.swift — host unit test for kernel/crypto/x25519.swift.
//
// Compiled with the host Swift toolchain against the same pure module a userland
// ELF links (no MMIO/syscalls/heap-per-op), then run with no arguments. It checks
// X25519 against the RFC 7748 §5.2 scalar-multiplication vectors (both published
// inputs), the iterated-ladder vectors (1 and 1000 iterations), and an ECDH
// round-trip with the §6.1 Alice/Bob private keys. Mirrors tests/hkdf_test.swift
// and tests/crypto_test.swift in style (the same check/hex/withBufs helpers).

import Foundation

@main
struct X25519Test {
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

    /// out = scalar * point, both 32-byte little-endian buffers.
    static func mul(_ scalar: [UInt8], _ point: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        scalar.withUnsafeBytes { sp in
            point.withUnsafeBytes { pp in
                out.withUnsafeMutableBytes { op in
                    x25519(sp.baseAddress!, pp.baseAddress!, op.baseAddress!)
                }
            }
        }
        return out
    }

    static func main() {
        // ---- 1. RFC 7748 §5.2 first scalar-mult vector --------------------
        let s1 = hex("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4")
        let u1 = hex("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c")
        let e1 = hex("c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552")
        let r1 = mul(s1, u1)
        check(r1 == e1, "RFC 7748 §5.2 vector 1 (got \(toHex(r1)))")

        // ---- 2. RFC 7748 §5.2 second scalar-mult vector -------------------
        let s2 = hex("4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d")
        let u2 = hex("e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493")
        let e2 = hex("95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957")
        let r2 = mul(s2, u2)
        check(r2 == e2, "RFC 7748 §5.2 vector 2 (got \(toHex(r2)))")

        // ---- 3. RFC 7748 §5.2 iterated test -------------------------------
        // Start k = u = 9 (the basepoint). After 1 iter, and after 1000 iters,
        // RFC 7748 publishes the expected k.
        var k = hex("0900000000000000000000000000000000000000000000000000000000000000")
        var u = k
        let after1    = hex("422c8e7a6227d7bca1350b3e2bb7279f7897b87bb6854b783c60e80311ae3079")
        let after1000 = hex("684cf59ba83309552800ef566f2f4d3c1c3887c49360e3875f2eb94d99532c51")
        for i in 1...1000 {
            let next = mul(k, u)
            u = k
            k = next
            if i == 1 { check(k == after1, "RFC 7748 §5.2 iterated, 1 iteration (got \(toHex(k)))") }
        }
        check(k == after1000, "RFC 7748 §5.2 iterated, 1000 iterations (got \(toHex(k)))")

        // ---- 4. RFC 7748 §6.1 ECDH round-trip -----------------------------
        // Alice/Bob private keys; derive public keys against the basepoint and
        // check the shared secret matches the published K.
        let base = hex("0900000000000000000000000000000000000000000000000000000000000000")
        let aPriv = hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
        let bPriv = hex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
        let aPubExp = hex("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
        let bPubExp = hex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
        let kExp    = hex("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")
        let aPub = mul(aPriv, base)
        let bPub = mul(bPriv, base)
        check(aPub == aPubExp, "RFC 7748 §6.1 Alice public key")
        check(bPub == bPubExp, "RFC 7748 §6.1 Bob public key")
        let kA = mul(aPriv, bPub)
        let kB = mul(bPriv, aPub)
        check(kA == kExp, "RFC 7748 §6.1 shared secret (Alice)")
        check(kB == kExp, "RFC 7748 §6.1 shared secret (Bob)")
        check(kA == kB, "RFC 7748 §6.1 shared secret agrees")

        if failed {
            FileHandle.standardError.write(Data("x25519_test: FAILURES\n".utf8))
            exit(1)
        }
        print("x25519_test: PASS (RFC 7748 §5.2 vectors + iterated + §6.1 ECDH)")
    }
}
