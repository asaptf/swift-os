// largemmapprobe.c - C/newlib proof for multi-MiB mmap/mprotect/munmap.

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>

static void fail(const char *msg) {
    printf("largemmapprobe: FAIL: %s errno=%d\n", msg, errno);
}

static int expect_zero(volatile unsigned char *p, size_t len, size_t stride) {
    for (size_t off = 0; off < len; off += stride) {
        if (p[off] != 0) {
            printf("largemmapprobe: FAIL: nonzero byte at %lu value=%u\n",
                   (unsigned long)off, (unsigned)p[off]);
            return 0;
        }
    }
    if (p[len - 1] != 0) {
        printf("largemmapprobe: FAIL: nonzero final byte value=%u\n",
               (unsigned)p[len - 1]);
        return 0;
    }
    return 1;
}

static int write_pattern(volatile unsigned char *p, size_t len, size_t stride) {
    for (size_t off = 0; off < len; off += stride) {
        p[off] = (unsigned char)((off / stride) ^ 0x5a);
    }
    p[len - 1] = 0xa5;
    for (size_t off = 0; off < len; off += stride) {
        unsigned char want = (unsigned char)((off / stride) ^ 0x5a);
        if (p[off] != want) {
            printf("largemmapprobe: FAIL: pattern mismatch at %lu got=%u want=%u\n",
                   (unsigned long)off, (unsigned)p[off], (unsigned)want);
            return 0;
        }
    }
    if (p[len - 1] != 0xa5) {
        printf("largemmapprobe: FAIL: final pattern mismatch got=%u\n",
               (unsigned)p[len - 1]);
        return 0;
    }
    return 1;
}

int main(void) {
    const size_t page = 4096;
    const size_t map_len = 8u * 1024u * 1024u;
    const size_t half_len = map_len / 2u;
    const size_t small_len = 1024u * 1024u;

    void *large = mmap(0, map_len, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (large == MAP_FAILED) {
        fail("8M mmap");
        return 1;
    }

    volatile unsigned char *bytes = (volatile unsigned char *)large;
    if (!expect_zero(bytes, map_len, page)) {
        (void)munmap(large, map_len);
        return 2;
    }
    printf("largemmapprobe: 8M zero-fill OK\n");

    if (!write_pattern(bytes, map_len, page)) {
        (void)munmap(large, map_len);
        return 3;
    }
    printf("largemmapprobe: 8M strided write OK\n");

    void *mid = (void *)(uintptr_t)((uintptr_t)large + (2u * 1024u * 1024u));
    if (mprotect(mid, page, PROT_READ | PROT_EXEC) != 0) {
        fail("partial mprotect RW->RX");
        (void)munmap(large, map_len);
        return 4;
    }
    if (mprotect(mid, page, PROT_READ | PROT_WRITE) != 0) {
        fail("partial mprotect RX->RW");
        (void)munmap(large, map_len);
        return 5;
    }
    bytes[2u * 1024u * 1024u] = 0x3c;
    if (bytes[2u * 1024u * 1024u] != 0x3c) {
        printf("largemmapprobe: FAIL: partial mprotect writeback mismatch\n");
        (void)munmap(large, map_len);
        return 6;
    }
    printf("largemmapprobe: partial mprotect OK\n");

    if (munmap(large, half_len) != 0) {
        fail("bottom-half munmap");
        (void)munmap((void *)(uintptr_t)((uintptr_t)large + half_len), half_len);
        return 7;
    }
    void *small = mmap(0, small_len, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (small == MAP_FAILED) {
        fail("reuse mmap");
        (void)munmap((void *)(uintptr_t)((uintptr_t)large + half_len), half_len);
        return 8;
    }
    uintptr_t large_base = (uintptr_t)large;
    uintptr_t small_base = (uintptr_t)small;
    if (small_base < large_base || small_base + small_len > large_base + half_len) {
        printf("largemmapprobe: FAIL: reuse VA outside freed bottom half large=0x%lx small=0x%lx\n",
               (unsigned long)large_base, (unsigned long)small_base);
        (void)munmap(small, small_len);
        (void)munmap((void *)(uintptr_t)(large_base + half_len), half_len);
        return 9;
    }
    if (!expect_zero((volatile unsigned char *)small, small_len, page)) {
        (void)munmap(small, small_len);
        (void)munmap((void *)(uintptr_t)(large_base + half_len), half_len);
        return 10;
    }
    if (!write_pattern((volatile unsigned char *)small, small_len, page)) {
        (void)munmap(small, small_len);
        (void)munmap((void *)(uintptr_t)(large_base + half_len), half_len);
        return 11;
    }
    if (bytes[half_len] != (unsigned char)((half_len / page) ^ 0x5a)) {
        printf("largemmapprobe: FAIL: upper half changed across reuse\n");
        (void)munmap(small, small_len);
        (void)munmap((void *)(uintptr_t)(large_base + half_len), half_len);
        return 12;
    }
    printf("largemmapprobe: bottom munmap reuse OK\n");

    if (munmap(small, small_len) != 0) {
        fail("small munmap");
        (void)munmap((void *)(uintptr_t)(large_base + half_len), half_len);
        return 13;
    }
    if (munmap((void *)(uintptr_t)(large_base + half_len), half_len) != 0) {
        fail("upper-half munmap");
        return 14;
    }

    printf("LARGEMMAPPROBE-OK\n");
    return 0;
}
