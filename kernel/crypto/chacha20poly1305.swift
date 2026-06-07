// chacha20poly1305.swift — RFC 8439 AEAD_CHACHA20_POLY1305 (net-h).
//
// Pure Swift: no Foundation, no MMIO, no heap allocation, no syscalls — same
// purity as kernel/net/packet.swift, so it compiles BOTH for the host unit test
// (tests/crypto_test.swift) and into the kernel (Embedded Swift). It is unused
// in the kernel for now (gc'd out), present so it keeps building — exactly like
// dns.swift was before it was wired up. This is groundwork for TLS 1.3, which
// mandates this AEAD; the handshake/record layer is deliberately deferred.
//
// All arithmetic is little-endian per RFC 8439: ChaCha20 words, Poly1305
// integers, and the AEAD length block are read/written least-significant byte
// first. We touch bytes one at a time so nothing depends on host alignment or
// endianness, matching the kernel's +strict-align build.

// Byte accessors. We keep these local (rather than reuse kernel/net/packet.swift)
// so the crypto module is fully self-contained: the host test compiles it alone,
// and the kernel links it without dragging in the net core.
@inline(__always) private func cb8(_ p: UnsafeRawPointer, _ off: Int) -> UInt8 {
    p.load(fromByteOffset: off, as: UInt8.self)
}
@inline(__always) private func cb8set(_ p: UnsafeMutableRawPointer, _ off: Int, _ v: UInt8) {
    p.storeBytes(of: v, toByteOffset: off, as: UInt8.self)
}

// MARK: - ChaCha20 (RFC 8439 §2.3)

/// The ChaCha20 constant "expand 32-byte k" as four little-endian words.
private let chachaConst: (UInt32, UInt32, UInt32, UInt32) =
    (0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574)

@inline(__always) private func rotl32(_ v: UInt32, _ n: UInt32) -> UInt32 {
    (v << n) | (v >> (32 - n))
}

/// Read a little-endian 32-bit word at byte offset `off`.
@inline(__always) private func le32(_ p: UnsafeRawPointer, _ off: Int) -> UInt32 {
    UInt32(cb8(p, off)) | (UInt32(cb8(p, off + 1)) << 8) |
    (UInt32(cb8(p, off + 2)) << 16) | (UInt32(cb8(p, off + 3)) << 24)
}

/// One ChaCha20 quarter-round on the four indexed words of `s`.
@inline(__always) private func quarterRound(
    _ s: inout (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32),
    _ a: Int, _ b: Int, _ c: Int, _ d: Int
) {
    // Swift tuples are not subscriptable, so route through a withUnsafe* view.
    withUnsafeMutableBytes(of: &s) { raw in
        let w = raw.baseAddress!.assumingMemoryBound(to: UInt32.self)
        w[a] = w[a] &+ w[b]; w[d] ^= w[a]; w[d] = rotl32(w[d], 16)
        w[c] = w[c] &+ w[d]; w[b] ^= w[c]; w[b] = rotl32(w[b], 12)
        w[a] = w[a] &+ w[b]; w[d] ^= w[a]; w[d] = rotl32(w[d], 8)
        w[c] = w[c] &+ w[d]; w[b] ^= w[c]; w[b] = rotl32(w[b], 7)
    }
}

/// Produce one 64-byte ChaCha20 keystream block for (`key`, `counter`, `nonce`)
/// into `out` (must hold 64 bytes). `key` is 32 bytes, `nonce` is 12 bytes.
func chacha20Block(key: UnsafeRawPointer, counter: UInt32, nonce: UnsafeRawPointer,
                   out: UnsafeMutableRawPointer) {
    var s = (
        chachaConst.0, chachaConst.1, chachaConst.2, chachaConst.3,
        le32(key, 0), le32(key, 4), le32(key, 8), le32(key, 12),
        le32(key, 16), le32(key, 20), le32(key, 24), le32(key, 28),
        counter, le32(nonce, 0), le32(nonce, 4), le32(nonce, 8)
    )
    var working = s
    // 20 rounds = 10 iterations of (4 column rounds + 4 diagonal rounds).
    for _ in 0..<10 {
        quarterRound(&working, 0, 4, 8, 12)
        quarterRound(&working, 1, 5, 9, 13)
        quarterRound(&working, 2, 6, 10, 14)
        quarterRound(&working, 3, 7, 11, 15)
        quarterRound(&working, 0, 5, 10, 15)
        quarterRound(&working, 1, 6, 11, 12)
        quarterRound(&working, 2, 7, 8, 13)
        quarterRound(&working, 3, 4, 9, 14)
    }
    withUnsafeBytes(of: &working) { wraw in
        withUnsafeBytes(of: &s) { sraw in
            let w = wraw.baseAddress!.assumingMemoryBound(to: UInt32.self)
            let init0 = sraw.baseAddress!.assumingMemoryBound(to: UInt32.self)
            for i in 0..<16 {
                let v = w[i] &+ init0[i]   // add the original input words
                let o = i * 4
                cb8set(out, o, UInt8(v & 0xFF))
                cb8set(out, o + 1, UInt8((v >> 8) & 0xFF))
                cb8set(out, o + 2, UInt8((v >> 16) & 0xFF))
                cb8set(out, o + 3, UInt8((v >> 24) & 0xFF))
            }
        }
    }
}

/// ChaCha20 encrypt/decrypt (the cipher is symmetric): XOR `len` plaintext bytes
/// at `input` with the keystream starting at block `counter` into `output`.
/// `output` may alias `input`. `key` is 32 bytes, `nonce` is 12 bytes.
func chacha20Encrypt(key: UnsafeRawPointer, counter: UInt32, nonce: UnsafeRawPointer,
                     input: UnsafeRawPointer, output: UnsafeMutableRawPointer, len: Int) {
    var block = (UInt64(0), UInt64(0), UInt64(0), UInt64(0),
                 UInt64(0), UInt64(0), UInt64(0), UInt64(0))   // 64-byte scratch
    withUnsafeMutableBytes(of: &block) { braw in
        let ks = braw.baseAddress!
        var off = 0
        var blk = counter
        while off < len {
            chacha20Block(key: key, counter: blk, nonce: nonce, out: ks)
            let n = min(64, len - off)
            for i in 0..<n {
                let c = cb8(input, off + i) ^ ks.load(fromByteOffset: i, as: UInt8.self)
                cb8set(output, off + i, c)
            }
            off += n
            blk &+= 1
        }
    }
}

// MARK: - Poly1305 (RFC 8439 §2.5)

// Poly1305 is a one-time MAC over GF(2^130 - 5). We hold the 130-bit accumulator
// and r/s as little-endian limbs. To stay portable and dependency-free we use a
// schoolbook 5x26-bit-limb multiply-reduce (the same shape as the reference
// "donna" 32-bit implementation), which avoids needing 128-bit integers.

/// Compute the 16-byte Poly1305 tag of `msg` (`len` bytes) under the 32-byte
/// one-time `key` (r ‖ s), writing the tag to `tagOut` (16 bytes).
func poly1305Mac(key: UnsafeRawPointer, msg: UnsafeRawPointer, len: Int,
                 tagOut: UnsafeMutableRawPointer) {
    // Load and clamp r (RFC 8439 §2.5: clear specific bits), as 5 26-bit limbs.
    let t0 = le32(key, 0), t1 = le32(key, 4), t2 = le32(key, 8), t3 = le32(key, 12)
    let r0 = t0 & 0x3ff_ffff
    let r1 = ((t0 >> 26) | (t1 << 6)) & 0x3ff_ff03
    let r2 = ((t1 >> 20) | (t2 << 12)) & 0x3ff_c0ff
    let r3 = ((t2 >> 14) | (t3 << 18)) & 0x3f0_3fff
    let r4 = (t3 >> 8) & 0x00f_ffff

    // Precompute 5*r1..5*r4 for the reduction step.
    let s1 = r1 &* 5, s2 = r2 &* 5, s3 = r3 &* 5, s4 = r4 &* 5

    var h0: UInt32 = 0, h1: UInt32 = 0, h2: UInt32 = 0, h3: UInt32 = 0, h4: UInt32 = 0

    var off = 0
    // Scratch for a possibly-padded final block (16 bytes).
    var tail = (UInt64(0), UInt64(0))
    while off < len {
        let n = min(16, len - off)
        // Read the next 16-byte block little-endian. A full block carries an
        // implicit high bit (2^128); a short final block is 0-padded with a 1
        // byte appended just past its data instead.
        var b0: UInt32 = 0, b1: UInt32 = 0, b2: UInt32 = 0, b3: UInt32 = 0
        if n == 16 {
            let bp = msg + off
            b0 = le32(bp, 0); b1 = le32(bp, 4); b2 = le32(bp, 8); b3 = le32(bp, 12)
        } else {
            withUnsafeMutableBytes(of: &tail) { t in
                for i in 0..<16 { t[i] = 0 }
                for i in 0..<n { t[i] = cb8(msg, off + i) }
                t[n] = 1
                let tp = t.baseAddress!
                b0 = le32(tp, 0); b1 = le32(tp, 4); b2 = le32(tp, 8); b3 = le32(tp, 12)
            }
        }
        let hibit: UInt32 = (n == 16) ? (1 << 24) : 0

        // h += block
        h0 = h0 &+ (b0 & 0x3ff_ffff)
        h1 = h1 &+ (((b0 >> 26) | (b1 << 6)) & 0x3ff_ffff)
        h2 = h2 &+ (((b1 >> 20) | (b2 << 12)) & 0x3ff_ffff)
        h3 = h3 &+ (((b2 >> 14) | (b3 << 18)) & 0x3ff_ffff)
        h4 = h4 &+ ((b3 >> 8) | hibit)

        // h *= r (mod 2^130 - 5), 64-bit partial products.
        let d0 = UInt64(h0) &* UInt64(r0) &+ UInt64(h1) &* UInt64(s4)
               &+ UInt64(h2) &* UInt64(s3) &+ UInt64(h3) &* UInt64(s2)
               &+ UInt64(h4) &* UInt64(s1)
        var d1 = UInt64(h0) &* UInt64(r1) &+ UInt64(h1) &* UInt64(r0)
               &+ UInt64(h2) &* UInt64(s4) &+ UInt64(h3) &* UInt64(s3)
               &+ UInt64(h4) &* UInt64(s2)
        var d2 = UInt64(h0) &* UInt64(r2) &+ UInt64(h1) &* UInt64(r1)
               &+ UInt64(h2) &* UInt64(r0) &+ UInt64(h3) &* UInt64(s4)
               &+ UInt64(h4) &* UInt64(s3)
        var d3 = UInt64(h0) &* UInt64(r3) &+ UInt64(h1) &* UInt64(r2)
               &+ UInt64(h2) &* UInt64(r1) &+ UInt64(h3) &* UInt64(r0)
               &+ UInt64(h4) &* UInt64(s4)
        var d4 = UInt64(h0) &* UInt64(r4) &+ UInt64(h1) &* UInt64(r3)
               &+ UInt64(h2) &* UInt64(r2) &+ UInt64(h3) &* UInt64(r1)
               &+ UInt64(h4) &* UInt64(r0)

        // Partial carry propagation back into 26-bit limbs.
        var c = UInt32(d0 >> 26); h0 = UInt32(d0 & 0x3ff_ffff)
        d1 = d1 &+ UInt64(c); c = UInt32(d1 >> 26); h1 = UInt32(d1 & 0x3ff_ffff)
        d2 = d2 &+ UInt64(c); c = UInt32(d2 >> 26); h2 = UInt32(d2 & 0x3ff_ffff)
        d3 = d3 &+ UInt64(c); c = UInt32(d3 >> 26); h3 = UInt32(d3 & 0x3ff_ffff)
        d4 = d4 &+ UInt64(c); c = UInt32(d4 >> 26); h4 = UInt32(d4 & 0x3ff_ffff)
        h0 = h0 &+ c &* 5; c = h0 >> 26; h0 = h0 & 0x3ff_ffff
        h1 = h1 &+ c

        off += n
    }

    // Final reduction: fully carry h.
    var c = h1 >> 26; h1 = h1 & 0x3ff_ffff
    h2 = h2 &+ c; c = h2 >> 26; h2 = h2 & 0x3ff_ffff
    h3 = h3 &+ c; c = h3 >> 26; h3 = h3 & 0x3ff_ffff
    h4 = h4 &+ c; c = h4 >> 26; h4 = h4 & 0x3ff_ffff
    h0 = h0 &+ c &* 5; c = h0 >> 26; h0 = h0 & 0x3ff_ffff
    h1 = h1 &+ c

    // Compute h + -p == h - (2^130 - 5); choose it if it didn't borrow (h >= p).
    var g0 = h0 &+ 5; c = g0 >> 26; g0 = g0 & 0x3ff_ffff
    var g1 = h1 &+ c; c = g1 >> 26; g1 = g1 & 0x3ff_ffff
    var g2 = h2 &+ c; c = g2 >> 26; g2 = g2 & 0x3ff_ffff
    var g3 = h3 &+ c; c = g3 >> 26; g3 = g3 & 0x3ff_ffff
    let g4 = h4 &+ c &- (1 << 26)

    // Constant-time select: if g4 has not borrowed (bit 31 clear), use g.
    let mask = (g4 >> 31) &- 1            // 0xffffffff if h >= p, else 0
    let nmask = ~mask
    h0 = (h0 & nmask) | (g0 & mask)
    h1 = (h1 & nmask) | (g1 & mask)
    h2 = (h2 & nmask) | (g2 & mask)
    h3 = (h3 & nmask) | (g3 & mask)
    h4 = (h4 & nmask) | (g4 & mask)
    // Serialize the 130-bit h to its low 128 bits, little-endian, in two u64s.
    // Limb boundaries are at bits 0,26,52,78,104; we pack the bottom 128 bits.
    let lo = (UInt64(h0) | (UInt64(h1) << 26) | (UInt64(h2) << 52))
    let hi = (UInt64(h2) >> 12) | (UInt64(h3) << 14) | (UInt64(h4) << 40)
    var hbytes = (UInt64(0), UInt64(0))
    withUnsafeMutableBytes(of: &hbytes) { hb in
        for i in 0..<8 { hb[i] = UInt8((lo >> (8 * UInt64(i))) & 0xFF) }
        for i in 0..<8 { hb[8 + i] = UInt8((hi >> (8 * UInt64(i))) & 0xFF) }
    }
    // tag = (h + s) mod 2^128, with s = key[16..32], little-endian.
    withUnsafeBytes(of: &hbytes) { hb in
        var carry: UInt16 = 0
        for i in 0..<16 {
            let sum = UInt16(hb[i]) + UInt16(cb8(key, 16 + i)) + carry
            cb8set(tagOut, i, UInt8(sum & 0xFF))
            carry = sum >> 8
        }
    }
}

// MARK: - AEAD_CHACHA20_POLY1305 (RFC 8439 §2.8)

/// Derive the Poly1305 one-time key for (`key`, `nonce`): the first 32 bytes of
/// ChaCha20 keystream block 0. Writes 32 bytes to `out`.
private func poly1305KeyGen(key: UnsafeRawPointer, nonce: UnsafeRawPointer,
                            out: UnsafeMutableRawPointer) {
    var block = (UInt64(0), UInt64(0), UInt64(0), UInt64(0),
                 UInt64(0), UInt64(0), UInt64(0), UInt64(0))
    withUnsafeMutableBytes(of: &block) { braw in
        let ks = braw.baseAddress!
        chacha20Block(key: key, counter: 0, nonce: nonce, out: ks)
        for i in 0..<32 { cb8set(out, i, ks.load(fromByteOffset: i, as: UInt8.self)) }
    }
}

/// Build the Poly1305 input for the AEAD: aad ‖ pad16 ‖ ciphertext ‖ pad16 ‖
/// len(aad) as u64-LE ‖ len(ciphertext) as u64-LE, then MAC it. `scratch` must
/// hold at least `padLen(aadLen) + padLen(ctLen) + 16` bytes.
@inline(__always) private func aeadTag(
    polyKey: UnsafeRawPointer,
    aad: UnsafeRawPointer, aadLen: Int,
    ciphertext: UnsafeRawPointer, ctLen: Int,
    scratch: UnsafeMutableRawPointer,
    tagOut: UnsafeMutableRawPointer
) {
    @inline(__always) func pad16(_ n: Int) -> Int { (n % 16 == 0) ? 0 : (16 - n % 16) }
    var w = 0
    for i in 0..<aadLen { cb8set(scratch, w + i, cb8(aad, i)) }; w += aadLen
    for _ in 0..<pad16(aadLen) { cb8set(scratch, w, 0); w += 1 }
    for i in 0..<ctLen { cb8set(scratch, w + i, cb8(ciphertext, i)) }; w += ctLen
    for _ in 0..<pad16(ctLen) { cb8set(scratch, w, 0); w += 1 }
    // Two little-endian u64 lengths.
    var la = UInt64(aadLen), lc = UInt64(ctLen)
    for _ in 0..<8 { cb8set(scratch, w, UInt8(la & 0xFF)); la >>= 8; w += 1 }
    for _ in 0..<8 { cb8set(scratch, w, UInt8(lc & 0xFF)); lc >>= 8; w += 1 }
    poly1305Mac(key: polyKey, msg: scratch, len: w, tagOut: tagOut)
}

/// AEAD seal: encrypt `plaintext` (`ptLen` bytes) under (`key`, 12-byte `nonce`)
/// with associated data `aad` (`aadLen` bytes). Writes `ptLen` ciphertext bytes
/// to `ciphertext` and the 16-byte authentication tag to `tagOut`. `scratch`
/// must hold at least `aadLen + ptLen + 32` bytes (rounded for padding).
func aeadSeal(key: UnsafeRawPointer, nonce: UnsafeRawPointer,
              aad: UnsafeRawPointer, aadLen: Int,
              plaintext: UnsafeRawPointer, ptLen: Int,
              ciphertext: UnsafeMutableRawPointer, tagOut: UnsafeMutableRawPointer,
              scratch: UnsafeMutableRawPointer) {
    var polyKey = (UInt64(0), UInt64(0), UInt64(0), UInt64(0))   // 32 bytes
    withUnsafeMutableBytes(of: &polyKey) { pk in
        poly1305KeyGen(key: key, nonce: nonce, out: pk.baseAddress!)
        // ChaCha20 starts at counter 1 (block 0 made the Poly1305 key).
        chacha20Encrypt(key: key, counter: 1, nonce: nonce,
                        input: plaintext, output: ciphertext, len: ptLen)
        aeadTag(polyKey: pk.baseAddress!, aad: aad, aadLen: aadLen,
                ciphertext: ciphertext, ctLen: ptLen, scratch: scratch, tagOut: tagOut)
    }
}

/// Constant-time 16-byte compare (no early-out on mismatch).
@inline(__always) private func tagsEqual(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer) -> Bool {
    var diff: UInt8 = 0
    for i in 0..<16 { diff |= cb8(a, i) ^ cb8(b, i) }
    return diff == 0
}

/// AEAD open: verify `tag` (16 bytes) over (`aad`, `ciphertext`) and, only if it
/// matches, decrypt `ciphertext` (`ctLen` bytes) into `plaintext`. Returns true
/// on success; on failure returns false and leaves `plaintext` untouched. The
/// tag check is constant-time. `scratch` sizing matches `aeadSeal`.
func aeadOpen(key: UnsafeRawPointer, nonce: UnsafeRawPointer,
              aad: UnsafeRawPointer, aadLen: Int,
              ciphertext: UnsafeRawPointer, ctLen: Int,
              tag: UnsafeRawPointer,
              plaintext: UnsafeMutableRawPointer,
              scratch: UnsafeMutableRawPointer) -> Bool {
    var polyKey = (UInt64(0), UInt64(0), UInt64(0), UInt64(0))   // 32 bytes
    var computed = (UInt64(0), UInt64(0))                        // 16-byte tag
    let ok: Bool = withUnsafeMutableBytes(of: &polyKey) { pk in
        poly1305KeyGen(key: key, nonce: nonce, out: pk.baseAddress!)
        return withUnsafeMutableBytes(of: &computed) { ct in
            aeadTag(polyKey: pk.baseAddress!, aad: aad, aadLen: aadLen,
                    ciphertext: ciphertext, ctLen: ctLen,
                    scratch: scratch, tagOut: ct.baseAddress!)
            return tagsEqual(ct.baseAddress!, tag)
        }
    }
    if !ok { return false }
    chacha20Encrypt(key: key, counter: 1, nonce: nonce,
                    input: ciphertext, output: plaintext, len: ctLen)
    return true
}
