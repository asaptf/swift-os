// SPDX-License-Identifier: Apache-2.0
// loader_sha256.h — minimal FIPS 180-4 SHA-256 for the UEFI loader (U1g-3a).
//
// Header-only static functions so the exact code the loader runs is also
// host-tested (tests/loader_sha256_test.c) against the standard vectors. The
// loader has no libc/crypto, so this is self-contained. 32-bit round math uses
// `unsigned int` (32-bit on both the aarch64-windows EFI target and the host);
// the byte counter is `unsigned long long`.

#ifndef SWIFT_OS_LOADER_SHA256_H
#define SWIFT_OS_LOADER_SHA256_H

typedef struct {
    unsigned int h[8];
    unsigned long long len;   // total bytes hashed
    unsigned char buf[64];
    unsigned int buflen;
} sha256_ctx;

static const unsigned int SHA256_K[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu, 0x59f111f1u,
    0x923f82a4u, 0xab1c5ed5u, 0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
    0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u, 0xe49b69c1u, 0xefbe4786u,
    0x0fc19dc6u, 0x240ca1ccu, 0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
    0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u, 0xc6e00bf3u, 0xd5a79147u,
    0x06ca6351u, 0x14292967u, 0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
    0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u, 0xa2bfe8a1u, 0xa81a664bu,
    0xc24b8b70u, 0xc76c51a3u, 0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
    0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au,
    0x5b9cca4fu, 0x682e6ff3u, 0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u
};

static inline unsigned int sha256_ror(unsigned int x, unsigned int n) {
    return (x >> n) | (x << (32 - n));
}

static inline void sha256_block(sha256_ctx *c, const unsigned char *p) {
    unsigned int w[64];
    for (int i = 0; i < 16; i++) {
        w[i] = ((unsigned int)p[i * 4] << 24) | ((unsigned int)p[i * 4 + 1] << 16)
             | ((unsigned int)p[i * 4 + 2] << 8) | (unsigned int)p[i * 4 + 3];
    }
    for (int i = 16; i < 64; i++) {
        unsigned int s0 = sha256_ror(w[i - 15], 7) ^ sha256_ror(w[i - 15], 18) ^ (w[i - 15] >> 3);
        unsigned int s1 = sha256_ror(w[i - 2], 17) ^ sha256_ror(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    unsigned int a = c->h[0], b = c->h[1], cc = c->h[2], d = c->h[3];
    unsigned int e = c->h[4], f = c->h[5], g = c->h[6], h = c->h[7];
    for (int i = 0; i < 64; i++) {
        unsigned int S1 = sha256_ror(e, 6) ^ sha256_ror(e, 11) ^ sha256_ror(e, 25);
        unsigned int ch = (e & f) ^ ((~e) & g);
        unsigned int t1 = h + S1 + ch + SHA256_K[i] + w[i];
        unsigned int S0 = sha256_ror(a, 2) ^ sha256_ror(a, 13) ^ sha256_ror(a, 22);
        unsigned int maj = (a & b) ^ (a & cc) ^ (b & cc);
        unsigned int t2 = S0 + maj;
        h = g; g = f; f = e; e = d + t1; d = cc; cc = b; b = a; a = t1 + t2;
    }
    c->h[0] += a; c->h[1] += b; c->h[2] += cc; c->h[3] += d;
    c->h[4] += e; c->h[5] += f; c->h[6] += g; c->h[7] += h;
}

static inline void sha256_init(sha256_ctx *c) {
    c->h[0] = 0x6a09e667u; c->h[1] = 0xbb67ae85u; c->h[2] = 0x3c6ef372u; c->h[3] = 0xa54ff53au;
    c->h[4] = 0x510e527fu; c->h[5] = 0x9b05688cu; c->h[6] = 0x1f83d9abu; c->h[7] = 0x5be0cd19u;
    c->len = 0; c->buflen = 0;
}

static inline void sha256_update(sha256_ctx *c, const unsigned char *data, unsigned long long n) {
    c->len += n;
    while (n) {
        unsigned int take = 64 - c->buflen;
        if ((unsigned long long)take > n) take = (unsigned int)n;
        for (unsigned int i = 0; i < take; i++) c->buf[c->buflen + i] = data[i];
        c->buflen += take; data += take; n -= take;
        if (c->buflen == 64) { sha256_block(c, c->buf); c->buflen = 0; }
    }
}

static inline void sha256_final(sha256_ctx *c, unsigned char out[32]) {
    unsigned long long bits = c->len * 8ULL;
    unsigned char pad = 0x80;
    sha256_update(c, &pad, 1);
    unsigned char z = 0;
    while (c->buflen != 56) sha256_update(c, &z, 1);
    unsigned char lenbe[8];
    for (int i = 0; i < 8; i++) lenbe[i] = (unsigned char)(bits >> (56 - 8 * i));
    sha256_update(c, lenbe, 8);
    for (int i = 0; i < 8; i++) {
        out[i * 4]     = (unsigned char)(c->h[i] >> 24);
        out[i * 4 + 1] = (unsigned char)(c->h[i] >> 16);
        out[i * 4 + 2] = (unsigned char)(c->h[i] >> 8);
        out[i * 4 + 3] = (unsigned char)(c->h[i]);
    }
}

static inline void sha256_hash(const unsigned char *data, unsigned long long n, unsigned char out[32]) {
    sha256_ctx c;
    sha256_init(&c);
    sha256_update(&c, data, n);
    sha256_final(&c, out);
}

#endif // SWIFT_OS_LOADER_SHA256_H
