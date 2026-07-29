// SPDX-License-Identifier: Apache-2.0
// satstress.c - fixed-size kernel-pool saturation stress.
//
// For each bounded kernel resource pool that a single EL0 process can safely
// drive to its ceiling and then fully release, this workload proves TWO things
// the product profiles depend on:
//   1. graceful saturation - hitting the cap returns a clean negative errno
//      (ENOMEM/EMFILE/ENOSPC/EAGAIN), never a kernel panic or a wedged
//      allocator; and
//   2. baseline return - once the held resources are released, the pool is
//      usable again (no slot leak), so a transient load spike cannot
//      permanently degrade the system.
//
// Pools exercised (limits as of this writing; the test does not hard-code them,
// it discovers the ceiling where a fixed ceiling still exists): per-process fds
// (maxFDs=512), pipes (maxPipes=16), IPC endpoints (maxEndpoints=32). The process
// table is growable from kInitialProcessSlots with no fixed ceiling (PT3a/PT3b):
// growth is PMM-backed and reclaimable, and refuses when free physical frames
// would fall below a kernel reserve. The process case therefore:
//   - forks a fixed batch past the initial capacity, reaps, and asserts free
//     physical memory returns to roughly the pre-bomb level (reclaim);
//   - under artificial memory pressure, asserts fork fails with EAGAIN and the
//     system keeps running (admission).
// A vnode create/unlink churn confirms the tmpfs node pool stays balanced under
// repeated allocation without driving the *shared* table to global exhaustion.

#include "lib/syscall.h"
#include "lib/fs.h"

int puts_raw(const char *s);

// Must exceed kInitialProcessSlots (64 in process.swift) so the process table is
// forced to grow at least once. Not a "cap must engage" guard — see
// saturate_processes().
#define PROC_BATCH 80
// Upper guards for pools that still have a fixed ceiling. Each is comfortably
// above the real kernel limit, so reaching it means the cap did NOT engage.
#define FD_GUARD 1024
#define PIPE_GUARD 64
#define ENDPOINT_GUARD 64
#define VNODE_CHURN 256

// Free-RAM tolerance for measurement noise (other quiescent tasks, one-time
// bumps). A leaked process-slot segment is multiple pages and dwarfs this.
#define MEM_TOLERANCE_BYTES (512UL * 1024)

// POSIX EAGAIN as returned by the raw fork syscall (negative errno).
#define FORK_EAGAIN (-11)

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
    puts_raw("SAT-FAIL ");
    puts_raw(msg);
    puts_raw("\n");
    return 1;
}

static void ok_count(const char *prefix, unsigned long n) {
    puts_raw(prefix);
    put_uint(n);
    puts_raw("\n");
}

// /tmp/sat-v-<i> path builder (i < 1000).
static void make_vnode_path(char *dst, int i) {
    int pos = 0;
    const char *p = "/tmp/sat-v-";
    while (*p) {
        dst[pos++] = *p++;
    }
    if (i >= 100) {
        dst[pos++] = (char)('0' + (i / 100) % 10);
    }
    if (i >= 10) {
        dst[pos++] = (char)('0' + (i / 10) % 10);
    }
    dst[pos++] = (char)('0' + i % 10);
    dst[pos] = 0;
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

// --- Processes: fixed batch past initial capacity, then reclaim. -------------
//
// Proves growth past the initial capacity (PROC_BATCH live children), full
// reclaim, baseline fork recovery, free-memory return (PT3b: segment pages go
// back to the PMM), and no panic across the run.
static int saturate_processes(void) {
    // Warm-up fork so one-time subsystem tables are not charged against the
    // free-memory baseline we are about to capture.
    {
        int w = fork();
        if (w < 0) {
            return fail("proc-warmup-fork");
        }
        if (w == 0) {
            _exit(0);
        }
        int st = 0;
        if (waitpid(w, &st, 0) != w) {
            return fail("proc-warmup-reap");
        }
    }

    unsigned long before = read_memfree();
    if (before == 0) {
        return fail("proc-sysinfo-unavailable");
    }

    int block[2];
    if (pipe(block) != 0) {
        return fail("proc-pipe-setup");
    }
    int pids[PROC_BATCH];
    int n = 0;
    while (n < PROC_BATCH) {
        int pid = fork();
        if (pid < 0) {
            // Every fork in the batch must succeed: refusal mid-batch means
            // growth or slot allocation failed under a load that should fit.
            // Drop the barrier so already-spawned children exit, then reap.
            close(block[1]);
            close(block[0]);
            for (int i = 0; i < n; i += 1) {
                int status = 0;
                (void)waitpid(pids[i], &status, 0);
            }
            return fail("proc-fork-refused");
        }
        if (pid == 0) {
            // Child: drop the write end and block on the barrier pipe so it
            // holds its process slot until the parent releases everyone.
            close(block[1]);
            char c;
            read(block[0], &c, 1);
            _exit(0);
        }
        pids[n++] = pid;
    }

    // Peak free memory should be strictly lower while the grown segment and
    // live children hold frames (observability for the before/after report).
    unsigned long during = read_memfree();

    // Release: closing every write end unblocks each child's read -> they exit.
    close(block[1]);
    close(block[0]);
    for (int i = 0; i < n; i += 1) {
        int status = 0;
        if (waitpid(pids[i], &status, 0) != pids[i]) {
            return fail("proc-reap");
        }
    }

    // Baseline return: a fork must succeed now that the children are reaped.
    int pid = fork();
    if (pid < 0) {
        return fail("proc-no-recover");
    }
    if (pid == 0) {
        _exit(0);
    }
    int status = 0;
    if (waitpid(pid, &status, 0) != pid) {
        return fail("proc-recover-reap");
    }

    unsigned long after = read_memfree();
    if (abs_diff(before, after) > MEM_TOLERANCE_BYTES) {
        puts_raw("SAT-FAIL proc-mem-leak before=");
        put_uint(before);
        puts_raw(" during=");
        put_uint(during);
        puts_raw(" after=");
        put_uint(after);
        puts_raw("\n");
        return 1;
    }

    ok_count("SAT-PROC-OK n=", (unsigned long)n);
    puts_raw("SAT-PROC-MEM before=");
    put_uint(before);
    puts_raw(" during=");
    put_uint(during);
    puts_raw(" after=");
    put_uint(after);
    puts_raw("\n");
    return 0;
}

// --- Admission: under memory pressure fork must fail with EAGAIN. ------------
//
// A helper child pins free physical frames below the process-slot growth reserve
// so the parent's address space stays small (cheap COW). The parent then forks
// until table growth is required and refused with EAGAIN (raw -11). Never a
// panic; after release the system must fork again.
static int saturate_admission(void) {
    unsigned long page = 4096;
    enum { ADMIT_GUARD = 512 };

    // Pipe 1: parent -> hog: "release and exit".
    // Pipe 2: hog -> parent: "memory is pinned".
    int release_pipe[2];
    int ready_pipe[2];
    if (pipe(release_pipe) != 0 || pipe(ready_pipe) != 0) {
        return fail("admit-pipe");
    }

    int hog = fork();
    if (hog < 0) {
        return fail("admit-hog-fork");
    }
    if (hog == 0) {
        close(release_pipe[1]);
        close(ready_pipe[0]);
        unsigned long free_now = read_memfree();
        // Leave ~6 MiB free: reserve is 8 MiB, so a new slot segment cannot be
        // admitted. Child kstacks for a small parent still fit in the cushion.
        unsigned long leave_free = 6UL * 1024 * 1024;
        unsigned long grab = free_now > leave_free ? free_now - leave_free : 0;
        grab = (grab / page) * page;
        if (grab >= page) {
            char *blob = (char *)mmap(0, grab, PROT_READ | PROT_WRITE,
                                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
            if (blob != (char *)MAP_FAILED) {
                for (unsigned long off = 0; off < grab; off += page) {
                    blob[off] = (char)(off & 0xff);
                }
            }
        }
        // Signal parent, then park until released.
        char ok = 'R';
        write(ready_pipe[1], &ok, 1);
        close(ready_pipe[1]);
        char c;
        read(release_pipe[0], &c, 1);
        _exit(0);
    }

    close(release_pipe[0]);
    close(ready_pipe[1]);
    char ready = 0;
    if (read(ready_pipe[0], &ready, 1) != 1) {
        close(release_pipe[1]);
        close(ready_pipe[0]);
        int st = 0;
        (void)waitpid(hog, &st, 0);
        return fail("admit-hog-ready");
    }
    close(ready_pipe[0]);

    // Parent is still small. Fork until growth is refused (EAGAIN). Cap so a
    // missing admission check cannot run forever.
    int block[2];
    if (pipe(block) != 0) {
        close(release_pipe[1]);
        int st = 0;
        (void)waitpid(hog, &st, 0);
        return fail("admit-block-pipe");
    }

    int pids[ADMIT_GUARD];
    int n = 0;
    int refused = 0;
    int refused_errno = 0;
    while (n < ADMIT_GUARD) {
        int pid = fork();
        if (pid < 0) {
            refused = 1;
            refused_errno = pid;
            break;
        }
        if (pid == 0) {
            close(block[1]);
            close(release_pipe[1]);
            char c;
            read(block[0], &c, 1);
            _exit(0);
        }
        pids[n++] = pid;
    }

    close(block[1]);
    close(block[0]);
    for (int i = 0; i < n; i += 1) {
        int status = 0;
        (void)waitpid(pids[i], &status, 0);
    }

    // Release the hog's pin.
    char go = 'X';
    write(release_pipe[1], &go, 1);
    close(release_pipe[1]);
    {
        int st = 0;
        (void)waitpid(hog, &st, 0);
    }

    if (!refused) {
        return fail("admit-never-engaged");
    }
    if (refused_errno != FORK_EAGAIN) {
        puts_raw("SAT-FAIL admit-bad-errno got=");
        put_uint((unsigned long)(long)(-refused_errno));
        puts_raw("\n");
        return 1;
    }

    // System keeps running: fork must succeed after pressure is released.
    int pid = fork();
    if (pid < 0) {
        return fail("admit-no-recover");
    }
    if (pid == 0) {
        _exit(0);
    }
    int status = 0;
    if (waitpid(pid, &status, 0) != pid) {
        return fail("admit-recover-reap");
    }

    ok_count("SAT-ADMIT-OK refused_after_n=", (unsigned long)n);
    return 0;
}

// --- File descriptors: dup one fd until the per-process table refuses. -------
static int saturate_fds(void) {
    int base = open("/tmp/sat-fd", O_CREAT | O_RDWR);
    if (base < 0) {
        return fail("fd-base-open");
    }
    int fds[FD_GUARD];
    int n = 0;
    while (n < FD_GUARD) {
        int fd = dup(base);
        if (fd < 0) {
            break; // graceful EMFILE.
        }
        fds[n++] = fd;
    }

    if (n == 0) {
        close(base);
        return fail("fd-no-dups");
    }
    if (n >= FD_GUARD) {
        for (int i = 0; i < n; i += 1) {
            close(fds[i]);
        }
        close(base);
        return fail("fd-cap-never-engaged");
    }

    for (int i = 0; i < n; i += 1) {
        if (close(fds[i]) != 0) {
            close(base);
            return fail("fd-close");
        }
    }

    // Baseline return: a dup must succeed again.
    int again = dup(base);
    if (again < 0) {
        close(base);
        return fail("fd-no-recover");
    }
    close(again);
    close(base);
    unlink("/tmp/sat-fd");
    ok_count("SAT-FD-OK n=", (unsigned long)n);
    return 0;
}

// --- Pipes: create until the global pipe pool refuses, then reclaim. ---------
static int saturate_pipes(void) {
    int ends[PIPE_GUARD][2];
    int n = 0;
    while (n < PIPE_GUARD) {
        if (pipe(ends[n]) != 0) {
            break; // graceful pool exhaustion.
        }
        n += 1;
    }

    if (n == 0) {
        return fail("pipe-none");
    }
    int cap_engaged = (n < PIPE_GUARD);

    for (int i = 0; i < n; i += 1) {
        close(ends[i][0]);
        close(ends[i][1]);
    }
    if (!cap_engaged) {
        return fail("pipe-cap-never-engaged");
    }

    // Baseline return.
    int p[2];
    if (pipe(p) != 0) {
        return fail("pipe-no-recover");
    }
    close(p[0]);
    close(p[1]);
    ok_count("SAT-PIPE-OK n=", (unsigned long)n);
    return 0;
}

// --- IPC endpoints: create until the endpoint pool refuses, then reclaim. ----
static int saturate_endpoints(void) {
    int ends[ENDPOINT_GUARD][2];
    int n = 0;
    while (n < ENDPOINT_GUARD) {
        if (endpoint_create(ends[n]) != 0) {
            break; // graceful pool exhaustion.
        }
        n += 1;
    }

    if (n == 0) {
        return fail("endpoint-none");
    }
    int cap_engaged = (n < ENDPOINT_GUARD);

    for (int i = 0; i < n; i += 1) {
        close(ends[i][0]);
        close(ends[i][1]);
    }
    if (!cap_engaged) {
        return fail("endpoint-cap-never-engaged");
    }

    // Baseline return.
    int e[2];
    if (endpoint_create(e) != 0) {
        return fail("endpoint-no-recover");
    }
    close(e[0]);
    close(e[1]);
    ok_count("SAT-ENDPOINT-OK n=", (unsigned long)n);
    return 0;
}

// --- Vnode churn: repeated create/unlink stays balanced (no slot leak). ------
static int saturate_vnodes(void) {
    char path[24];
    for (int round = 0; round < 2; round += 1) {
        for (int i = 0; i < VNODE_CHURN; i += 1) {
            make_vnode_path(path, i);
            int fd = open(path, O_CREAT | O_RDWR);
            if (fd < 0) {
                return fail("vnode-create");
            }
            close(fd);
        }
        for (int i = 0; i < VNODE_CHURN; i += 1) {
            make_vnode_path(path, i);
            if (unlink(path) != 0) {
                return fail("vnode-unlink");
            }
        }
    }
    puts_raw("SAT-VNODE-OK\n");
    return 0;
}

int main(void) {
    puts_raw("SAT-START fixed-size pool saturation\n");
    if (saturate_processes() != 0) {
        return 1;
    }
    if (saturate_admission() != 0) {
        return 1;
    }
    if (saturate_fds() != 0) {
        return 1;
    }
    if (saturate_pipes() != 0) {
        return 1;
    }
    if (saturate_endpoints() != 0) {
        return 1;
    }
    if (saturate_vnodes() != 0) {
        return 1;
    }
    puts_raw("SAT-OK fixed-size pool saturation completed\n");
    return 0;
}
