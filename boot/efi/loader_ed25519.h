// SPDX-License-Identifier: Apache-2.0
// loader_ed25519.h — SHA-512 + Ed25519 *verify* (RFC 8032) for the UEFI loader.
//
// Header-only static functions so the exact code the loader runs is also
// host-tested (tests/loader_ed25519_test.c) against the RFC 8032 §7.1 vectors.
// The loader has no libc/crypto. This is the compact TweetNaCl shape, ported
// from the kernel's tested kernel/crypto/{ed25519,sha512}.swift with the curve
// constants copied verbatim. Verify-only: signing stays host-side (Swift).
//
// Types: 64-bit field/scalar math uses `long long` / `unsigned long long`
// (64-bit on both the aarch64-windows EFI target and the host).

#ifndef SWIFT_OS_LOADER_ED25519_H
#define SWIFT_OS_LOADER_ED25519_H

// ---- SHA-512 (FIPS 180-4) --------------------------------------------------

static const unsigned long long ED_SHA512_K[80] = {
    0x428a2f98d728ae22ULL, 0x7137449123ef65cdULL, 0xb5c0fbcfec4d3b2fULL, 0xe9b5dba58189dbbcULL,
    0x3956c25bf348b538ULL, 0x59f111f1b605d019ULL, 0x923f82a4af194f9bULL, 0xab1c5ed5da6d8118ULL,
    0xd807aa98a3030242ULL, 0x12835b0145706fbeULL, 0x243185be4ee4b28cULL, 0x550c7dc3d5ffb4e2ULL,
    0x72be5d74f27b896fULL, 0x80deb1fe3b1696b1ULL, 0x9bdc06a725c71235ULL, 0xc19bf174cf692694ULL,
    0xe49b69c19ef14ad2ULL, 0xefbe4786384f25e3ULL, 0x0fc19dc68b8cd5b5ULL, 0x240ca1cc77ac9c65ULL,
    0x2de92c6f592b0275ULL, 0x4a7484aa6ea6e483ULL, 0x5cb0a9dcbd41fbd4ULL, 0x76f988da831153b5ULL,
    0x983e5152ee66dfabULL, 0xa831c66d2db43210ULL, 0xb00327c898fb213fULL, 0xbf597fc7beef0ee4ULL,
    0xc6e00bf33da88fc2ULL, 0xd5a79147930aa725ULL, 0x06ca6351e003826fULL, 0x142929670a0e6e70ULL,
    0x27b70a8546d22ffcULL, 0x2e1b21385c26c926ULL, 0x4d2c6dfc5ac42aedULL, 0x53380d139d95b3dfULL,
    0x650a73548baf63deULL, 0x766a0abb3c77b2a8ULL, 0x81c2c92e47edaee6ULL, 0x92722c851482353bULL,
    0xa2bfe8a14cf10364ULL, 0xa81a664bbc423001ULL, 0xc24b8b70d0f89791ULL, 0xc76c51a30654be30ULL,
    0xd192e819d6ef5218ULL, 0xd69906245565a910ULL, 0xf40e35855771202aULL, 0x106aa07032bbd1b8ULL,
    0x19a4c116b8d2d0c8ULL, 0x1e376c085141ab53ULL, 0x2748774cdf8eeb99ULL, 0x34b0bcb5e19b48a8ULL,
    0x391c0cb3c5c95a63ULL, 0x4ed8aa4ae3418acbULL, 0x5b9cca4f7763e373ULL, 0x682e6ff3d6b2b8a3ULL,
    0x748f82ee5defb2fcULL, 0x78a5636f43172f60ULL, 0x84c87814a1f0ab72ULL, 0x8cc702081a6439ecULL,
    0x90befffa23631e28ULL, 0xa4506cebde82bde9ULL, 0xbef9a3f7b2c67915ULL, 0xc67178f2e372532bULL,
    0xca273eceea26619cULL, 0xd186b8c721c0c207ULL, 0xeada7dd6cde0eb1eULL, 0xf57d4f7fee6ed178ULL,
    0x06f067aa72176fbaULL, 0x0a637dc5a2c898a6ULL, 0x113f9804bef90daeULL, 0x1b710b35131c471bULL,
    0x28db77f523047d84ULL, 0x32caab7b40c72493ULL, 0x3c9ebe0a15c9bebcULL, 0x431d67c49c100d4cULL,
    0x4cc5d4becb3e42b6ULL, 0x597f299cfc657e2aULL, 0x5fcb6fab3ad6faecULL, 0x6c44198c4a475817ULL
};

static unsigned long long ed_rotr64(unsigned long long x, unsigned n) {
    return (x >> n) | (x << (64 - n));
}

// One-shot SHA-512 over [msg, msg+len) into out[64]. Padding materialized on the
// fly (mirrors kernel/crypto/sha512.swift).
static void ed_sha512(const unsigned char *bytes, unsigned long long len, unsigned char *out) {
    unsigned long long h[8] = {
        0x6a09e667f3bcc908ULL, 0xbb67ae8584caa73bULL, 0x3c6ef372fe94f82bULL, 0xa54ff53a5f1d36f1ULL,
        0x510e527fade682d1ULL, 0x9b05688c2b3e6c1fULL, 0x1f83d9abfb41bd6bULL, 0x5be0cd19137e2179ULL
    };
    unsigned long long blocks = (len + 1 + 16 + 127) / 128;
    unsigned long long w[80];
    for (unsigned long long b = 0; b < blocks; b++) {
        for (int t = 0; t < 16; t++) {
            unsigned long long v = 0;
            for (int i = 0; i < 8; i++) {
                unsigned long long idx = b * 128 + (unsigned long long)t * 8 + i;
                unsigned char byte = 0;
                if (idx < len) {
                    byte = bytes[idx];
                } else if (idx == len) {
                    byte = 0x80;
                } else if (b == blocks - 1 && t >= 14) {
                    unsigned long long bitLen = len << 3;
                    unsigned long long pos = b * 128 + 128 - idx - 1;
                    if (pos < 8) byte = (unsigned char)(bitLen >> (8 * pos));
                }
                v = (v << 8) | byte;
            }
            w[t] = v;
        }
        for (int t = 16; t < 80; t++) {
            unsigned long long s0 = ed_rotr64(w[t - 15], 1) ^ ed_rotr64(w[t - 15], 8) ^ (w[t - 15] >> 7);
            unsigned long long s1 = ed_rotr64(w[t - 2], 19) ^ ed_rotr64(w[t - 2], 61) ^ (w[t - 2] >> 6);
            w[t] = w[t - 16] + s0 + w[t - 7] + s1;
        }
        unsigned long long a = h[0], bb = h[1], c = h[2], d = h[3];
        unsigned long long e = h[4], f = h[5], g = h[6], hh = h[7];
        for (int t = 0; t < 80; t++) {
            unsigned long long S1 = ed_rotr64(e, 14) ^ ed_rotr64(e, 18) ^ ed_rotr64(e, 41);
            unsigned long long ch = (e & f) ^ (~e & g);
            unsigned long long t1 = hh + S1 + ch + ED_SHA512_K[t] + w[t];
            unsigned long long S0 = ed_rotr64(a, 28) ^ ed_rotr64(a, 34) ^ ed_rotr64(a, 39);
            unsigned long long maj = (a & bb) ^ (a & c) ^ (bb & c);
            unsigned long long t2 = S0 + maj;
            hh = g; g = f; f = e; e = d + t1; d = c; c = bb; bb = a; a = t1 + t2;
        }
        h[0] += a; h[1] += bb; h[2] += c; h[3] += d;
        h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
    }
    for (int i = 0; i < 8; i++)
        for (int j = 0; j < 8; j++)
            out[i * 8 + j] = (unsigned char)(h[i] >> (56 - 8 * j));
}

// ---- field arithmetic mod 2^255-19 (sixteen 16-bit limbs) ------------------

typedef long long ed_gf[16];

static const ed_gf ED_gf1 = {1};
static const ed_gf ED_D = {
    0x78a3, 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141, 0x0a4d, 0x0070,
    0xe898, 0x7779, 0x4079, 0x8cc7, 0xfe73, 0x2b6f, 0x6cee, 0x5203
};
static const ed_gf ED_D2 = {
    0xf159, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0,
    0xd130, 0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df, 0xd9dc, 0x2406
};
static const ed_gf ED_X = {
    0xd51a, 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525, 0xc760, 0x692c,
    0xdc5c, 0xfdd6, 0xe231, 0xc0a4, 0x53fe, 0xcd6e, 0x36d3, 0x2169
};
static const ed_gf ED_Y = {
    0x6658, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666,
    0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666
};
static const ed_gf ED_I = {
    0xa0b0, 0x4a0e, 0x1b27, 0xc4ee, 0xe478, 0xad2f, 0x1806, 0x2f43,
    0xd7a7, 0x3dfb, 0x0099, 0x2b4d, 0xdf0b, 0x4fc1, 0x2480, 0x2b83
};
// Group order L, little-endian bytes (2^252 + 27742...).
static const long long ED_L[32] = {
    0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10
};

static void ed_copy(ed_gf o, const ed_gf a) { for (int i = 0; i < 16; i++) o[i] = a[i]; }

static void ed_car(ed_gf o) {
    for (int i = 0; i < 16; i++) {
        o[i] += (1LL << 16);
        long long c = o[i] >> 16;
        if (i < 15) o[i + 1] += c - 1;
        else o[0] += 38 * (c - 1);
        o[i] -= c << 16;
    }
}

static void ed_sel(ed_gf p, ed_gf q, long long b) {
    long long c = ~(b - 1);
    for (int i = 0; i < 16; i++) {
        long long t = c & (p[i] ^ q[i]);
        p[i] ^= t;
        q[i] ^= t;
    }
}

static void ed_pack(unsigned char *o, const ed_gf n) {
    ed_gf t, m;
    ed_copy(t, n);
    ed_car(t); ed_car(t); ed_car(t);
    for (int j = 0; j < 2; j++) {
        m[0] = t[0] - 0xffed;
        for (int i = 1; i < 15; i++) {
            m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1);
            m[i - 1] &= 0xffff;
        }
        m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1);
        long long b = (m[15] >> 16) & 1;
        m[14] &= 0xffff;
        ed_sel(t, m, 1 - b);
    }
    for (int i = 0; i < 16; i++) {
        o[2 * i] = (unsigned char)(t[i]);
        o[2 * i + 1] = (unsigned char)(t[i] >> 8);
    }
}

// Returns 1 if a != b (matches the Swift neq25519).
static int ed_neq(const ed_gf a, const ed_gf b) {
    unsigned char c[32], d[32];
    ed_pack(c, a);
    ed_pack(d, b);
    unsigned char diff = 0;
    for (int i = 0; i < 32; i++) diff |= c[i] ^ d[i];
    return diff != 0;
}

static unsigned char ed_par(const ed_gf a) {
    unsigned char s[32];
    ed_pack(s, a);
    return s[0] & 1;
}

static void ed_unpack(ed_gf o, const unsigned char *n) {
    for (int i = 0; i < 16; i++) o[i] = (long long)n[2 * i] + ((long long)n[2 * i + 1] << 8);
    o[15] &= 0x7fff;
}

static void ed_A(ed_gf o, const ed_gf a, const ed_gf b) { for (int i = 0; i < 16; i++) o[i] = a[i] + b[i]; }
static void ed_Z(ed_gf o, const ed_gf a, const ed_gf b) { for (int i = 0; i < 16; i++) o[i] = a[i] - b[i]; }

static void ed_M(ed_gf o, const ed_gf a, const ed_gf b) {
    long long t[31];
    for (int i = 0; i < 31; i++) t[i] = 0;
    for (int i = 0; i < 16; i++)
        for (int j = 0; j < 16; j++) t[i + j] += a[i] * b[j];
    for (int i = 0; i < 15; i++) t[i] += 38 * t[i + 16];
    for (int i = 0; i < 16; i++) o[i] = t[i];
    ed_car(o);
    ed_car(o);
}

static void ed_S(ed_gf o, const ed_gf a) { ed_M(o, a, a); }

static void ed_inv(ed_gf o, const ed_gf i) {
    ed_gf c;
    ed_copy(c, i);
    for (int a = 253; a >= 0; a--) {
        ed_S(c, c);
        if (a != 2 && a != 4) ed_M(c, c, i);
    }
    ed_copy(o, c);
}

static void ed_pow2523(ed_gf o, const ed_gf i) {
    ed_gf c;
    ed_copy(c, i);
    for (int a = 250; a >= 0; a--) {
        ed_S(c, c);
        if (a != 1) ed_M(c, c, i);
    }
    ed_copy(o, c);
}

// ---- edwards25519 points (extended coords X,Y,Z,T) -------------------------

typedef struct { ed_gf x, y, z, t; } ed_point;

static void ed_point_neutral(ed_point *p) {
    for (int i = 0; i < 16; i++) { p->x[i] = 0; p->y[i] = 0; p->z[i] = 0; p->t[i] = 0; }
    p->y[0] = 1; p->z[0] = 1;
}

static void ed_point_add(ed_point *p, const ed_point *q) {
    ed_gf a, b, c, d, e, f, g, h, t;
    ed_Z(a, p->y, p->x);
    ed_Z(t, q->y, q->x);
    ed_M(a, a, t);
    ed_A(b, p->x, p->y);
    ed_A(t, q->x, q->y);
    ed_M(b, b, t);
    ed_M(c, p->t, q->t);
    ed_M(c, c, ED_D2);
    ed_M(d, p->z, q->z);
    ed_A(d, d, d);
    ed_Z(e, b, a);
    ed_Z(f, d, c);
    ed_A(g, d, c);
    ed_A(h, b, a);
    ed_M(p->x, e, f);
    ed_M(p->y, h, g);
    ed_M(p->z, g, f);
    ed_M(p->t, e, h);
}

static void ed_point_cswap(ed_point *p, ed_point *q, long long b) {
    ed_sel(p->x, q->x, b);
    ed_sel(p->y, q->y, b);
    ed_sel(p->z, q->z, b);
    ed_sel(p->t, q->t, b);
}

static void ed_point_pack(unsigned char *r, const ed_point *p) {
    ed_gf zi, tx, ty;
    ed_inv(zi, p->z);
    ed_M(tx, p->x, zi);
    ed_M(ty, p->y, zi);
    ed_pack(r, ty);
    r[31] ^= ed_par(tx) << 7;
}

// q = [s]p, 256-bit ladder, MSB first, constant-time swaps.
static void ed_scalarmult(ed_point *q, ed_point *p, const unsigned char *s) {
    ed_point_neutral(q);
    for (int i = 255; i >= 0; i--) {
        long long b = (s[i / 8] >> (i & 7)) & 1;
        ed_point_cswap(q, p, b);
        ed_point_add(p, q);
        ed_point_add(q, q);
        ed_point_cswap(q, p, b);
    }
}

static void ed_scalarbase(ed_point *q, const unsigned char *s) {
    ed_point p;
    ed_copy(p.x, ED_X);
    ed_copy(p.y, ED_Y);
    ed_copy(p.z, ED_gf1);
    ed_M(p.t, ED_X, ED_Y);
    ed_scalarmult(q, &p, s);
}

// ---- scalar reduction mod L ------------------------------------------------

static void ed_modL(unsigned char *r, long long *x) {
    for (int i = 63; i >= 32; i--) {
        long long carry = 0;
        for (int j = i - 32; j < i - 12; j++) {
            x[j] += carry - 16 * x[i] * ED_L[j - (i - 32)];
            carry = (x[j] + 128) >> 8;
            x[j] -= carry << 8;
        }
        x[i - 12] += carry;
        x[i] = 0;
    }
    long long carry = 0;
    for (int j = 0; j < 32; j++) {
        x[j] += carry - (x[31] >> 4) * ED_L[j];
        carry = x[j] >> 8;
        x[j] &= 255;
    }
    for (int j = 0; j < 32; j++) x[j] -= carry * ED_L[j];
    for (int j = 0; j < 32; j++) {
        x[j + 1] += x[j] >> 8;
        r[j] = (unsigned char)(x[j] & 255);
    }
}

static void ed_reduce64(unsigned char *r) {
    long long x[64];
    for (int i = 0; i < 64; i++) x[i] = (long long)r[i];
    for (int i = 0; i < 64; i++) r[i] = 0;
    ed_modL(r, x);
}

// Decode a packed point into -P (x negated). Returns 0 for a non-curve encoding.
static int ed_unpackneg(ed_point *r, const unsigned char *p) {
    ed_gf t, chk, num, den, den2, den4, den6;
    ed_copy(r->z, ED_gf1);
    ed_unpack(r->y, p);
    ed_S(num, r->y);
    ed_M(den, num, ED_D);
    ed_Z(num, num, r->z);
    ed_A(den, r->z, den);

    ed_S(den2, den);
    ed_S(den4, den2);
    ed_M(den6, den4, den2);
    ed_M(t, den6, num);
    ed_M(t, t, den);

    ed_pow2523(t, t);
    ed_M(t, t, num);
    ed_M(t, t, den);
    ed_M(t, t, den);
    ed_M(r->x, t, den);

    ed_S(chk, r->x);
    ed_M(chk, chk, den);
    if (ed_neq(chk, num)) ed_M(r->x, r->x, ED_I);

    ed_S(chk, r->x);
    ed_M(chk, chk, den);
    if (ed_neq(chk, num)) return 0;

    if (ed_par(r->x) == (p[31] >> 7)) {
        ed_gf zero = {0};
        ed_Z(r->x, zero, r->x);
    }
    ed_M(r->t, r->x, r->y);
    return 1;
}

// ---- verify ----------------------------------------------------------------

// Maximum message length the loader verifies (the SWOSKERN manifest body, plus
// headroom for the host test vectors). R||A||M is staged in a static buffer.
#define ED25519_MAX_MSG 512

// Verify a detached 64-byte Ed25519 signature over [msg, msg+mlen) with the
// 32-byte public key. Returns 1 if valid, 0 otherwise (or if mlen is too large).
static int ed25519_verify(const unsigned char *sig, const unsigned char *msg,
                          unsigned long long mlen, const unsigned char *pub) {
    static unsigned char sm[64 + ED25519_MAX_MSG];
    if (mlen > ED25519_MAX_MSG) return 0;

    ed_point q;
    if (!ed_unpackneg(&q, pub)) return 0;

    for (int i = 0; i < 32; i++) sm[i] = sig[i];
    for (int i = 0; i < 32; i++) sm[32 + i] = pub[i];
    for (unsigned long long i = 0; i < mlen; i++) sm[64 + i] = msg[i];

    unsigned char h[64];
    ed_sha512(sm, 64 + mlen, h);
    ed_reduce64(h);

    ed_point p;
    ed_scalarmult(&p, &q, h);
    ed_point sb;
    ed_scalarbase(&sb, sig + 32);
    ed_point_add(&p, &sb);

    unsigned char check[32];
    ed_point_pack(check, &p);
    unsigned char diff = 0;
    for (int i = 0; i < 32; i++) diff |= check[i] ^ sig[i];
    return diff == 0;
}

#endif // SWIFT_OS_LOADER_ED25519_H
