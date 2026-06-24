// SPDX-License-Identifier: Apache-2.0
// edgestress.c - coarse memory-edge-case stress (milestone 3 of the stress arc).
//
// Targets the two memory edge cases that production load eventually finds but
// that ordinary churn misses, and asserts GRACEFUL behaviour + LEAK BALANCE
// rather than trying to literally trigger the overflow (e.g. a UInt16 COW
// refcount needs 65535 sharers - infeasible to fork; the kernel already caps the
// increment). Free-frame accounting is read from the kernel via sysinfo(), so a
// per-iteration page-table or refcount leak accumulates far beyond measurement
// noise across many rounds.
//
//   A. Sparse page-table pressure: reserve a large lazy region and touch one page
//      every 2 MiB so each touch forces a fresh leaf page table, then unmap. The
//      free-frame count must return to baseline - i.e. munmap reclaims the
//      intermediate page-table frames, not just the data frames. Also asserts an
//      absurdly large reservation is refused gracefully (MAP_FAILED, no panic)
//      and that the arena recovers afterwards.
//
//   B. COW fork lifecycle: map a private page, fork, have the child write it
//      (taking the copy-on-write fault) and verify isolation from the parent,
//      then reap. Repeated many times; the free-frame count must return to
//      baseline, proving the COW refcount inc-on-fork / dec-on-exit path leaks
//      no frames.
//
// Non-goal: nested-signal kernel-stack overflow. Deliberately not exercised -
// actually overflowing the 8 KiB kernel stack would corrupt the kernel, and
// signal-mask / nested-delivery semantics are still incomplete (roadmap risk #5).

#include "lib/syscall.h"
#include "lib/fs.h"

int puts_raw(const char *s);

static const unsigned long pageSize = 4096;
#define STRIDE (2UL * 1024 * 1024)   // 2 MiB: one fresh leaf page table per touch
#define SPARSE_RESERVE (512UL * 1024 * 1024) // 512 MiB lazy reservation
#define SPARSE_ROUNDS 3
#define COW_ROUNDS 96
// Free-RAM tolerance for measurement noise (other quiescent tasks). A real leak
// over the round counts above would dwarf this.
#define TOLERANCE_BYTES (256UL * 1024)

static int fail(const char *msg) {
    puts_raw("EDGE-FAIL ");
    puts_raw(msg);
    puts_raw("\n");
    return 1;
}

static void put_uint(unsigned long v) {
    char buf[24];
    int pos = 24;
    buf[--pos] = 0;
    if (v == 0) {
        buf[--pos] = '0';
    } else {
        while (v != 0 && pos > 0) {
            buf[--pos] = (char)('0' + (int)(v % 10));
            v /= 10;
        }
    }
    puts_raw(&buf[pos]);
}

// Read system free memory (bytes) from sysinfo offset 24. Returns 0 on error.
static unsigned long read_memfree(void) {
    unsigned char buf[64];
    for (int i = 0; i < 64; i += 1) {
        buf[i] = 0;
    }
    long rc = __syscall3(SYS_SYSINFO, (long)buf, 64, 0);
    if (rc < 0) {
        return 0;
    }
    unsigned long v = 0;
    for (int i = 0; i < 8; i += 1) {
        v |= ((unsigned long)buf[24 + i]) << (8 * i);
    }
    return v;
}

static unsigned long abs_diff(unsigned long a, unsigned long b) {
    return a > b ? a - b : b - a;
}

// One sparse round: a large LAZY reservation (PROT_NONE so no frames are
// committed up front - a normal RW mmap here would eagerly commit the whole span
// and ENOMEM on a 256 MiB box), then commit one page per 2 MiB stride via
// MAP_FIXED so each committed page lands in its own leaf page table. Verify, then
// unmap the whole reservation - which must reclaim both the data frames and the
// intermediate page-table frames (the leak-balance check in main proves it does).
static int sparse_round(int round) {
    char *base = (char *)mmap(0, SPARSE_RESERVE, PROT_NONE,
                              MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (base == (char *)MAP_FAILED) {
        return fail("sparse-reserve");
    }
    for (unsigned long off = 0; off + pageSize <= SPARSE_RESERVE; off += STRIDE) {
        void *p = mmap(base + off, pageSize, PROT_READ | PROT_WRITE,
                       MAP_FIXED | MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p != (void *)(base + off)) {
            munmap(base, SPARSE_RESERVE);
            return fail("sparse-commit");
        }
        base[off] = (char)('A' + ((round + (int)(off / STRIDE)) % 23));
    }
    for (unsigned long off = 0; off + pageSize <= SPARSE_RESERVE; off += STRIDE) {
        char want = (char)('A' + ((round + (int)(off / STRIDE)) % 23));
        if (base[off] != want) {
            munmap(base, SPARSE_RESERVE);
            return fail("sparse-verify");
        }
    }
    if (munmap(base, SPARSE_RESERVE) != 0) {
        return fail("sparse-munmap");
    }
    return 0;
}

// One COW round: map a private page, fork, child COW-writes + verifies isolation.
static int cow_round(int round) {
    char *page = (char *)mmap(0, pageSize, PROT_READ | PROT_WRITE,
                              MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (page == (char *)MAP_FAILED) {
        return fail("cow-mmap");
    }
    char parentVal = (char)('P' + (round % 16));
    char childVal = (char)('c' + (round % 16));
    page[0] = parentVal;

    int pid = fork();
    if (pid < 0) {
        munmap(page, pageSize);
        return fail("cow-fork");
    }
    if (pid == 0) {
        // Child shares the page COW. It must first see the parent's value, then
        // its own write must take effect locally (the COW fault).
        int ok = (page[0] == parentVal);
        page[0] = childVal;
        ok = ok && (page[0] == childVal);
        _exit(ok ? 0 : 1);
    }

    int status = 0;
    if (waitpid(pid, &status, 0) != pid) {
        munmap(page, pageSize);
        return fail("cow-reap");
    }
    if (((status >> 8) & 0xff) != 0) {
        munmap(page, pageSize);
        return fail("cow-child-view");
    }
    // Isolation: the child's write must NOT have leaked into the parent's page.
    if (page[0] != parentVal) {
        munmap(page, pageSize);
        return fail("cow-isolation");
    }
    if (munmap(page, pageSize) != 0) {
        return fail("cow-munmap");
    }
    return 0;
}

int main(void) {
    puts_raw("EDGE-START coarse memory edge-case stress\n");

    // --- A: sparse page-table pressure -------------------------------------
    // Warm up once so any one-time lazy kernel-heap growth is excluded from the
    // baseline, then measure across the real rounds.
    if (sparse_round(0) != 0) {
        return 1;
    }
    unsigned long beforeSparse = read_memfree();
    if (beforeSparse == 0) {
        return fail("sysinfo-unavailable");
    }
    for (int r = 0; r < SPARSE_ROUNDS; r += 1) {
        if (sparse_round(r + 1) != 0) {
            return 1;
        }
    }
    unsigned long afterSparse = read_memfree();
    if (abs_diff(beforeSparse, afterSparse) > TOLERANCE_BYTES) {
        puts_raw("EDGE-FAIL sparse-leak before=");
        put_uint(beforeSparse);
        puts_raw(" after=");
        put_uint(afterSparse);
        puts_raw("\n");
        return 1;
    }
    puts_raw("EDGE-SPARSE-OK\n");

    // Graceful refusal of an absurd reservation (far larger than the arena), then
    // recovery: a normal mapping must still succeed afterwards.
    void *huge = mmap(0, 100UL * 1024 * 1024 * 1024, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (huge != (void *)MAP_FAILED) {
        munmap(huge, 100UL * 1024 * 1024 * 1024);
        return fail("huge-mmap-not-refused");
    }
    char *recover = (char *)mmap(0, pageSize, PROT_READ | PROT_WRITE,
                                 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (recover == (char *)MAP_FAILED) {
        return fail("no-recover-after-huge");
    }
    recover[0] = 'z';
    if (recover[0] != 'z' || munmap(recover, pageSize) != 0) {
        return fail("recover-broken");
    }
    puts_raw("EDGE-GRACEFUL-OK\n");

    // --- B: COW fork lifecycle ---------------------------------------------
    if (cow_round(0) != 0) {
        return 1;
    }
    unsigned long beforeCow = read_memfree();
    for (int r = 0; r < COW_ROUNDS; r += 1) {
        if (cow_round(r + 1) != 0) {
            return 1;
        }
    }
    unsigned long afterCow = read_memfree();
    if (abs_diff(beforeCow, afterCow) > TOLERANCE_BYTES) {
        puts_raw("EDGE-FAIL cow-leak before=");
        put_uint(beforeCow);
        puts_raw(" after=");
        put_uint(afterCow);
        puts_raw("\n");
        return 1;
    }
    puts_raw("EDGE-COW-OK\n");

    puts_raw("EDGE-OK coarse memory edge-case stress completed\n");
    return 0;
}
