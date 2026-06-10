// SPDX-License-Identifier: Apache-2.0
// loader_sha256_test.c — host vector test for the UEFI loader's SHA-256 (U1g-3a).
//
// Compiles the exact header-only SHA-256 the loader uses (boot/efi/loader_sha256.h)
// with the host compiler and checks it against the standard FIPS 180-4 vectors.
// This is what lets us trust the kernel-slot integrity check the loader performs
// before ExitBootServices, where it cannot be observed directly.

#include "../boot/efi/loader_sha256.h"
#include <stdio.h>
#include <string.h>

static int check(const char *label, const char *msg, unsigned long long n, const char *want) {
    unsigned char out[32];
    sha256_hash((const unsigned char *)msg, n, out);
    char got[65];
    for (int i = 0; i < 32; i++) sprintf(got + i * 2, "%02x", out[i]);
    got[64] = 0;
    if (strcmp(got, want) != 0) {
        printf("FAIL %s: got %s want %s\n", label, got, want);
        return 1;
    }
    return 0;
}

int main(void) {
    int bad = 0;
    bad |= check("abc", "abc", 3,
                 "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    bad |= check("empty", "", 0,
                 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    // 56-byte message: forces a second padded block (the classic multi-block case).
    bad |= check("two-block", "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", 56,
                 "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
    if (bad) {
        printf("loader_sha256_test: FAIL\n");
        return 1;
    }
    printf("PASS: loader SHA-256 matches FIPS 180-4 vectors\n");
    return 0;
}
