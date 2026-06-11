// mapfixedprobe.c - C/newlib proof for MAP_FIXED anonymous reservation flows.

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

typedef int (*jit_fn_t)(void);

static void fail(const char *msg) {
    printf("mapfixedprobe: FAIL: %s errno=%d\n", msg, errno);
}

static int expect_zero(volatile unsigned char *p, size_t len, size_t stride) {
    for (size_t off = 0; off < len; off += stride) {
        if (p[off] != 0) {
            printf("mapfixedprobe: FAIL: nonzero byte at %lu value=%u\n",
                   (unsigned long)off, (unsigned)p[off]);
            return 0;
        }
    }
    if (p[len - 1] != 0) {
        printf("mapfixedprobe: FAIL: nonzero final byte value=%u\n",
               (unsigned)p[len - 1]);
        return 0;
    }
    return 1;
}

static int write_pattern(volatile unsigned char *p, size_t len, size_t stride) {
    for (size_t off = 0; off < len; off += stride) {
        p[off] = (unsigned char)((off / stride) + 23u);
    }
    p[len - 1] = 0x7e;
    for (size_t off = 0; off < len; off += stride) {
        unsigned char want = (unsigned char)((off / stride) + 23u);
        if (p[off] != want) {
            printf("mapfixedprobe: FAIL: pattern mismatch at %lu got=%u want=%u\n",
                   (unsigned long)off, (unsigned)p[off], (unsigned)want);
            return 0;
        }
    }
    if (p[len - 1] != 0x7e) {
        printf("mapfixedprobe: FAIL: final pattern mismatch got=%u\n",
               (unsigned)p[len - 1]);
        return 0;
    }
    return 1;
}

int main(void) {
    const size_t page = 4096;
    const size_t reserve_len = 8u * 1024u * 1024u;
    const size_t window_len = 1024u * 1024u;
    const unsigned char code[] = {
        0x40, 0x05, 0x80, 0x52,  /* mov w0, #42 */
        0xc0, 0x03, 0x5f, 0xd6   /* ret */
    };

    void *reserve = mmap(0, reserve_len, PROT_NONE,
                         MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (reserve == MAP_FAILED) {
        fail("PROT_NONE arena reserve");
        return 1;
    }
    printf("mapfixedprobe: reserve arena OK\n");

    unsigned char *base = (unsigned char *)reserve;
    unsigned char *guard = base + page;
    unsigned char *window = base + (2u * 1024u * 1024u);
    unsigned char *jit = base + (4u * 1024u * 1024u);

    void *fixed = mmap(window, window_len, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    if (fixed != window) {
        fail("MAP_FIXED commit window");
        (void)munmap(reserve, reserve_len);
        return 2;
    }
    if (!expect_zero((volatile unsigned char *)window, window_len, page)) {
        (void)munmap(reserve, reserve_len);
        return 3;
    }
    if (!write_pattern((volatile unsigned char *)window, window_len, page)) {
        (void)munmap(reserve, reserve_len);
        return 4;
    }
    printf("mapfixedprobe: fixed commit RW OK\n");

    errno = 0;
    void *noreplace = mmap(window, page, PROT_READ | PROT_WRITE,
                           MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
    if (noreplace != MAP_FAILED) {
        printf("mapfixedprobe: FAIL: MAP_FIXED_NOREPLACE overwrote existing range\n");
        (void)munmap(reserve, reserve_len);
        return 5;
    }
    printf("mapfixedprobe: NOREPLACE overlap OK errno=%d\n", errno);

    void *replace = mmap(window, page, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    if (replace != window) {
        fail("MAP_FIXED replace live page");
        (void)munmap(reserve, reserve_len);
        return 6;
    }
    if (!expect_zero((volatile unsigned char *)window, page, page)) {
        (void)munmap(reserve, reserve_len);
        return 7;
    }
    printf("mapfixedprobe: fixed replace zero-fill OK\n");

    if (mprotect(guard, page, PROT_READ | PROT_WRITE) != 0) {
        fail("guard commit RW");
        (void)munmap(reserve, reserve_len);
        return 8;
    }
    guard[0] = 0x5a;
    guard[page - 1] = 0xa5;
    void *guard_none = mmap(guard, page, PROT_NONE,
                            MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    if (guard_none != guard) {
        fail("guard MAP_FIXED PROT_NONE");
        (void)munmap(reserve, reserve_len);
        return 9;
    }
    void *guard_rw = mmap(guard, page, PROT_READ | PROT_WRITE,
                          MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    if (guard_rw != guard) {
        fail("guard MAP_FIXED recommit");
        (void)munmap(reserve, reserve_len);
        return 10;
    }
    if (!expect_zero((volatile unsigned char *)guard, page, page)) {
        (void)munmap(reserve, reserve_len);
        return 11;
    }
    printf("mapfixedprobe: fixed guard recommit zero-fill OK\n");

    void *jit_map = mmap(jit, page, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    if (jit_map != jit) {
        fail("jit MAP_FIXED RW");
        (void)munmap(reserve, reserve_len);
        return 12;
    }
    memcpy(jit, code, sizeof(code));
    if (mprotect(jit, page, PROT_READ | PROT_EXEC) != 0) {
        fail("jit fixed RW->RX");
        (void)munmap(reserve, reserve_len);
        return 13;
    }
    int result = ((jit_fn_t)(uintptr_t)jit)();
    if (result != 42) {
        printf("mapfixedprobe: FAIL: fixed jit returned %d\n", result);
        (void)munmap(reserve, reserve_len);
        return 14;
    }
    printf("mapfixedprobe: fixed JIT RW-RX OK\n");

    errno = 0;
    void *rwx = mmap(jit, page, PROT_READ | PROT_WRITE | PROT_EXEC,
                     MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    if (rwx != MAP_FAILED) {
        printf("mapfixedprobe: FAIL: W^X breach MAP_FIXED RWX allowed\n");
        (void)munmap(reserve, reserve_len);
        return 15;
    }
    printf("mapfixedprobe: W^X fixed mmap OK errno=%d\n", errno);

    if (munmap(reserve, reserve_len) != 0) {
        fail("munmap arena");
        return 16;
    }
    printf("MAPFIXEDPROBE-OK\n");
    return 0;
}
