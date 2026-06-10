// SPDX-License-Identifier: Apache-2.0
//
// ed25519.swift — Ed25519 signatures (RFC 8032) in pure, Embedded-compatible
// Swift: signed model bundles today, signed system images later.
//
// Self-contained like the other kernel/crypto files (no Foundation, no
// stdlib beyond Array/UnsafePointer): field arithmetic mod 2^255-19 on
// sixteen 16-bit limbs held in Int64 (the compact TweetNaCl shape, rewritten
// in Swift), edwards25519 points in extended coordinates, a constant-time
// conditional-swap scalar ladder, and scalar reduction mod the group order L.
// SHA-512 comes from sha512.swift. All curve constants below were generated
// by exact integer arithmetic from first principles (d = -121665/121666,
// base point y = 4/5, sqrt(-1) = 2^((p-1)/4)), and the whole file is pinned
// to the RFC 8032 §7.1 test vectors by tests/ed25519_test.swift.
//
// Verification (the path the OS runs at bundle load) does not need to be
// constant-time; signing is host-side tooling today. The ladder is
// constant-time anyway because it is the simplest correct structure.

private typealias Gf = [Int64]   // 16 limbs of 16 bits

private let gf0: Gf = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
private let gf1: Gf = [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
// d = -121665/121666 mod p
private let gfD: Gf = [
    0x78a3, 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141, 0x0a4d, 0x0070,
    0xe898, 0x7779, 0x4079, 0x8cc7, 0xfe73, 0x2b6f, 0x6cee, 0x5203,
]
// 2d mod p
private let gfD2: Gf = [
    0xf159, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0,
    0xd130, 0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df, 0xd9dc, 0x2406,
]
// Base point
private let gfX: Gf = [
    0xd51a, 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525, 0xc760, 0x692c,
    0xdc5c, 0xfdd6, 0xe231, 0xc0a4, 0x53fe, 0xcd6e, 0x36d3, 0x2169,
]
private let gfY: Gf = [
    0x6658, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666,
    0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666,
]
// sqrt(-1) = 2^((p-1)/4) mod p
private let gfI: Gf = [
    0xa0b0, 0x4a0e, 0x1b27, 0xc4ee, 0xe478, 0xad2f, 0x1806, 0x2f43,
    0xd7a7, 0x3dfb, 0x0099, 0x2b4d, 0xdf0b, 0x4fc1, 0x2480, 0x2b83,
]
// Group order l, little-endian bytes (2^252 + 27742...93)
private let orderL: [Int64] = [
    0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10,
]

// MARK: field arithmetic

private func car25519(_ o: inout Gf) {
    for i in 0..<16 {
        o[i] += (1 << 16)
        let c = o[i] >> 16
        if i < 15 {
            o[i + 1] += c - 1
        } else {
            o[0] += 38 * (c - 1)   // limb 15 wraps: 2^256 = 38 mod p over limb 0
        }
        o[i] -= c << 16
    }
}

private func sel25519(_ p: inout Gf, _ q: inout Gf, _ b: Int64) {
    let c = ~(b - 1)   // b=1 -> all ones (swap); b=0 -> 0 (keep)
    for i in 0..<16 {
        let t = c & (p[i] ^ q[i])
        p[i] ^= t
        q[i] ^= t
    }
}

private func pack25519(_ o: UnsafeMutablePointer<UInt8>, _ n: Gf) {
    var t = n
    car25519(&t); car25519(&t); car25519(&t)
    var m = gf0
    for _ in 0..<2 {
        m[0] = t[0] - 0xffed
        for i in 1..<15 {
            m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1)
            m[i - 1] &= 0xffff
        }
        m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1)
        let b = (m[15] >> 16) & 1
        m[14] &= 0xffff
        var mm = m, tt = t
        sel25519(&tt, &mm, 1 - b)
        t = tt; m = mm
    }
    for i in 0..<16 {
        o[2 * i] = UInt8(truncatingIfNeeded: t[i])
        o[2 * i + 1] = UInt8(truncatingIfNeeded: t[i] >> 8)
    }
}

private func neq25519(_ a: Gf, _ b: Gf) -> Bool {
    var c = [UInt8](repeating: 0, count: 32)
    var d = [UInt8](repeating: 0, count: 32)
    c.withUnsafeMutableBufferPointer { cb in pack25519(cb.baseAddress!, a) }
    d.withUnsafeMutableBufferPointer { db in pack25519(db.baseAddress!, b) }
    var diff: UInt8 = 0
    for i in 0..<32 { diff |= c[i] ^ d[i] }
    return diff != 0
}

private func par25519(_ a: Gf) -> UInt8 {
    var d = [UInt8](repeating: 0, count: 32)
    d.withUnsafeMutableBufferPointer { db in pack25519(db.baseAddress!, a) }
    return d[0] & 1
}

private func unpack25519(_ o: inout Gf, _ n: UnsafePointer<UInt8>) {
    for i in 0..<16 { o[i] = Int64(n[2 * i]) + (Int64(n[2 * i + 1]) << 8) }
    o[15] &= 0x7fff
}

private func fadd(_ o: inout Gf, _ a: Gf, _ b: Gf) {
    for i in 0..<16 { o[i] = a[i] + b[i] }
}
private func fsub(_ o: inout Gf, _ a: Gf, _ b: Gf) {
    for i in 0..<16 { o[i] = a[i] - b[i] }
}
private func fmul(_ o: inout Gf, _ a: Gf, _ b: Gf) {
    var t = [Int64](repeating: 0, count: 31)
    for i in 0..<16 {
        for j in 0..<16 { t[i + j] += a[i] * b[j] }
    }
    for i in 0..<15 { t[i] += 38 * t[i + 16] }
    for i in 0..<16 { o[i] = t[i] }
    car25519(&o)
    car25519(&o)
}
private func fsquare(_ o: inout Gf, _ a: Gf) { fmul(&o, a, a) }

private func inv25519(_ o: inout Gf, _ i: Gf) {
    var c = i
    var a = 253
    while a >= 0 {
        fsquare(&c, c)
        if a != 2 && a != 4 { fmul(&c, c, i) }
        a -= 1
    }
    o = c
}

private func pow2523(_ o: inout Gf, _ i: Gf) {
    var c = i
    var a = 250
    while a >= 0 {
        fsquare(&c, c)
        if a != 1 { fmul(&c, c, i) }
        a -= 1
    }
    o = c
}

// MARK: edwards25519 points (extended coordinates X, Y, Z, T)

private struct Point {
    var x = gf0
    var y = gf1
    var z = gf1
    var t = gf0
}

private func pointAdd(_ p: inout Point, _ q: Point) {
    var a = gf0, b = gf0, c = gf0, d = gf0
    var e = gf0, f = gf0, g = gf0, h = gf0
    var t = gf0
    fsub(&a, p.y, p.x)
    fsub(&t, q.y, q.x)
    fmul(&a, a, t)
    fadd(&b, p.x, p.y)
    fadd(&t, q.x, q.y)
    fmul(&b, b, t)
    fmul(&c, p.t, q.t)
    fmul(&c, c, gfD2)
    fmul(&d, p.z, q.z)
    fadd(&d, d, d)
    fsub(&e, b, a)
    fsub(&f, d, c)
    fadd(&g, d, c)
    fadd(&h, b, a)
    fmul(&p.x, e, f)
    fmul(&p.y, h, g)
    fmul(&p.z, g, f)
    fmul(&p.t, e, h)
}

private func pointCSwap(_ p: inout Point, _ q: inout Point, _ b: Int64) {
    sel25519(&p.x, &q.x, b)
    sel25519(&p.y, &q.y, b)
    sel25519(&p.z, &q.z, b)
    sel25519(&p.t, &q.t, b)
}

private func pointPack(_ r: UnsafeMutablePointer<UInt8>, _ p: Point) {
    var zi = gf0, tx = gf0, ty = gf0
    inv25519(&zi, p.z)
    fmul(&tx, p.x, zi)
    fmul(&ty, p.y, zi)
    pack25519(r, ty)
    r[31] ^= par25519(tx) << 7
}

/// q = [s]p, 256-bit ladder, MSB first, constant-time swaps.
private func pointScalarMult(_ q: inout Point, _ p: inout Point, _ s: UnsafePointer<UInt8>) {
    q = Point()   // neutral (0, 1, 1, 0)
    var i = 255
    while i >= 0 {
        let b = Int64((s[i / 8] >> (UInt8(i & 7))) & 1)
        pointCSwap(&q, &p, b)
        pointAdd(&p, q)
        pointAdd(&q, q)
        pointCSwap(&q, &p, b)
        i -= 1
    }
}

private func pointScalarBase(_ q: inout Point, _ s: UnsafePointer<UInt8>) {
    var p = Point()
    p.x = gfX
    p.y = gfY
    p.z = gf1
    fmul(&p.t, gfX, gfY)
    pointScalarMult(&q, &p, s)
}

// MARK: scalar arithmetic mod L

private func modL(_ r: UnsafeMutablePointer<UInt8>, _ x: inout [Int64]) {
    for i in stride(from: 63, through: 32, by: -1) {
        var carry: Int64 = 0
        for j in (i - 32)..<(i - 12) {
            x[j] += carry - 16 * x[i] * orderL[j - (i - 32)]
            carry = (x[j] + 128) >> 8
            x[j] -= carry << 8
        }
        x[i - 12] += carry
        x[i] = 0
    }
    var carry: Int64 = 0
    for j in 0..<32 {
        x[j] += carry - (x[31] >> 4) * orderL[j]
        carry = x[j] >> 8
        x[j] &= 255
    }
    for j in 0..<32 { x[j] -= carry * orderL[j] }
    for i in 0..<32 {
        x[i + 1] += x[i] >> 8
        r[i] = UInt8(truncatingIfNeeded: x[i] & 255)
    }
}

private func reduce64(_ r: UnsafeMutablePointer<UInt8>) {
    var x = [Int64](repeating: 0, count: 64)
    for i in 0..<64 { x[i] = Int64(r[i]) }
    for i in 0..<64 { r[i] = 0 }
    modL(r, &x)
}

// MARK: point decompression

/// Decode a packed point into -P (x negated): the verifier needs [h](-A).
/// Returns false for a non-curve encoding.
private func unpackNeg(_ r: inout Point, _ p: UnsafePointer<UInt8>) -> Bool {
    var t = gf0, chk = gf0, num = gf0, den = gf0
    var den2 = gf0, den4 = gf0, den6 = gf0
    r.z = gf1
    unpack25519(&r.y, p)
    fsquare(&num, r.y)
    fmul(&den, num, gfD)
    fsub(&num, num, r.z)
    fadd(&den, r.z, den)

    fsquare(&den2, den)
    fsquare(&den4, den2)
    fmul(&den6, den4, den2)
    fmul(&t, den6, num)
    fmul(&t, t, den)

    pow2523(&t, t)
    fmul(&t, t, num)
    fmul(&t, t, den)
    fmul(&t, t, den)
    fmul(&r.x, t, den)

    fsquare(&chk, r.x)
    fmul(&chk, chk, den)
    if neq25519(chk, num) { fmul(&r.x, r.x, gfI) }

    fsquare(&chk, r.x)
    fmul(&chk, chk, den)
    if neq25519(chk, num) { return false }

    if par25519(r.x) == (p[31] >> 7) {
        fsub(&r.x, gf0, r.x)
    }
    fmul(&r.t, r.x, r.y)
    return true
}

// MARK: public API

/// Derive the 32-byte public key from a 32-byte seed (RFC 8032 §5.1.5).
func ed25519PublicKey(seed: UnsafeRawPointer, publicKey out: UnsafeMutableRawPointer) {
    var d = [UInt8](repeating: 0, count: 64)
    d.withUnsafeMutableBytes { db in sha512(seed, 32, db.baseAddress!) }
    d[0] &= 248
    d[31] &= 127
    d[31] |= 64
    var p = Point()
    d.withUnsafeBufferPointer { db in pointScalarBase(&p, db.baseAddress!) }
    pointPack(out.assumingMemoryBound(to: UInt8.self), p)
}

/// Detached signature (64 bytes) over `message`, RFC 8032 §5.1.6.
func ed25519Sign(message: UnsafeRawPointer, _ len: Int, seed: UnsafeRawPointer,
                 signature out: UnsafeMutableRawPointer) {
    let msg = message.assumingMemoryBound(to: UInt8.self)
    let sig = out.assumingMemoryBound(to: UInt8.self)

    var d = [UInt8](repeating: 0, count: 64)
    d.withUnsafeMutableBytes { db in sha512(seed, 32, db.baseAddress!) }
    d[0] &= 248
    d[31] &= 127
    d[31] |= 64

    var pub = [UInt8](repeating: 0, count: 32)
    pub.withUnsafeMutableBytes { pb in ed25519PublicKey(seed: seed, publicKey: pb.baseAddress!) }

    // r = SHA-512(prefix || M) mod L
    var buf = [UInt8](repeating: 0, count: 64 + len)
    for i in 0..<32 { buf[32 + i] = d[32 + i] }   // prefix into the R slot for hashing
    for i in 0..<len { buf[64 + i] = msg[i] }
    var r = [UInt8](repeating: 0, count: 64)
    buf.withUnsafeBytes { bb in
        r.withUnsafeMutableBytes { rb in
            sha512(bb.baseAddress! + 32, 32 + len, rb.baseAddress!)
        }
    }
    r.withUnsafeMutableBufferPointer { rb in reduce64(rb.baseAddress!) }

    var p = Point()
    r.withUnsafeBufferPointer { rb in pointScalarBase(&p, rb.baseAddress!) }
    pointPack(sig, p)

    // h = SHA-512(R || A || M) mod L
    for i in 0..<32 { buf[i] = sig[i] }
    for i in 0..<32 { buf[32 + i] = pub[i] }
    var h = [UInt8](repeating: 0, count: 64)
    buf.withUnsafeBytes { bb in
        h.withUnsafeMutableBytes { hb in sha512(bb.baseAddress!, 64 + len, hb.baseAddress!) }
    }
    h.withUnsafeMutableBufferPointer { hb in reduce64(hb.baseAddress!) }

    // S = (r + h * a) mod L
    var x = [Int64](repeating: 0, count: 64)
    for i in 0..<32 { x[i] = Int64(r[i]) }
    for i in 0..<32 {
        for j in 0..<32 { x[i + j] += Int64(h[i]) * Int64(d[j]) }
    }
    modL(sig + 32, &x)
}

/// Verify a detached signature. Not constant-time (verification is public).
func ed25519Verify(message: UnsafeRawPointer, _ len: Int, signature: UnsafeRawPointer,
                   publicKey: UnsafeRawPointer) -> Bool {
    let msg = message.assumingMemoryBound(to: UInt8.self)
    let sig = signature.assumingMemoryBound(to: UInt8.self)
    let pub = publicKey.assumingMemoryBound(to: UInt8.self)

    var q = Point()
    if !unpackNeg(&q, pub) { return false }

    // h = SHA-512(R || A || M) mod L
    var buf = [UInt8](repeating: 0, count: 64 + len)
    for i in 0..<32 { buf[i] = sig[i] }
    for i in 0..<32 { buf[32 + i] = pub[i] }
    for i in 0..<len { buf[64 + i] = msg[i] }
    var h = [UInt8](repeating: 0, count: 64)
    buf.withUnsafeBytes { bb in
        h.withUnsafeMutableBytes { hb in sha512(bb.baseAddress!, 64 + len, hb.baseAddress!) }
    }
    h.withUnsafeMutableBufferPointer { hb in reduce64(hb.baseAddress!) }

    // R' = [S]B + [h](-A); accept iff R' == R.
    var p = Point()
    h.withUnsafeBufferPointer { hb in
        var qq = q
        pointScalarMult(&p, &qq, hb.baseAddress!)
    }
    var sb = Point()
    pointScalarBase(&sb, sig + 32)
    pointAdd(&p, sb)

    var t = [UInt8](repeating: 0, count: 32)
    t.withUnsafeMutableBufferPointer { tb in pointPack(tb.baseAddress!, p) }
    var diff: UInt8 = 0
    for i in 0..<32 { diff |= t[i] ^ sig[i] }
    return diff == 0
}
