// s4stress.c - S4f restricted-SMP resource churn workload.
//
// Runs under the current S2h secondary-EL0 gate: QEMU -smp 4 keeps secondary
// timers active while this CPU0 user process repeatedly drives kernel resource
// paths that S4 has just protected.

#include "lib/syscall.h"
#include "lib/fs.h"

int puts_raw(const char *s);

#ifndef O_TRUNC
#define O_TRUNC 0x80
#endif

static const unsigned long pageSize = 4096;

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

static size_t str_len(const char *s) {
    size_t n = 0;
    while (s[n] != 0) {
        n += 1;
    }
    return n;
}

static void append_prefix(char *dst, const char *prefix, int *pos) {
    for (int i = 0; prefix[i] != 0; i += 1) {
        dst[*pos] = prefix[i];
        *pos += 1;
    }
}

static void append_two_digits(char *dst, int round, int *pos) {
    dst[*pos] = (char)('0' + ((round / 10) % 10));
    *pos += 1;
    dst[*pos] = (char)('0' + (round % 10));
    *pos += 1;
}

static void make_file_path(char *dst, int round, char suffix) {
    int pos = 0;
    append_prefix(dst, "/tmp/s4f-", &pos);
    append_two_digits(dst, round, &pos);
    dst[pos] = suffix;
    pos += 1;
    dst[pos] = 0;
}

static void make_dir_path(char *dst, int round) {
    int pos = 0;
    append_prefix(dst, "/tmp/s4fdir-", &pos);
    append_two_digits(dst, round, &pos);
    dst[pos] = 0;
}

static int fail(const char *msg) {
    puts_raw("S4F-FAIL ");
    puts_raw(msg);
    puts_raw("\n");
    return 1;
}

static int tmpfs_fail(const char *msg) {
    puts_raw("S4F-TMPFS-FAIL ");
    puts_raw(msg);
    puts_raw("\n");
    return 0;
}

static int alloc_round(int round) {
    char *mem = (char *)mmap(0, pageSize, PROT_READ | PROT_WRITE,
                             MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mem == (char *)MAP_FAILED) {
        return 0;
    }
    for (unsigned long i = 0; i < pageSize; i += 257) {
        mem[i] = (char)('A' + ((round + (int)i) % 23));
    }
    for (unsigned long i = 0; i < pageSize; i += 257) {
        char want = (char)('A' + ((round + (int)i) % 23));
        if (mem[i] != want) {
            munmap(mem, pageSize);
            return 0;
        }
    }
    return munmap(mem, pageSize) == 0;
}

static int pipe_round(int round) {
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

    const char *msg = "s4f-pipe-payload\n";
    size_t len = str_len(msg);
    if (!write_all(fds[1], msg, len)) {
        close(rfd);
        close(fds[1]);
        return 0;
    }
    close(fds[1]);

    char buf[32];
    int ok = read_exact(rfd, buf, len) && bytes_eq(buf, msg, len);
    close(rfd);
    (void)round;
    return ok;
}

static int tmpfs_round(int round) {
    const char *pathA = "/tmp/s4f-live-a";
    const char *pathB = "/tmp/s4f-live-b";
    char dirPath[32];
    char unlinkPath[32];

    if (round == 0) {
        unlink(pathA);
        unlink(pathB);
    }

    int fd = open(pathA, (round == 0 ? O_CREAT : O_TRUNC) | O_RDWR);
    if (fd < 0) {
        return tmpfs_fail("open-create");
    }
    const char *payload = "s4f-tmpfs-payload\n";
    size_t len = str_len(payload);
    if (!write_all(fd, payload, len)) {
        close(fd);
        unlink(pathA);
        return tmpfs_fail("write");
    }
    close(fd);

    if (rename(pathA, pathB) != 0) {
        if (round == 0) {
            unlink(pathA);
            unlink(pathB);
        }
        return tmpfs_fail("rename");
    }

    fd = open(pathB, O_RDONLY);
    if (fd < 0) {
        unlink(pathB);
        return tmpfs_fail("open-read");
    }
    char buf[32];
    int ok = read_exact(fd, buf, len) && bytes_eq(buf, payload, len);
    struct stat st;
    ok = ok && fstat(fd, &st) == 0 && st.st_size == len;
    if (!ok) {
        close(fd);
        unlink(pathB);
        return tmpfs_fail("read-or-stat");
    }
    close(fd);
    if (rename(pathB, pathA) != 0) {
        return tmpfs_fail("rename-back");
    }

    if ((round & 3) == 1) {
        make_file_path(unlinkPath, round / 4, 'u');
        unlink(unlinkPath);
        fd = open(unlinkPath, O_CREAT | O_RDWR);
        if (fd < 0) {
            return tmpfs_fail("unlink-smoke-create");
        }
        if (!write_all(fd, payload, len)) {
            close(fd);
            unlink(unlinkPath);
            return tmpfs_fail("unlink-smoke-write");
        }
        close(fd);
        if (unlink(unlinkPath) != 0) {
            return tmpfs_fail("unlink-smoke");
        }
    }

    if ((round & 3) == 0) {
        make_dir_path(dirPath, round);
        rmdir(dirPath);
        if (mkdir(dirPath, 0) != 0) {
            return tmpfs_fail("mkdir");
        }
        if (rmdir(dirPath) != 0) {
            return tmpfs_fail("rmdir");
        }
    }
    return 1;
}

static int fork_round(void) {
    int fds[2];
    if (pipe(fds) != 0) {
        return 0;
    }
    int pid = fork();
    if (pid < 0) {
        close(fds[0]);
        close(fds[1]);
        return 0;
    }
    if (pid == 0) {
        close(fds[0]);
        const char *msg = "s4f-child\n";
        int ok = write_all(fds[1], msg, str_len(msg));
        close(fds[1]);
        _exit(ok ? 17 : 41);
    }

    close(fds[1]);
    const char *msg = "s4f-child\n";
    char buf[16];
    int ok = read_exact(fds[0], buf, str_len(msg)) &&
             bytes_eq(buf, msg, str_len(msg));
    close(fds[0]);

    int status = 0;
    int waited = waitpid(pid, &status, 0);
    ok = ok && waited == pid && ((status >> 8) & 0xff) == 17;
    return ok;
}

static int spawn_round(void) {
    char *argv[] = { "argvdemo", "s4f", 0 };
    return spawn("/bin/argvdemo", argv) == 2;
}

int main(void) {
    puts_raw("S4F-START restricted resource stress\n");
    for (int round = 0; round < 16; round += 1) {
        if (!alloc_round(round)) {
            return fail("alloc");
        }
        if (!pipe_round(round)) {
            return fail("pipe");
        }
        if (!tmpfs_round(round)) {
            return fail("tmpfs");
        }
        if ((round & 3) == 0 && !fork_round()) {
            return fail("fork");
        }
        if ((round & 3) == 2 && !spawn_round()) {
            return fail("spawn");
        }
    }
    puts_raw("S4F-ALLOC-OK\n");
    puts_raw("S4F-PIPE-OK\n");
    puts_raw("S4F-TMPFS-OK\n");
    puts_raw("S4F-FORK-OK\n");
    puts_raw("S4F-SPAWN-OK\n");
    puts_raw("S4F-OK resource stress completed\n");
    return 0;
}
