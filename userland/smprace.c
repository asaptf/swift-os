// SPDX-License-Identifier: Apache-2.0
// smprace.c - concurrent cross-CPU resource-churn workload.
//
// Designed to run as N simultaneous copies placed on different CPUs by the
// kernel's S5f run-any placement primitive (see runSmpRaceStressDemo in
// kernel/main.swift). While the copies execute in parallel they hammer the
// shared kernel resource pools that the S4 series put behind locks - the
// physical-frame allocator (mmap/munmap), the VFS node/open-description tables
// and tmpfs (create/write/read/unlink), and the pipe pool (pipe/dup/close).
//
// The point is to put MORE THAN ONE CPU inside those locked paths at the same
// instant, which a CPU0-only userland stress (s4stress/satstress) cannot do.
// Correctness is asserted by the kernel after every copy is reaped: the S4a-S4e
// lock-boundary guards must still be balanced and pmm_free_count must return to
// its pre-churn baseline (runSmpRaceStressDemo checks both). Each copy also
// self-checks its own round-trips and prints a per-pid OK/FAIL line so the test
// harness can confirm every placed copy actually ran to completion.

#include "lib/syscall.h"
#include "lib/fs.h"

int puts_raw(const char *s);

#ifndef O_TRUNC
#define O_TRUNC 0x80
#endif

#define ITERATIONS 48
static const unsigned long pageSize = 4096;

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

static int child_fail(int pid, const char *msg) {
    puts_raw("SMPRACE-CHILD-FAIL pid=");
    put_uint((unsigned long)pid);
    puts_raw(" ");
    puts_raw(msg);
    puts_raw("\n");
    return 1;
}

static size_t str_len(const char *s) {
    size_t n = 0;
    while (s[n] != 0) {
        n += 1;
    }
    return n;
}

static int write_all(int fd, const char *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        long n = write(fd, buf + off, len - off);
        if (n <= 0) {
            return 0;
        }
        off += (size_t)n;
    }
    return 1;
}

static int read_exact(int fd, char *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        long n = read(fd, buf + off, len - off);
        if (n <= 0) {
            return 0;
        }
        off += (size_t)n;
    }
    return 1;
}

static int bytes_eq(const char *a, const char *b, size_t len) {
    for (size_t i = 0; i < len; i += 1) {
        if (a[i] != b[i]) {
            return 0;
        }
    }
    return 1;
}

// /tmp/smprace-<pid> path builder (pid < 10000).
static void make_path(char *dst, int pid) {
    int pos = 0;
    const char *p = "/tmp/smprace-";
    while (*p) {
        dst[pos++] = *p++;
    }
    if (pid >= 1000) dst[pos++] = (char)('0' + (pid / 1000) % 10);
    if (pid >= 100) dst[pos++] = (char)('0' + (pid / 100) % 10);
    if (pid >= 10) dst[pos++] = (char)('0' + (pid / 10) % 10);
    dst[pos++] = (char)('0' + pid % 10);
    dst[pos] = 0;
}

// One round of frame-allocator churn: map two pages, touch + verify, unmap.
static int mmap_round(int round) {
    char *mem = (char *)mmap(0, pageSize * 2, PROT_READ | PROT_WRITE,
                             MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mem == (char *)MAP_FAILED) {
        return 0;
    }
    for (unsigned long i = 0; i < pageSize * 2; i += 251) {
        mem[i] = (char)('A' + ((round + (int)i) % 23));
    }
    for (unsigned long i = 0; i < pageSize * 2; i += 251) {
        char want = (char)('A' + ((round + (int)i) % 23));
        if (mem[i] != want) {
            munmap(mem, pageSize * 2);
            return 0;
        }
    }
    return munmap(mem, pageSize * 2) == 0;
}

// One round of VFS/tmpfs churn: create, write, read back, verify, unlink.
static int tmpfs_round(const char *path) {
    int fd = open(path, O_CREAT | O_TRUNC | O_RDWR);
    if (fd < 0) {
        return 0;
    }
    const char *payload = "smprace-payload\n";
    size_t len = str_len(payload);
    if (!write_all(fd, payload, len)) {
        close(fd);
        unlink(path);
        return 0;
    }
    close(fd);

    fd = open(path, O_RDONLY);
    if (fd < 0) {
        unlink(path);
        return 0;
    }
    char buf[32];
    int ok = read_exact(fd, buf, len) && bytes_eq(buf, payload, len);
    close(fd);
    if (unlink(path) != 0) {
        ok = 0;
    }
    return ok;
}

// One round of pipe-pool churn: create, dup, round-trip a payload, close.
static int pipe_round(void) {
    int fds[2];
    if (pipe(fds) != 0) {
        return 0;
    }
    int rfd = dup(fds[0]);
    if (rfd < 0) {
        close(fds[0]);
        close(fds[1]);
        return 0;
    }
    close(fds[0]);
    const char *msg = "smprace-pipe\n";
    size_t len = str_len(msg);
    if (!write_all(fds[1], msg, len)) {
        close(rfd);
        close(fds[1]);
        return 0;
    }
    close(fds[1]);
    char buf[16];
    int ok = read_exact(rfd, buf, len) && bytes_eq(buf, msg, len);
    close(rfd);
    return ok;
}

int main(void) {
    int pid = getpid();
    char path[32];
    make_path(path, pid);

    for (int round = 0; round < ITERATIONS; round += 1) {
        if (!mmap_round(round)) {
            return child_fail(pid, "mmap");
        }
        if (!tmpfs_round(path)) {
            return child_fail(pid, "tmpfs");
        }
        if (!pipe_round()) {
            return child_fail(pid, "pipe");
        }
    }

    puts_raw("SMPRACE-CHILD-OK pid=");
    put_uint((unsigned long)pid);
    puts_raw("\n");
    return 0;
}
