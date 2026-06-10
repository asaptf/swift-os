// SPDX-License-Identifier: Apache-2.0
// loader_ed25519_test.c — host vector test for the UEFI loader's Ed25519 verify
// (U1g-3b). Compiles the exact header (boot/efi/loader_ed25519.h) with the host
// compiler and checks it against the RFC 8032 §7.1 test vectors, plus a negative
// (tampered-signature) case. This is what lets us trust the kernel-image
// signature check the loader performs before ExitBootServices.

#include "../boot/efi/loader_ed25519.h"
#include <stdio.h>
#include <string.h>

static int hex(const char *s, unsigned char *out, int n) {
    for (int i = 0; i < n; i++) {
        unsigned v = 0;
        sscanf(s + 2 * i, "%2x", &v);
        out[i] = (unsigned char)v;
    }
    return n;
}

int main(void) {
    int bad = 0;
    unsigned char pub[32], sig[64], msg[2];

    // RFC 8032 §7.1 Test 1: empty message.
    hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", pub, 32);
    hex("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
        "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b", sig, 64);
    if (ed25519_verify(sig, msg, 0, pub) != 1) { printf("FAIL: RFC8032 test1 (empty msg)\n"); bad = 1; }
    // Tamper the signature -> must reject.
    sig[0] ^= 0x01;
    if (ed25519_verify(sig, msg, 0, pub) != 0) { printf("FAIL: tampered sig accepted\n"); bad = 1; }

    // RFC 8032 §7.1 Test 2: one-byte message 0x72.
    hex("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", pub, 32);
    hex("92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da"
        "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00", sig, 64);
    msg[0] = 0x72;
    if (ed25519_verify(sig, msg, 1, pub) != 1) { printf("FAIL: RFC8032 test2 (1-byte msg)\n"); bad = 1; }
    // Tamper the message -> must reject.
    msg[0] = 0x73;
    if (ed25519_verify(sig, msg, 1, pub) != 0) { printf("FAIL: tampered msg accepted\n"); bad = 1; }

    if (bad) { printf("loader_ed25519_test: FAIL\n"); return 1; }
    printf("PASS: loader Ed25519 verify matches RFC 8032 vectors (and rejects tampering)\n");
    return 0;
}
