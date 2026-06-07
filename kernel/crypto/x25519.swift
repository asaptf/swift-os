// SPDX-License-Identifier: Apache-2.0
// x25519.swift — X25519 ECDH on Curve25519 (RFC 7748 §5).
//
// Pure Swift: no Foundation, no MMIO, no heap allocation, no syscalls — same
// purity discipline as kernel/crypto/chacha20poly1305.swift and sha256.swift, so
// it compiles BOTH for the host unit test (tests/x25519_test.swift) and into a
// userland ELF (it is linked into /bin/tlsget to compute the TLS 1.3 key share).
//
// The field is GF(p), p = 2^255 - 19. We represent a field element as FIVE limbs
// of radix 2^51 held in UInt64 (the public-domain "curve25519-donna-c64" layout).
// Partial products are accumulated in UInt128 — Swift's native 128-bit integer,
// which LLVM lowers to aarch64 mul/umulh with no compiler-rt helper, so the file
// stays portable and allocator-free under the kernel's +strict-align build. This
// radix-2^51 representation is markedly simpler to get right than the signed
// radix-2^25.5 ref10 layout, which is why it is used here.
//
// The scalar multiplication is the Montgomery ladder of RFC 7748 §5: clamp the
// scalar, iterate bits 254..0, conditionally swap with a constant-time mask, run
// the differential add-and-double, then recover the affine x = X/Z via a field
// inverse (x^(p-2)) using the standard addition chain. Validated against the two
// RFC 7748 §5.2 scalar-mult vectors before any TLS code was written.

// Byte accessors, kept local so the module is self-contained (the host test
// compiles it alone, mirroring chacha20poly1305.swift / sha256.swift).
@inline(__always) private func xb8(_ p: UnsafeRawPointer, _ off: Int) -> UInt8 {
    p.load(fromByteOffset: off, as: UInt8.self)
}
@inline(__always) private func xb8set(_ p: UnsafeMutableRawPointer, _ off: Int, _ v: UInt8) {
    p.storeBytes(of: v, toByteOffset: off, as: UInt8.self)
}

// A field element: five 51-bit limbs h[0..4], little-endian (h[0] is the least
// significant). Carried as a tuple so it lives on the stack with no allocation.
private typealias Fe = (UInt64, UInt64, UInt64, UInt64, UInt64)

private let mask51: UInt64 = 0x7_ffff_ffff_ffff   // 2^51 - 1

// MARK: - Field arithmetic (radix 2^51, GF(2^255 - 19))

/// Decode 32 little-endian bytes at `s` into a field element, dropping bit 255
/// (the high bit is ignored on decode per RFC 7748 §5). Packs the 256-bit
/// little-endian integer into five 51-bit limbs.
private func feFromBytes(_ s: UnsafeRawPointer) -> Fe {
    @inline(__always) func ld8(_ n: Int) -> UInt64 {
        var v: UInt64 = 0
        var i = 0
        while i < 8 { v |= UInt64(xb8(s, n + i)) << (UInt64(i) &* 8); i += 1 }
        return v
    }
    // Read overlapping 64-bit windows and slice out 51-bit limbs.
    let w0 = ld8(0)            // bytes  0..7
    let w1 = ld8(6)            // bytes  6..13
    let w2 = ld8(12)           // bytes 12..19
    let w3 = ld8(19)           // bytes 19..26
    let w4 = ld8(24)           // bytes 24..31
    let h0 = w0 & mask51
    let h1 = (w1 >> 3) & mask51
    let h2 = (w2 >> 6) & mask51
    let h3 = (w3 >> 1) & mask51
    let h4 = (w4 >> 12) & mask51        // bit 255 lands at (12+51)=63 of w4, dropped by mask
    return (h0, h1, h2, h3, h4)
}

/// Fully reduce `h` mod p and serialize it as 32 little-endian bytes to `out`.
private func feToBytes(_ h: Fe, _ out: UnsafeMutableRawPointer) {
    // First carry-propagate so each limb is < 2^51.
    var h0 = h.0, h1 = h.1, h2 = h.2, h3 = h.3, h4 = h.4
    @inline(__always) func carry() {
        let c0 = h0 >> 51; h0 &= mask51; h1 &+= c0
        let c1 = h1 >> 51; h1 &= mask51; h2 &+= c1
        let c2 = h2 >> 51; h2 &= mask51; h3 &+= c2
        let c3 = h3 >> 51; h3 &= mask51; h4 &+= c3
        let c4 = h4 >> 51; h4 &= mask51; h0 &+= c4 &* 19
    }
    carry(); carry()
    // Now h < 2^255 + small; conditionally subtract p = 2^255 - 19 if h >= p.
    // q = (h + 19) >> 255 is 1 iff h >= p. Compute h + 19, see if it overflows
    // past 2^255, and reduce.
    var q = (h0 &+ 19) >> 51
    q = (h1 &+ q) >> 51
    q = (h2 &+ q) >> 51
    q = (h3 &+ q) >> 51
    q = (h4 &+ q) >> 51
    // If q == 1, h >= p, so add 19 (mod 2^255) which subtracts p.
    h0 &+= 19 &* q
    let d0 = h0 >> 51; h0 &= mask51; h1 &+= d0
    let d1 = h1 >> 51; h1 &= mask51; h2 &+= d1
    let d2 = h2 >> 51; h2 &= mask51; h3 &+= d2
    let d3 = h3 >> 51; h3 &= mask51; h4 &+= d3
    h4 &= mask51   // clears the 2^255 bit that q's addition produced

    // Pack five 51-bit limbs into 32 bytes (little-endian 255-bit integer).
    let t0 = h0 | (h1 << 51)
    let t1 = (h1 >> 13) | (h2 << 38)
    let t2 = (h2 >> 26) | (h3 << 25)
    let t3 = (h3 >> 39) | (h4 << 12)
    @inline(__always) func st8(_ v: UInt64, _ n: Int) {
        var i = 0
        while i < 8 { xb8set(out, n + i, UInt8((v >> (UInt64(i) &* 8)) & 0xFF)); i += 1 }
    }
    st8(t0, 0); st8(t1, 8); st8(t2, 16); st8(t3, 24)
}

@inline(__always) private func feAdd(_ a: Fe, _ b: Fe) -> Fe {
    (a.0 &+ b.0, a.1 &+ b.1, a.2 &+ b.2, a.3 &+ b.3, a.4 &+ b.4)
}

/// Subtraction: add 2*p to keep limbs positive, then subtract. 2*p per limb is
/// (2^52 - 38, 2^52 - 2, 2^52 - 2, 2^52 - 2, 2^52 - 2). Inputs must be < 2^54 or
/// so (they are, right after a multiply/carry), so no underflow.
@inline(__always) private func feSub(_ a: Fe, _ b: Fe) -> Fe {
    let two52 = UInt64(1) << 52
    return (a.0 &+ (two52 &- 38) &- b.0,
            a.1 &+ (two52 &- 2)  &- b.1,
            a.2 &+ (two52 &- 2)  &- b.2,
            a.3 &+ (two52 &- 2)  &- b.3,
            a.4 &+ (two52 &- 2)  &- b.4)
}

/// Field multiply with reduction mod 2^255 - 19 (schoolbook 5x5 with the
/// 2^255 ≡ 19 folding, donna-c64 style). Accumulates in UInt128.
private func feMul(_ a: Fe, _ b: Fe) -> Fe {
    let a0 = UInt128(a.0), a1 = UInt128(a.1), a2 = UInt128(a.2)
    let a3 = UInt128(a.3), a4 = UInt128(a.4)
    let b0 = b.0, b1 = b.1, b2 = b.2, b3 = b.3, b4 = b.4
    // Pre-multiply the wrapped (high) b-limbs by 19.
    let b1_19 = UInt128(b1 &* 19)
    let b2_19 = UInt128(b2 &* 19)
    let b3_19 = UInt128(b3 &* 19)
    let b4_19 = UInt128(b4 &* 19)
    let B0 = UInt128(b0), B1 = UInt128(b1), B2 = UInt128(b2), B3 = UInt128(b3), B4 = UInt128(b4)

    let r0 = a0 &* B0 &+ a1 &* b4_19 &+ a2 &* b3_19 &+ a3 &* b2_19 &+ a4 &* b1_19
    var r1 = a0 &* B1 &+ a1 &* B0    &+ a2 &* b4_19 &+ a3 &* b3_19 &+ a4 &* b2_19
    var r2 = a0 &* B2 &+ a1 &* B1    &+ a2 &* B0    &+ a3 &* b4_19 &+ a4 &* b3_19
    var r3 = a0 &* B3 &+ a1 &* B2    &+ a2 &* B1    &+ a3 &* B0    &+ a4 &* b4_19
    var r4 = a0 &* B4 &+ a1 &* B3    &+ a2 &* B2    &+ a3 &* B1    &+ a4 &* B0

    // Carry-reduce the 128-bit accumulators down to 51-bit limbs.
    let m51 = UInt128(mask51)
    var c: UInt128
    c = r0 >> 51; var h0 = UInt64(r0 & m51); r1 &+= c
    c = r1 >> 51; var h1 = UInt64(r1 & m51); r2 &+= c
    c = r2 >> 51; let h2 = UInt64(r2 & m51); r3 &+= c
    c = r3 >> 51; let h3 = UInt64(r3 & m51); r4 &+= c
    c = r4 >> 51; let h4 = UInt64(r4 & m51); h0 &+= UInt64(c) &* 19
    // One more short carry chain: h0 may now exceed 2^51 (it absorbed c*19), so
    // its carry must propagate into h1. h1 then stays < 2^51, and h2..h4 are
    // already < 2^51, so no further propagation is needed.
    let c0 = h0 >> 51; h0 &= mask51; h1 &+= c0
    return (h0, h1, h2, h3, h4)
}

@inline(__always) private func feSquare(_ a: Fe) -> Fe { feMul(a, a) }

/// Multiply by the small constant a24 = 121665 (RFC 7748: (A-2)/4 for Curve25519).
private func feMul121665(_ a: Fe) -> Fe {
    let k = UInt128(121665)
    let r0 = UInt128(a.0) &* k
    var r1 = UInt128(a.1) &* k
    var r2 = UInt128(a.2) &* k
    var r3 = UInt128(a.3) &* k
    var r4 = UInt128(a.4) &* k
    let m51 = UInt128(mask51)
    var c: UInt128
    c = r0 >> 51; var h0 = UInt64(r0 & m51); r1 &+= c
    c = r1 >> 51; var h1 = UInt64(r1 & m51); r2 &+= c
    c = r2 >> 51; let h2 = UInt64(r2 & m51); r3 &+= c
    c = r3 >> 51; let h3 = UInt64(r3 & m51); r4 &+= c
    c = r4 >> 51; let h4 = UInt64(r4 & m51); h0 &+= UInt64(c) &* 19
    let c0 = h0 >> 51; h0 &= mask51; h1 &+= c0
    return (h0, h1, h2, h3, h4)
}

/// Field inverse: z^(p-2) mod p, p-2 = 2^255 - 21. Uses the standard Curve25519
/// addition chain (ref10 fe_invert), ~254 squarings + 11 multiplies.
private func feInvert(_ z: Fe) -> Fe {
    let z2 = feSquare(z)                       // 2
    var t = feSquare(z2); t = feSquare(t)      // 8
    let z9 = feMul(t, z)                        // 9
    let z11 = feMul(z9, z2)                     // 11
    let z2_5_0 = feMul(feSquare(z11), z9)       // 2^5 - 2^0 = 31

    var z2_10_0 = feSquare(z2_5_0)
    for _ in 0..<4 { z2_10_0 = feSquare(z2_10_0) }
    z2_10_0 = feMul(z2_10_0, z2_5_0)            // 2^10 - 2^0

    var z2_20_0 = feSquare(z2_10_0)
    for _ in 0..<9 { z2_20_0 = feSquare(z2_20_0) }
    z2_20_0 = feMul(z2_20_0, z2_10_0)           // 2^20 - 2^0

    var t2 = feSquare(z2_20_0)
    for _ in 0..<19 { t2 = feSquare(t2) }
    let z2_40_0 = feMul(t2, z2_20_0)            // 2^40 - 2^0

    var z2_50_0 = feSquare(z2_40_0)
    for _ in 0..<9 { z2_50_0 = feSquare(z2_50_0) }
    z2_50_0 = feMul(z2_50_0, z2_10_0)           // 2^50 - 2^0

    var z2_100_0 = feSquare(z2_50_0)
    for _ in 0..<49 { z2_100_0 = feSquare(z2_100_0) }
    z2_100_0 = feMul(z2_100_0, z2_50_0)         // 2^100 - 2^0

    var t3 = feSquare(z2_100_0)
    for _ in 0..<99 { t3 = feSquare(t3) }
    let z2_200_0 = feMul(t3, z2_100_0)          // 2^200 - 2^0

    var z2_250_0 = feSquare(z2_200_0)
    for _ in 0..<49 { z2_250_0 = feSquare(z2_250_0) }
    z2_250_0 = feMul(z2_250_0, z2_50_0)         // 2^250 - 2^0

    var r = feSquare(z2_250_0)
    for _ in 0..<4 { r = feSquare(r) }          // 2^255 - 2^5
    return feMul(r, z11)                        // 2^255 - 21
}

/// Constant-time conditional swap of `a` and `b` when `swap` == 1 (else no-op).
@inline(__always) private func cswap(_ swap: UInt64, _ a: inout Fe, _ b: inout Fe) {
    // mask is all-ones when swap==1, all-zeros when swap==0.
    let m = 0 &- swap
    @inline(__always) func sw(_ x: inout UInt64, _ y: inout UInt64) {
        let d = m & (x ^ y); x ^= d; y ^= d
    }
    sw(&a.0, &b.0); sw(&a.1, &b.1); sw(&a.2, &b.2); sw(&a.3, &b.3); sw(&a.4, &b.4)
}

// MARK: - X25519 (RFC 7748 §5)

/// X25519 scalar multiplication: out = scalar * point on Curve25519.
/// `scalarIn` (32 bytes) and `pointIn` (32-byte u-coordinate) are little-endian;
/// `out` receives the 32-byte little-endian u-coordinate of the result. Constant
/// -time in the scalar. This is the single primitive TLS 1.3's X25519 key share
/// needs: a public key is `x25519(sk, basepoint)`; the shared secret is
/// `x25519(sk, peerPub)`.
func x25519(_ scalarIn: UnsafeRawPointer, _ pointIn: UnsafeRawPointer,
            _ out: UnsafeMutableRawPointer) {
    // 1. Clamp the scalar (RFC 7748 §5: clear bits 0,1,2 of byte 0; clear bit 7
    //    and set bit 6 of byte 31).
    var e = (UInt64(0), UInt64(0), UInt64(0), UInt64(0))   // 32-byte clamped scalar
    withUnsafeMutableBytes(of: &e) { eb in
        let ep = eb.baseAddress!
        for i in 0..<32 { xb8set(ep, i, xb8(scalarIn, i)) }
        xb8set(ep, 0, xb8(ep, 0) & 248)
        xb8set(ep, 31, (xb8(ep, 31) & 127) | 64)

        // 2. Decode the base u-coordinate.
        let x1 = feFromBytes(pointIn)

        // 3. Montgomery ladder. (x2,z2) = point-at-infinity (1,0); (x3,z3)=(x1,1).
        var x2: Fe = (1, 0, 0, 0, 0)
        var z2: Fe = (0, 0, 0, 0, 0)
        var x3: Fe = x1
        var z3: Fe = (1, 0, 0, 0, 0)
        var swap: UInt64 = 0

        var pos = 254
        while pos >= 0 {
            let bit = (UInt64(xb8(ep, pos >> 3)) >> (UInt64(pos) & 7)) & 1
            swap ^= bit
            cswap(swap, &x2, &x3)
            cswap(swap, &z2, &z3)
            swap = bit

            // Differential add-and-double (RFC 7748 §5 / Montgomery).
            let a  = feAdd(x2, z2)
            let aa = feSquare(a)
            let b  = feSub(x2, z2)
            let bb = feSquare(b)
            let e_ = feSub(aa, bb)
            let c  = feAdd(x3, z3)
            let d  = feSub(x3, z3)
            let da = feMul(d, a)
            let cb = feMul(c, b)
            let x3p = feSquare(feAdd(da, cb))
            let z3p = feMul(x1, feSquare(feSub(da, cb)))
            x3 = x3p
            z3 = z3p
            x2 = feMul(aa, bb)
            // z_2 = E * (AA + a24 * E)   — RFC 7748 §5 (note: AA, not BB).
            z2 = feMul(e_, feAdd(aa, feMul121665(e_)))

            pos -= 1
        }
        // Undo the final pending swap.
        cswap(swap, &x2, &x3)
        cswap(swap, &z2, &z3)

        // 4. Affine result x2 / z2 = x2 * z2^(p-2).
        let result = feMul(x2, feInvert(z2))
        feToBytes(result, out)
    }
}
