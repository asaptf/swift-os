// SPDX-License-Identifier: Apache-2.0
// slotscanstress.c - concurrent full-table scan vs process-slot grow/shrink.
//
// Exercises the interleaving that makes reclaimable slot segments dangerous on
// SMP (and under preemption even on a single core):
//
//   * scanner workers hammer SYS_PSINFO / SYS_SYSINFO / SYS_PROCSTAT (the
//     full-table walks that used to sample capacity then walk without the
//     storage lock);
//   * churn workers fork past kInitialProcessSlots and reap so trailing
//     segments grow and return to the PMM.
//
// Pass: no panic, every scanner/churn child exits 0, and free memory after the
// final churn cycle returns to approximately the pre-churn baseline (reclaim
// still works). A green run is evidence the race is closed for exercised
// interleavings, not a formal proof of absence of every possible schedule.

#include "lib/syscall.h"
#include "lib/fs.h"

int puts_raw(const char *s);

// Past kInitialProcessSlots (64) so growth + shrink actually allocate/free a
// trailing PMM segment.
#define CHURN_BATCH 80
#define CHURN_ROUNDS 6
#define SCAN_ROUNDS 400
#define SCAN_WORKERS 3
#define CHURN_WORKERS 2
#define MEM_TOLERANCE_BYTES (512UL * 1024)

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

static int fail(const char *msg) {
    puts_raw("SLOTSCAN-FAIL ");
    puts_raw(msg);
    puts_raw("\n");
    return 1;
}

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

// Full-table scanners: keep capacity samples and mid-walks concurrent with
// segment free. Also check that successive psinfo totals stay non-negative and
// that sysinfo returns 0 (consistent enough for the harness).
static int scanner_worker(int id) {
    unsigned char psbuf[32 * 128];
    unsigned char statbuf[56 * 128];
    unsigned char sysbuf[64 + 8 + (8 * 16)];
    int last_total = -1;

    for (int round = 0; round < SCAN_ROUNDS; round += 1) {
        long n = __syscall3(SYS_PSINFO, (long)psbuf, 128, 0);
        if (n < 0) {
            return fail("psinfo");
        }
        if (last_total >= 0 && n == 0) {
            // Table never empty while we and the shell live; a zero with a live
            // scanner would mean a broken walk or freed-underfoot garbage.
            return fail("psinfo-empty");
        }
        last_total = (int)n;

        long s = __syscall3(SYS_SYSINFO, (long)sysbuf, (long)sizeof(sysbuf), 0);
        if (s < 0) {
            return fail("sysinfo");
        }

        long p = __syscall3(SYS_PROCSTAT, (long)statbuf, 128, 0);
        if (p < 0) {
            return fail("procstat");
        }
        if (p != n && p + 4 < n) {
            // Counts can move underfoot between syscalls; only flag a gross
            // divergence that suggests corrupted storage rather than churn.
            return fail("ps-procstat-diverge");
        }

        // Brief sleep so a churn worker can grow/shrink between walks.
        if ((round & 7) == 0) {
            (void)__syscall3(SYS_NANOSLEEP, 0, 1, 0);
        }
    }

    puts_raw("SLOTSCAN-SCANNER-OK id=");
    put_uint((unsigned long)id);
    puts_raw(" last_n=");
    put_uint((unsigned long)last_total);
    puts_raw("\n");
    return 0;
}

static int churn_worker(int id) {
    for (int round = 0; round < CHURN_ROUNDS; round += 1) {
        int block[2];
        if (pipe(block) != 0) {
            return fail("churn-pipe");
        }
        int pids[CHURN_BATCH];
        int n = 0;
        while (n < CHURN_BATCH) {
            int pid = fork();
            if (pid < 0) {
                close(block[1]);
                close(block[0]);
                for (int i = 0; i < n; i += 1) {
                    int st = 0;
                    (void)waitpid(pids[i], &st, 0);
                }
                return fail("churn-fork");
            }
            if (pid == 0) {
                close(block[1]);
                char c;
                (void)read(block[0], &c, 1);
                _exit(0);
            }
            pids[n++] = pid;
        }
        close(block[1]);
        close(block[0]);
        for (int i = 0; i < n; i += 1) {
            int st = 0;
            if (waitpid(pids[i], &st, 0) != pids[i]) {
                return fail("churn-reap");
            }
        }
        (void)__syscall3(SYS_NANOSLEEP, 0, 1, 0);
    }

    puts_raw("SLOTSCAN-CHURN-OK id=");
    put_uint((unsigned long)id);
    puts_raw("\n");
    return 0;
}

int main(void) {
    puts_raw("SLOTSCAN-START scan+shrink concurrency stress\n");

    // Warm-up so one-time subsystem tables are not charged against baseline.
    {
        int w = fork();
        if (w < 0) {
            return fail("warmup-fork");
        }
        if (w == 0) {
            _exit(0);
        }
        int st = 0;
        if (waitpid(w, &st, 0) != w) {
            return fail("warmup-reap");
        }
    }

    unsigned long before = read_memfree();
    if (before == 0) {
        return fail("sysinfo-unavailable");
    }

    enum { NWORKERS = SCAN_WORKERS + CHURN_WORKERS };
    int kids[NWORKERS];
    int k = 0;

    for (int i = 0; i < SCAN_WORKERS; i += 1) {
        int pid = fork();
        if (pid < 0) {
            return fail("spawn-scanner");
        }
        if (pid == 0) {
            _exit(scanner_worker(i));
        }
        kids[k++] = pid;
    }
    for (int i = 0; i < CHURN_WORKERS; i += 1) {
        int pid = fork();
        if (pid < 0) {
            return fail("spawn-churn");
        }
        if (pid == 0) {
            _exit(churn_worker(i));
        }
        kids[k++] = pid;
    }

    int failed = 0;
    for (int i = 0; i < k; i += 1) {
        int st = 0;
        if (waitpid(kids[i], &st, 0) != kids[i]) {
            failed = 1;
            (void)fail("worker-reap");
            continue;
        }
        // WEXITSTATUS-style: low 8 bits of the status word we store as
        // (code & 0xff) << 8 on normal exit.
        int code = (st >> 8) & 0xff;
        if (code != 0) {
            failed = 1;
            puts_raw("SLOTSCAN-FAIL worker-exit code=");
            put_uint((unsigned long)code);
            puts_raw("\n");
        }
    }
    if (failed) {
        return 1;
    }

    // One more grow/reap alone so free-memory return is measurable after the
    // concurrent workers (which may still have been scanning during reaps).
    {
        int block[2];
        if (pipe(block) != 0) {
            return fail("final-pipe");
        }
        int pids[CHURN_BATCH];
        int n = 0;
        while (n < CHURN_BATCH) {
            int pid = fork();
            if (pid < 0) {
                close(block[1]);
                close(block[0]);
                for (int i = 0; i < n; i += 1) {
                    int st = 0;
                    (void)waitpid(pids[i], &st, 0);
                }
                return fail("final-fork");
            }
            if (pid == 0) {
                close(block[1]);
                char c;
                (void)read(block[0], &c, 1);
                _exit(0);
            }
            pids[n++] = pid;
        }
        close(block[1]);
        close(block[0]);
        for (int i = 0; i < n; i += 1) {
            int st = 0;
            if (waitpid(pids[i], &st, 0) != pids[i]) {
                return fail("final-reap");
            }
        }
    }

    unsigned long after = read_memfree();
    if (abs_diff(before, after) > MEM_TOLERANCE_BYTES) {
        puts_raw("SLOTSCAN-FAIL mem-leak before=");
        put_uint(before);
        puts_raw(" after=");
        put_uint(after);
        puts_raw("\n");
        return 1;
    }

    puts_raw("SLOTSCAN-MEM before=");
    put_uint(before);
    puts_raw(" after=");
    put_uint(after);
    puts_raw("\n");
    puts_raw("SLOTSCAN-OK scan+shrink concurrency completed\n");
    return 0;
}
