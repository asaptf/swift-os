// mmapreserveprobe.c - C/newlib proof for lazy anonymous mmap reservations.

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

typedef int (*jit_fn_t)(void);

static void fail(const char *msg) {
    printf("mmapreserveprobe: FAIL: %s errno=%d\n", msg, errno);
}

static int expect_zero(volatile unsigned char *p, size_t len, size_t stride) {
    for (size_t off = 0; off < len; off += stride) {
        if (p[off] != 0) {
            printf("mmapreserveprobe: FAIL: nonzero byte at %lu value=%u\n",
                   (unsigned long)off, (unsigned)p[off]);
            return 0;
        }
    }
    if (p[len - 1] != 0) {
        printf("mmapreserveprobe: FAIL: nonzero final byte value=%u\n",
               (unsigned)p[len - 1]);
        return 0;
    }
    return 1;
}

static int write_pattern(volatile unsigned char *p, size_t len, size_t stride) {
    for (size_t off = 0; off < len; off += stride) {
        p[off] = (unsigned char)((off / stride) + 17u);
    }
    p[len - 1] = 0xc3;
    for (size_t off = 0; off < len; off += stride) {
        unsigned char want = (unsigned char)((off / stride) + 17u);
        if (p[off] != want) {
            printf("mmapreserveprobe: FAIL: pattern mismatch at %lu got=%u want=%u\n",
                   (unsigned long)off, (unsigned)p[off], (unsigned)want);
            return 0;
        }
    }
    if (p[len - 1] != 0xc3) {
        printf("mmapreserveprobe: FAIL: final pattern mismatch got=%u\n",
               (unsigned)p[len - 1]);
        return 0;
    }
    return 1;
}

int main(void) {
    const size_t page = 4096;
    const size_t reserve_len = 16u * 1024u * 1024u;
    const size_t commit_len = 1024u * 1024u;
    const unsigned char code[] = {
        0x40, 0x05, 0x80, 0x52,  /* mov w0, #42 */
        0xc0, 0x03, 0x5f, 0xd6   /* ret */
    };

    void *reserve = mmap(0, reserve_len, PROT_NONE,
                         MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (reserve == MAP_FAILED) {
        fail("PROT_NONE reserve");
        return 1;
    }
    printf("mmapreserveprobe: reserve PROT_NONE OK\n");

    unsigned char *base = (unsigned char *)reserve;
    unsigned char *mid = base + (4u * 1024u * 1024u);
    if (mprotect(mid, commit_len, PROT_READ | PROT_WRITE) != 0) {
        fail("commit middle RW");
        (void)munmap(reserve, reserve_len);
        return 2;
    }
    if (!expect_zero((volatile unsigned char *)mid, commit_len, page)) {
        (void)munmap(reserve, reserve_len);
        return 3;
    }
    if (!write_pattern((volatile unsigned char *)mid, commit_len, page)) {
        (void)munmap(reserve, reserve_len);
        return 4;
    }
    printf("mmapreserveprobe: commit middle RW OK\n");

    if (mprotect(mid, commit_len, PROT_NONE) != 0) {
        fail("decommit middle");
        (void)munmap(reserve, reserve_len);
        return 5;
    }
    if (mprotect(mid, commit_len, PROT_READ | PROT_WRITE) != 0) {
        fail("recommit middle");
        (void)munmap(reserve, reserve_len);
        return 6;
    }
    if (!expect_zero((volatile unsigned char *)mid, commit_len, page)) {
        (void)munmap(reserve, reserve_len);
        return 7;
    }
    printf("mmapreserveprobe: decommit recommit zero-fill OK\n");

    unsigned char *jit = base + (8u * 1024u * 1024u);
    if (mprotect(jit, page, PROT_READ | PROT_WRITE) != 0) {
        fail("commit jit RW");
        (void)munmap(reserve, reserve_len);
        return 8;
    }
    memcpy(jit, code, sizeof(code));
    if (mprotect(jit, page, PROT_READ | PROT_EXEC) != 0) {
        fail("jit RW->RX");
        (void)munmap(reserve, reserve_len);
        return 9;
    }
    int result = ((jit_fn_t)(uintptr_t)jit)();
    if (result != 42) {
        printf("mmapreserveprobe: FAIL: jit returned %d\n", result);
        (void)munmap(reserve, reserve_len);
        return 10;
    }
    printf("mmapreserveprobe: reserved JIT RW-RX OK\n");

    errno = 0;
    if (mprotect(jit, page, PROT_READ | PROT_WRITE | PROT_EXEC) == 0) {
        printf("mmapreserveprobe: FAIL: W^X breach mprotect RWX allowed\n");
        (void)munmap(reserve, reserve_len);
        return 11;
    }
    printf("mmapreserveprobe: W^X over reservation OK errno=%d\n", errno);

    if (munmap(reserve, reserve_len) != 0) {
        fail("munmap reserve");
        return 12;
    }
    printf("MMAPRESERVEPROBE-OK\n");
    return 0;
}
