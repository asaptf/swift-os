// SPDX-License-Identifier: Apache-2.0
//
// p256.swift — NIST P-256 (secp256r1) ECDSA in pure, Embedded-compatible Swift.
//
// The missing primitive for a native Swift ACME (RFC 8555 / Let's Encrypt)
// client: account-key signing, JWS ES256, and CSR self-signatures all need
// ECDSA over P-256, which the existing kernel/crypto modules (X25519, Ed25519)
// do not provide. Self-contained like its neighbours: no Foundation, no full
// stdlib, no heap-per-op (InlineArray stack storage and stack scratch only).
//
// Representation: a 256-bit integer is eight little-endian UInt32 limbs
// (limb 0 least significant). Field (mod p) and scalar (mod n) arithmetic both
// use Montgomery multiplication (SOS form) with the parameters R = 2^256,
// n0 = -m^{-1} mod 2^32 and R2 = 2^512 mod m derived at runtime (no hand-
// transcribed Montgomery constants). Points use Jacobian coordinates with the
// a = -3 doubling. Nonces are generated deterministically per RFC 6979 using
// the HMAC-SHA256 from sha256.swift, so signing needs no entropy source and is
// reproducible against the published RFC 6979 §A.2.5 vectors (the file is
// pinned to them by tests/p256_test.swift).
//
// Signing here is straightforward double-and-add — NOT hardened against timing
// side channels. That is acceptable for an ACME account key on a single-tenant
// host; a constant-time ladder is a later hardening track if P-256 ever guards
// multi-tenant secrets.

private typealias Big = InlineArray<8, UInt32>

// MARK: - curve constants (little-endian limbs, limb 0 = least significant)

// p = 2^256 - 2^224 + 2^192 + 2^96 - 1
private let P_MOD: Big = [0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0x00000000,
                          0x00000000, 0x00000000, 0x00000001, 0xFFFFFFFF]
// n = group order
private let N_MOD: Big = [0xFC632551, 0xF3B9CAC2, 0xA7179E84, 0xBCE6FAAD,
                          0xFFFFFFFF, 0xFFFFFFFF, 0x00000000, 0xFFFFFFFF]
// Base point G (affine, integer form; converted to Montgomery at use)
private let G_X: Big = [0xD898C296, 0xF4A13945, 0x2DEB33A0, 0x77037D81,
                        0x63A440F2, 0xF8BCE6E5, 0xE12C4247, 0x6B17D1F2]
private let G_Y: Big = [0x37BF51F5, 0xCBB64068, 0x6B315ECE, 0x2BCE3357,
                        0x7C0F9E16, 0x8EE7EB4A, 0xFE1A7F9B, 0x4FE342E2]

@inline(__always) private func bigZero() -> Big { Big(repeating: 0) }
@inline(__always) private func bigOne() -> Big { [1, 0, 0, 0, 0, 0, 0, 0] }

@inline(__always) private func isZeroBig(_ a: Big) -> Bool {
    var r: UInt32 = 0
    for i in 0..<8 { r |= a[i] }
    return r == 0
}

/// Returns -1, 0, 1 for a < b, a == b, a > b (unsigned).
private func cmpBig(_ a: Big, _ b: Big) -> Int {
    var i = 7
    while i >= 0 {
        if a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
        i -= 1
    }
    return 0
}

/// out = a + b; returns the carry out of bit 255.
@discardableResult
private func addBig(_ a: Big, _ b: Big, _ out: inout Big) -> UInt32 {
    var carry: UInt64 = 0
    for i in 0..<8 {
        let s = UInt64(a[i]) + UInt64(b[i]) + carry
        out[i] = UInt32(truncatingIfNeeded: s)
        carry = s >> 32
    }
    return UInt32(carry)
}

/// out = a - b; returns the borrow out of bit 255 (1 if a < b).
@discardableResult
private func subBig(_ a: Big, _ b: Big, _ out: inout Big) -> UInt32 {
    var borrow: UInt64 = 0
    for i in 0..<8 {
        let d = UInt64(a[i]) &- UInt64(b[i]) &- borrow
        out[i] = UInt32(truncatingIfNeeded: d)
        borrow = (d >> 63) & 1   // set when the subtraction underflowed
    }
    return UInt32(borrow)
}

/// (a + b) mod m, valid when a, b < m (so a + b < 2m).
private func addMod(_ a: Big, _ b: Big, _ m: Big) -> Big {
    var s = bigZero()
    let c = addBig(a, b, &s)
    if c != 0 || cmpBig(s, m) >= 0 {
        var t = bigZero()
        subBig(s, m, &t)
        return t
    }
    return s
}

/// (a - b) mod m, valid when a, b < m.
private func subMod(_ a: Big, _ b: Big, _ m: Big) -> Big {
    var d = bigZero()
    let bor = subBig(a, b, &d)
    if bor != 0 {
        var t = bigZero()
        addBig(d, m, &t)
        return t
    }
    return d
}

/// a mod m for a < 2m (single conditional subtraction). Both p and n exceed
/// 2^255, so any 256-bit input is < 2m and one subtraction suffices.
private func reduceOnce(_ a: Big, _ m: Big) -> Big {
    if cmpBig(a, m) >= 0 {
        var t = bigZero()
        subBig(a, m, &t)
        return t
    }
    return a
}

// MARK: - Montgomery context

private struct Mont {
    var m: Big        // modulus
    var n0: UInt32    // -m^{-1} mod 2^32
    var r2: Big       // 2^512 mod m
    var one: Big      // R mod m (= 1 in Montgomery form)
}

/// Inverse of an odd 32-bit value mod 2^32 (Newton's iteration; 5 rounds cover
/// all 32 bits starting from the seed x ≡ x^{-1} mod 8).
private func inv32(_ x: UInt32) -> UInt32 {
    var y = x
    for _ in 0..<5 { y = y &* (2 &- x &* y) }
    return y
}

private func makeMont(_ m: Big) -> Mont {
    let n0 = 0 &- inv32(m[0])              // -(m^{-1}) mod 2^32
    var acc = bigOne()                     // compute 2^512 mod m by doubling 1
    for _ in 0..<512 { acc = addMod(acc, acc, m) }
    var ctx = Mont(m: m, n0: n0, r2: acc, one: bigZero())
    ctx.one = montMul(bigOne(), acc, ctx)  // 1 -> Montgomery form (= R mod m)
    return ctx
}

/// Montgomery multiplication, Separated Operand Scanning (SOS):
/// returns a * b * R^{-1} mod m.
private func montMul(_ a: Big, _ b: Big, _ ctx: Mont) -> Big {
    var t = InlineArray<17, UInt32>(repeating: 0)   // 16 product limbs + carry
    let m = ctx.m

    // t = a * b (schoolbook).
    for i in 0..<8 {
        var carry: UInt64 = 0
        for j in 0..<8 {
            let p = UInt64(a[i]) * UInt64(b[j]) + UInt64(t[i + j]) + carry
            t[i + j] = UInt32(truncatingIfNeeded: p)
            carry = p >> 32
        }
        t[i + 8] = UInt32(truncatingIfNeeded: UInt64(t[i + 8]) + carry)
    }

    // Montgomery reduction.
    for i in 0..<8 {
        let mi = t[i] &* ctx.n0                       // (t[i] * n0) mod 2^32
        var carry: UInt64 = 0
        for j in 0..<8 {
            let p = UInt64(mi) * UInt64(m[j]) + UInt64(t[i + j]) + carry
            t[i + j] = UInt32(truncatingIfNeeded: p)
            carry = p >> 32
        }
        var k = i + 8
        while carry != 0 {
            let p = UInt64(t[k]) + carry
            t[k] = UInt32(truncatingIfNeeded: p)
            carry = p >> 32
            k += 1
        }
    }

    // result = t[8..16]; subtract m once if a final carry occurred or t >= m.
    var res = bigZero()
    for i in 0..<8 { res[i] = t[i + 8] }
    if t[16] != 0 || cmpBig(res, m) >= 0 {
        var u = bigZero()
        subBig(res, m, &u)
        return u
    }
    return res
}

@inline(__always) private func toMont(_ a: Big, _ ctx: Mont) -> Big { montMul(a, ctx.r2, ctx) }
@inline(__always) private func fromMont(_ a: Big, _ ctx: Mont) -> Big { montMul(a, bigOne(), ctx) }

/// Montgomery exponentiation: base (already in Montgomery form) ^ exp, returned
/// in Montgomery form. Square-and-multiply, MSB first.
private func montExp(_ base: Big, _ exp: Big, _ ctx: Mont) -> Big {
    var result = ctx.one
    var bit = 255
    while bit >= 0 {
        result = montMul(result, result, ctx)
        if (exp[bit >> 5] >> UInt32(bit & 31)) & 1 == 1 {
            result = montMul(result, base, ctx)
        }
        bit -= 1
    }
    return result
}

/// Modular inverse of a (plain integer, 0 < a < m) via Fermat: a^(m-2) mod m.
private func modInverse(_ a: Big, _ ctx: Mont) -> Big {
    var two = bigZero(); two[0] = 2
    var expo = bigZero()
    subBig(ctx.m, two, &expo)               // m - 2
    let am = toMont(a, ctx)
    return fromMont(montExp(am, expo, ctx), ctx)
}

/// (a * b) mod m for plain integers a, b < m.
@inline(__always) private func mulMod(_ a: Big, _ b: Big, _ ctx: Mont) -> Big {
    fromMont(montMul(toMont(a, ctx), toMont(b, ctx), ctx), ctx)
}

// MARK: - byte <-> Big (32-byte big-endian, ACME/JOSE wire order)

private func loadBE(_ p: UnsafeRawPointer) -> Big {
    let b = p.assumingMemoryBound(to: UInt8.self)
    var out = bigZero()
    for limb in 0..<8 {
        let base = (7 - limb) * 4   // limb 0 holds the last 4 bytes
        out[limb] = (UInt32(b[base]) << 24) | (UInt32(b[base + 1]) << 16)
                  | (UInt32(b[base + 2]) << 8) | UInt32(b[base + 3])
    }
    return out
}

private func storeBE(_ a: Big, _ p: UnsafeMutableRawPointer) {
    let b = p.assumingMemoryBound(to: UInt8.self)
    for limb in 0..<8 {
        let v = a[limb]
        let base = (7 - limb) * 4
        b[base] = UInt8(truncatingIfNeeded: v >> 24)
        b[base + 1] = UInt8(truncatingIfNeeded: v >> 16)
        b[base + 2] = UInt8(truncatingIfNeeded: v >> 8)
        b[base + 3] = UInt8(truncatingIfNeeded: v)
    }
}

// MARK: - point arithmetic (Jacobian, coordinates in Montgomery form mod p)

private struct Jac { var x: Big; var y: Big; var z: Big }   // z == 0 ⇒ infinity

private func pointDouble(_ pt: Jac, _ fp: Mont) -> Jac {
    if isZeroBig(pt.z) || isZeroBig(pt.y) {
        return Jac(x: fp.one, y: fp.one, z: bigZero())
    }
    func fmul(_ a: Big, _ b: Big) -> Big { montMul(a, b, fp) }
    func fsqr(_ a: Big) -> Big { montMul(a, a, fp) }
    func fadd(_ a: Big, _ b: Big) -> Big { addMod(a, b, fp.m) }
    func fsub(_ a: Big, _ b: Big) -> Big { subMod(a, b, fp.m) }

    let yy = fsqr(pt.y)
    let xyy = fmul(pt.x, yy)
    let s = fadd(fadd(xyy, xyy), fadd(xyy, xyy))      // 4*X*Y^2
    let zz = fsqr(pt.z)
    let zzzz = fsqr(zz)
    // a = -3: M = 3*(X^2) - 3*(Z^4) = 3*(X - Z^2)*(X + Z^2)
    let xsq3 = { () -> Big in let t = fsqr(pt.x); return fadd(fadd(t, t), t) }()
    let aTerm = { () -> Big in let t = fadd(fadd(zzzz, zzzz), zzzz); return t }()  // 3*Z^4
    let m = fsub(xsq3, aTerm)
    let twoS = fadd(s, s)
    let x3 = fsub(fsqr(m), twoS)
    let yyyy = fsqr(yy)
    let eightYYYY = { () -> Big in
        let a2 = fadd(yyyy, yyyy); let a4 = fadd(a2, a2); return fadd(a4, a4)
    }()
    let y3 = fsub(fmul(m, fsub(s, x3)), eightYYYY)
    let z3 = fmul(fadd(pt.y, pt.y), pt.z)             // 2*Y*Z
    return Jac(x: x3, y: y3, z: z3)
}

private func pointAdd(_ p1: Jac, _ p2: Jac, _ fp: Mont) -> Jac {
    if isZeroBig(p1.z) { return p2 }
    if isZeroBig(p2.z) { return p1 }
    func fmul(_ a: Big, _ b: Big) -> Big { montMul(a, b, fp) }
    func fsqr(_ a: Big) -> Big { montMul(a, a, fp) }
    func fadd(_ a: Big, _ b: Big) -> Big { addMod(a, b, fp.m) }
    func fsub(_ a: Big, _ b: Big) -> Big { subMod(a, b, fp.m) }

    let z1z1 = fsqr(p1.z)
    let z2z2 = fsqr(p2.z)
    let u1 = fmul(p1.x, z2z2)
    let u2 = fmul(p2.x, z1z1)
    let s1 = fmul(p1.y, fmul(p2.z, z2z2))
    let s2 = fmul(p2.y, fmul(p1.z, z1z1))
    if cmpBig(u1, u2) == 0 {
        if cmpBig(s1, s2) == 0 { return pointDouble(p1, fp) }
        return Jac(x: fp.one, y: fp.one, z: bigZero())   // P + (-P) = infinity
    }
    let h = fsub(u2, u1)
    let r = fsub(s2, s1)
    let hh = fsqr(h)
    let hhh = fmul(h, hh)
    let u1hh = fmul(u1, hh)
    let x3 = fsub(fsub(fsqr(r), hhh), fadd(u1hh, u1hh))
    let y3 = fsub(fmul(r, fsub(u1hh, x3)), fmul(s1, hhh))
    let z3 = fmul(fmul(p1.z, p2.z), h)
    return Jac(x: x3, y: y3, z: z3)
}

/// k * P (k a plain integer), double-and-add, MSB first.
private func scalarMult(_ k: Big, _ pt: Jac, _ fp: Mont) -> Jac {
    var r = Jac(x: fp.one, y: fp.one, z: bigZero())   // infinity
    var bit = 255
    while bit >= 0 {
        r = pointDouble(r, fp)
        if (k[bit >> 5] >> UInt32(bit & 31)) & 1 == 1 {
            r = pointAdd(r, pt, fp)
        }
        bit -= 1
    }
    return r
}

/// Base point G as a Jacobian point in Montgomery form.
private func baseG(_ fp: Mont) -> Jac {
    Jac(x: toMont(G_X, fp), y: toMont(G_Y, fp), z: fp.one)
}

/// Affine coordinates (plain integer form) of a non-infinity Jacobian point.
private func toAffine(_ pt: Jac, _ fp: Mont) -> (x: Big, y: Big) {
    let zinv = montExp(pt.z, { () -> Big in
        var two = bigZero(); two[0] = 2
        var e = bigZero(); subBig(fp.m, two, &e); return e
    }(), fp)                                  // Z^{-1} in Montgomery form
    let zinv2 = montMul(zinv, zinv, fp)
    let zinv3 = montMul(zinv2, zinv, fp)
    let x = fromMont(montMul(pt.x, zinv2, fp), fp)
    let y = fromMont(montMul(pt.y, zinv3, fp), fp)
    return (x, y)
}

// MARK: - public API

/// Derive the public key Q = d*G from a 32-byte big-endian private scalar.
/// Writes the affine X and Y (32 bytes big-endian each). Returns false if the
/// private scalar is not in [1, n-1].
func p256DerivePublic(_ privBE32: UnsafeRawPointer,
                      _ outX32: UnsafeMutableRawPointer,
                      _ outY32: UnsafeMutableRawPointer) -> Bool {
    let fp = makeMont(P_MOD)
    let d = loadBE(privBE32)
    if isZeroBig(d) || cmpBig(d, N_MOD) >= 0 { return false }
    let q = scalarMult(d, baseG(fp), fp)
    if isZeroBig(q.z) { return false }
    let aff = toAffine(q, fp)
    storeBE(aff.x, outX32)
    storeBE(aff.y, outY32)
    return true
}

/// Deterministic ECDSA (RFC 6979) over P-256 with SHA-256. `hash32` is the
/// 32-byte SHA-256 of the message. Writes r and s (32 bytes big-endian each).
/// Returns false only on a degenerate key.
func p256SignDeterministic(_ privBE32: UnsafeRawPointer,
                           _ hash32: UnsafeRawPointer,
                           _ outR32: UnsafeMutableRawPointer,
                           _ outS32: UnsafeMutableRawPointer) -> Bool {
    let fp = makeMont(P_MOD)
    let fn = makeMont(N_MOD)
    let d = loadBE(privBE32)
    if isZeroBig(d) || cmpBig(d, N_MOD) >= 0 { return false }

    // z = bits2int(hash) reduced mod n; bits2octets(hash) = z as 32 BE bytes.
    let z = reduceOnce(loadBE(hash32), N_MOD)
    let g = baseG(fp)

    var ok = false
    var rOut = bigZero()
    var sOut = bigZero()

    // RFC 6979 §3.2 deterministic generation of k, with the (r,s)-validity
    // retry folded into the same regeneration loop.
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { kBuf in
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { vBuf in
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { tmp in
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { privO in
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { hO in
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 97) { msg in
        for i in 0..<32 { privO[i] = privBE32.assumingMemoryBound(to: UInt8.self)[i] }
        storeBE(z, hO.baseAddress!)         // bits2octets(h1)

        let K = kBuf.baseAddress!
        let V = vBuf.baseAddress!
        for i in 0..<32 { V[i] = 0x01; K[i] = 0x00 }

        // build msg = V || sep || privO || hO  (length 97), HMAC into K
        func updateK(_ sep: UInt8) {
            for i in 0..<32 { msg[i] = V[i] }
            msg[32] = sep
            for i in 0..<32 { msg[33 + i] = privO[i] }
            for i in 0..<32 { msg[65 + i] = hO[i] }
            hmacSha256(K, 32, msg.baseAddress!, 97, tmp.baseAddress!)
            for i in 0..<32 { K[i] = tmp[i] }
        }
        func hmacKV() {  // V = HMAC(K, V)
            hmacSha256(K, 32, V, 32, tmp.baseAddress!)
            for i in 0..<32 { V[i] = tmp[i] }
        }

        updateK(0x00); hmacKV()
        updateK(0x01); hmacKV()

        var guardCount = 0
        while !ok && guardCount < 64 {
            guardCount += 1
            hmacKV()                                  // T = V (hlen == qlen)
            let k = loadBE(V)
            if isZeroBig(k) || cmpBig(k, N_MOD) >= 0 {
                // k out of range: reseed and retry.
                for i in 0..<32 { msg[i] = V[i] }
                msg[32] = 0x00
                hmacSha256(K, 32, msg.baseAddress!, 33, tmp.baseAddress!)
                for i in 0..<32 { K[i] = tmp[i] }
                hmacKV()
                continue
            }

            let r = computeR(k, g, fp)
            if isZeroBig(r) {
                for i in 0..<32 { msg[i] = V[i] }
                msg[32] = 0x00
                hmacSha256(K, 32, msg.baseAddress!, 33, tmp.baseAddress!)
                for i in 0..<32 { K[i] = tmp[i] }
                hmacKV()
                continue
            }
            // s = k^{-1} * (z + r*d) mod n
            let rd = mulMod(r, d, fn)
            let zrd = addMod(z, rd, N_MOD)
            let kinv = modInverse(k, fn)
            let s = mulMod(kinv, zrd, fn)
            if isZeroBig(s) {
                for i in 0..<32 { msg[i] = V[i] }
                msg[32] = 0x00
                hmacSha256(K, 32, msg.baseAddress!, 33, tmp.baseAddress!)
                for i in 0..<32 { K[i] = tmp[i] }
                hmacKV()
                continue
            }
            rOut = r; sOut = s; ok = true
        }
    } } } } } }

    if !ok { return false }
    storeBE(rOut, outR32)
    storeBE(sOut, outS32)
    return true
}

/// r coordinate for nonce k: x-coordinate of k*G reduced mod n.
private func computeR(_ k: Big, _ g: Jac, _ fp: Mont) -> Big {
    let kg = scalarMult(k, g, fp)
    if isZeroBig(kg.z) { return bigZero() }
    let aff = toAffine(kg, fp)
    return reduceOnce(aff.x, N_MOD)
}

/// Verify an ECDSA signature (used by the self-test; not on the ACME hot path).
func p256Verify(_ pubX32: UnsafeRawPointer, _ pubY32: UnsafeRawPointer,
                _ hash32: UnsafeRawPointer,
                _ r32: UnsafeRawPointer, _ s32: UnsafeRawPointer) -> Bool {
    let fp = makeMont(P_MOD)
    let fn = makeMont(N_MOD)
    let r = loadBE(r32)
    let s = loadBE(s32)
    if isZeroBig(r) || cmpBig(r, N_MOD) >= 0 { return false }
    if isZeroBig(s) || cmpBig(s, N_MOD) >= 0 { return false }
    let z = reduceOnce(loadBE(hash32), N_MOD)
    let w = modInverse(s, fn)
    let u1 = mulMod(z, w, fn)
    let u2 = mulMod(r, w, fn)
    let q = Jac(x: toMont(loadBE(pubX32), fp), y: toMont(loadBE(pubY32), fp), z: fp.one)
    let r1 = scalarMult(u1, baseG(fp), fp)
    let r2 = scalarMult(u2, q, fp)
    let sum = pointAdd(r1, r2, fp)
    if isZeroBig(sum.z) { return false }
    let aff = toAffine(sum, fp)
    let v = reduceOnce(aff.x, N_MOD)
    return cmpBig(v, r) == 0
}
