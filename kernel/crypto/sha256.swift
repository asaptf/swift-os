// sha256.swift — SHA-256 (FIPS 180-4) + HMAC-SHA256 (RFC 2104) + HKDF (RFC 5869).
//
// Pure Swift: no Foundation, no MMIO, no heap allocation, no syscalls — same
// purity discipline as kernel/crypto/chacha20poly1305.swift, so it compiles BOTH
// for the host unit test (tests/hkdf_test.swift) and into a userland ELF (it is
// linked into /bin/tlsget alongside the AEAD). SHA-256 previously lived only as a
// private hex-output helper in userland/console-login.swift; this is the shared,
// raw-output home for it, extended with the MAC and key-derivation functions
// TLS 1.3's key schedule needs (RFC 8446 §7.1 builds entirely on HKDF-SHA256).
//
// All message-length and word arithmetic is big-endian per FIPS 180-4 (SHA-256
// processes 32-bit words MSB-first and appends the bit length as a 64-bit
// big-endian integer). We touch bytes one at a time so nothing depends on host
// alignment or endianness, matching the kernel's +strict-align build.

// Byte accessors, kept local so the module is self-contained (the host test
// compiles it alone, mirroring chacha20poly1305.swift).
@inline(__always) private func sb8(_ p: UnsafeRawPointer, _ off: Int) -> UInt8 {
    p.load(fromByteOffset: off, as: UInt8.self)
}
@inline(__always) private func sb8set(_ p: UnsafeMutableRawPointer, _ off: Int, _ v: UInt8) {
    p.storeBytes(of: v, toByteOffset: off, as: UInt8.self)
}

@inline(__always) private func rotr32(_ x: UInt32, _ n: UInt32) -> UInt32 {
    (x >> n) | (x << (32 &- n))
}

/// The SHA-256 round constants K[0..63] (FIPS 180-4 §4.2.2: the first 32 bits of
/// the fractional parts of the cube roots of the first 64 primes). Held as a
/// tuple rather than a heap Array so the module needs no allocator — accessed via
/// a withUnsafe* view, the same shape chacha20poly1305.swift uses for its state.
private let sha256K: (
    UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
    UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
    UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
    UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
    UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
    UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
    UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
    UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32
) = (
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
)

// MARK: - SHA-256 (FIPS 180-4)

/// SHA-256 digest length in bytes.
let sha256DigestLen = 32
/// SHA-256 internal block size in bytes (also HMAC's block size).
private let sha256BlockLen = 64

/// Compute SHA-256 of `msg[0..<len]` and write the 32-byte digest to `out32`.
/// `out32` must hold 32 bytes; it may not alias `msg`.
func sha256(_ msg: UnsafeRawPointer, _ len: Int, _ out32: UnsafeMutableRawPointer) {
    var h0: UInt32 = 0x6a09e667, h1: UInt32 = 0xbb67ae85
    var h2: UInt32 = 0x3c6ef372, h3: UInt32 = 0xa54ff53a
    var h4: UInt32 = 0x510e527f, h5: UInt32 = 0x9b05688c
    var h6: UInt32 = 0x1f83d9ab, h7: UInt32 = 0x5be0cd19

    // Padded length: message ‖ 0x80 ‖ zeros ‖ 64-bit big-endian bit length, so
    // the total is a multiple of 64 and the last 8 bytes hold the length.
    var padded = len + 1
    while padded % sha256BlockLen != 56 { padded += 1 }
    padded += 8

    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: padded) { bufb in
        let buf = bufb.baseAddress!
        for i in 0..<len { sb8set(buf, i, sb8(msg, i)) }
        sb8set(buf, len, 0x80)
        var i = len + 1
        while i < padded - 8 { sb8set(buf, i, 0); i += 1 }
        let bits = UInt64(len) &* 8
        var b = 0
        while b < 8 { sb8set(buf, padded - 1 - b, UInt8((bits >> (UInt64(b) &* 8)) & 0xFF)); b += 1 }

        withUnsafeBytes(of: sha256K) { kraw in
            let K = kraw.baseAddress!.assumingMemoryBound(to: UInt32.self)
            withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 64) { w in
                var off = 0
                while off < padded {
                    for t in 0..<16 {
                        let o = off + t * 4
                        w[t] = (UInt32(sb8(buf, o)) << 24) | (UInt32(sb8(buf, o + 1)) << 16)
                             | (UInt32(sb8(buf, o + 2)) << 8) | UInt32(sb8(buf, o + 3))
                    }
                    for t in 16..<64 {
                        let s0 = rotr32(w[t-15], 7) ^ rotr32(w[t-15], 18) ^ (w[t-15] >> 3)
                        let s1 = rotr32(w[t-2], 17) ^ rotr32(w[t-2], 19) ^ (w[t-2] >> 10)
                        w[t] = w[t-16] &+ s0 &+ w[t-7] &+ s1
                    }
                    var a = h0, bb = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7
                    for t in 0..<64 {
                        let S1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25)
                        let ch = (e & f) ^ (~e & g)
                        let t1 = h &+ S1 &+ ch &+ K[t] &+ w[t]
                        let S0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22)
                        let maj = (a & bb) ^ (a & c) ^ (bb & c)
                        let t2 = S0 &+ maj
                        h = g; g = f; f = e; e = d &+ t1; d = c; c = bb; bb = a; a = t1 &+ t2
                    }
                    h0 = h0 &+ a; h1 = h1 &+ bb; h2 = h2 &+ c; h3 = h3 &+ d
                    h4 = h4 &+ e; h5 = h5 &+ f; h6 = h6 &+ g; h7 = h7 &+ h
                    off += sha256BlockLen
                }
            }
        }
    }
    // Serialize the eight state words big-endian.
    @inline(__always) func put(_ v: UInt32, _ o: Int) {
        sb8set(out32, o,     UInt8((v >> 24) & 0xFF))
        sb8set(out32, o + 1, UInt8((v >> 16) & 0xFF))
        sb8set(out32, o + 2, UInt8((v >> 8) & 0xFF))
        sb8set(out32, o + 3, UInt8(v & 0xFF))
    }
    put(h0, 0);  put(h1, 4);  put(h2, 8);  put(h3, 12)
    put(h4, 16); put(h5, 20); put(h6, 24); put(h7, 28)
}

/// Compute SHA-256 of `msg[0..<len]` and write 64 lowercase hex bytes to `outHex`
/// (which must hold 64 bytes). A convenience wrapper over `sha256` for callers
/// that want the textual digest (e.g. /etc/swos/passwd verification).
func sha256Hex(_ msg: UnsafeRawPointer, _ len: Int, _ outHex: UnsafeMutableRawPointer) {
    var digest = (UInt64(0), UInt64(0), UInt64(0), UInt64(0))   // 32 bytes
    withUnsafeMutableBytes(of: &digest) { d in
        sha256(msg, len, d.baseAddress!)
        for i in 0..<sha256DigestLen {
            let byte = d.load(fromByteOffset: i, as: UInt8.self)
            let hi = byte >> 4, lo = byte & 0xF
            sb8set(outHex, i * 2,     hi < 10 ? 0x30 &+ hi : 0x61 &+ (hi &- 10))
            sb8set(outHex, i * 2 + 1, lo < 10 ? 0x30 &+ lo : 0x61 &+ (lo &- 10))
        }
    }
}

// MARK: - HMAC-SHA256 (RFC 2104)

/// HMAC-SHA256 of `msg[0..<msgLen]` under `key[0..<keyLen]`, writing the 32-byte
/// MAC to `out32`. Keys longer than the 64-byte block are first hashed; shorter
/// keys are zero-padded. Stack-only: no heap, no allocator dependency.
func hmacSha256(_ key: UnsafeRawPointer, _ keyLen: Int,
                _ msg: UnsafeRawPointer, _ msgLen: Int,
                _ out32: UnsafeMutableRawPointer) {
    // k0 = normalized key padded to the block size.
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: sha256BlockLen) { k0b in
        let k0 = k0b.baseAddress!
        for i in 0..<sha256BlockLen { sb8set(k0, i, 0) }
        if keyLen > sha256BlockLen {
            sha256(key, keyLen, k0)          // K' = H(K), then zero-padded (rest already 0)
        } else {
            for i in 0..<keyLen { sb8set(k0, i, sb8(key, i)) }
        }
        // inner = H( (k0 ^ ipad) ‖ msg ); outer = H( (k0 ^ opad) ‖ inner ).
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: sha256BlockLen + msgLen) { innerb in
            let inner = innerb.baseAddress!
            for i in 0..<sha256BlockLen { sb8set(inner, i, sb8(k0, i) ^ 0x36) }
            for i in 0..<msgLen { sb8set(inner, sha256BlockLen + i, sb8(msg, i)) }
            var ih = (UInt64(0), UInt64(0), UInt64(0), UInt64(0))   // 32-byte inner digest
            withUnsafeMutableBytes(of: &ih) { ihp in
                sha256(inner, sha256BlockLen + msgLen, ihp.baseAddress!)
                withUnsafeTemporaryAllocation(of: UInt8.self,
                                              capacity: sha256BlockLen + sha256DigestLen) { outerb in
                    let outer = outerb.baseAddress!
                    for i in 0..<sha256BlockLen { sb8set(outer, i, sb8(k0, i) ^ 0x5c) }
                    for i in 0..<sha256DigestLen {
                        sb8set(outer, sha256BlockLen + i, ihp.load(fromByteOffset: i, as: UInt8.self))
                    }
                    sha256(outer, sha256BlockLen + sha256DigestLen, out32)
                }
            }
        }
    }
}

// MARK: - HKDF (RFC 5869)

/// HKDF-Extract: PRK = HMAC-SHA256(salt, IKM). `salt` may be a zero-length (or
/// all-zero) buffer per the RFC's default. Writes 32 bytes to `prkOut`.
func hkdfExtract(salt: UnsafeRawPointer, saltLen: Int,
                 ikm: UnsafeRawPointer, ikmLen: Int,
                 prkOut: UnsafeMutableRawPointer) {
    hmacSha256(salt, saltLen, ikm, ikmLen, prkOut)
}

/// HKDF-Expand: derive `outLen` bytes of OKM from a 32-byte `prk` and an `info`
/// context, writing them to `out`. `outLen` must be <= 255*32 = 8160 (RFC 5869
/// §2.3). Implements the T(1) ‖ T(2) ‖ … construction with single-block HMACs.
func hkdfExpand(prk: UnsafeRawPointer,
                info: UnsafeRawPointer, infoLen: Int,
                out: UnsafeMutableRawPointer, outLen: Int) {
    // Each round: T(i) = HMAC(PRK, T(i-1) ‖ info ‖ byte(i)). T(0) is empty.
    withUnsafeTemporaryAllocation(of: UInt8.self,
                                  capacity: sha256DigestLen + infoLen + 1) { msgb in
        let msg = msgb.baseAddress!
        var t = (UInt64(0), UInt64(0), UInt64(0), UInt64(0))   // 32-byte previous T
        withUnsafeMutableBytes(of: &t) { tp in
            var produced = 0
            var counter: UInt8 = 1
            var haveT = false
            while produced < outLen {
                var w = 0
                if haveT {
                    for i in 0..<sha256DigestLen { sb8set(msg, w + i, tp.load(fromByteOffset: i, as: UInt8.self)) }
                    w += sha256DigestLen
                }
                for i in 0..<infoLen { sb8set(msg, w + i, sb8(info, i)) }; w += infoLen
                sb8set(msg, w, counter); w += 1
                // T(i) overwrites the previous block in place.
                hmacSha256(prk, sha256DigestLen, msg, w, tp.baseAddress!)
                haveT = true
                let n = min(sha256DigestLen, outLen - produced)
                for i in 0..<n { sb8set(out, produced + i, tp.load(fromByteOffset: i, as: UInt8.self)) }
                produced += n
                counter &+= 1
            }
        }
    }
}

// MARK: - Streaming SHA-256 (I8)
//
// Incremental hashing for inputs that cannot be held contiguously — the kernel
// verifies base-image file content by streaming it off virtio-blk in chunks.
// InlineArray state, no heap. Self-contained compress loop (the proven one-shot
// above is left untouched); equivalence is pinned by tests/ed25519_test.swift's
// streaming check and by every signed-image content verification.

struct Sha256Stream {
    private var h: InlineArray<8, UInt32> = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    private var tail = InlineArray<64, UInt8>(repeating: 0)
    private var tailLen = 0
    private var total: UInt64 = 0

    init() {}

    private mutating func compress(_ block: UnsafeRawPointer) {
        withUnsafeBytes(of: sha256K) { kraw in
            let K = kraw.baseAddress!.assumingMemoryBound(to: UInt32.self)
            var w = InlineArray<64, UInt32>(repeating: 0)
            for t in 0..<16 {
                let o = t * 4
                w[t] = (UInt32(sb8(block, o)) << 24) | (UInt32(sb8(block, o + 1)) << 16)
                     | (UInt32(sb8(block, o + 2)) << 8) | UInt32(sb8(block, o + 3))
            }
            for t in 16..<64 {
                let s0 = rotr32(w[t-15], 7) ^ rotr32(w[t-15], 18) ^ (w[t-15] >> 3)
                let s1 = rotr32(w[t-2], 17) ^ rotr32(w[t-2], 19) ^ (w[t-2] >> 10)
                w[t] = w[t-16] &+ s0 &+ w[t-7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hh = h[7]
            for t in 0..<64 {
                let S1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ S1 &+ ch &+ K[t] &+ w[t]
                let S0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = S0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
    }

    mutating func update(_ p: UnsafeRawPointer, _ len: Int) {
        total &+= UInt64(len)
        var off = 0
        // Top up a partial tail block first.
        if tailLen > 0 {
            while tailLen < 64 && off < len {
                tail[tailLen] = sb8(p, off)
                tailLen += 1
                off += 1
            }
            if tailLen == 64 {
                withUnsafeBytes(of: tail) { compress($0.baseAddress!) }
                tailLen = 0
            }
        }
        // Whole blocks straight from the input.
        while off + 64 <= len {
            compress(p + off)
            off += 64
        }
        // Stash the remainder.
        while off < len {
            tail[tailLen] = sb8(p, off)
            tailLen += 1
            off += 1
        }
    }

    mutating func final(_ out32: UnsafeMutableRawPointer) {
        let bits = total &* 8
        tail[tailLen] = 0x80
        tailLen += 1
        if tailLen > 56 {
            while tailLen < 64 { tail[tailLen] = 0; tailLen += 1 }
            withUnsafeBytes(of: tail) { compress($0.baseAddress!) }
            tailLen = 0
        }
        while tailLen < 56 { tail[tailLen] = 0; tailLen += 1 }
        for b in 0..<8 {
            tail[56 + b] = UInt8((bits >> (UInt64(7 - b) &* 8)) & 0xFF)
        }
        withUnsafeBytes(of: tail) { compress($0.baseAddress!) }
        for i in 0..<8 {
            let v = h[i]
            sb8set(out32, i * 4,     UInt8((v >> 24) & 0xFF))
            sb8set(out32, i * 4 + 1, UInt8((v >> 16) & 0xFF))
            sb8set(out32, i * 4 + 2, UInt8((v >> 8) & 0xFF))
            sb8set(out32, i * 4 + 3, UInt8(v & 0xFF))
        }
    }
}
