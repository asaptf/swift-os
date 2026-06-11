// stubs.c — link-time POSIX surface for busybox on swift-os newlib.
//
// Implements (or safely stubs) the functions our compat headers declare and
// busybox references but newlib lacks. Everything is `weak`, so a real newlib
// symbol always wins and there are never duplicate-definition link errors;
// where newlib has nothing, these fill the gap. Real behaviour is provided over
// our syscall ABI where it matters (dirent via getdents, termios via 7/8,
// fork/exec/wait); the rest are benign ENOSYS-style stubs.

#include <sys/types.h>
#include <sys/stat.h>
#include <sys/resource.h>
#include <sys/time.h>
#include <sys/uio.h>
#include <errno.h>
#include <stdarg.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <termios.h>
#include <time.h>
#include <pwd.h>
#include <grp.h>
#include <sys/utsname.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <net/if.h>
#include <signal.h>

#define W __attribute__((weak))

extern char **environ;

static long sys3(long n, long a0, long a1, long a2) {
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a0;
    register long x1 __asm__("x1") = a1;
    register long x2 __asm__("x2") = a2;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
    return x0;
}

#define SYS_READ 2
#define SYS_WRITE 3
#define SYS_LSEEK 6
#define SYS_TCGETATTR 7
#define SYS_TCSETATTR 8
#define SYS_WAITPID 13
#define SYS_GETDENTS 16
#define SYS_FORK 20
#define SYS_EXECVE 21
#define SYS_DUP 23
#define SYS_DUP2 24
#define SYS_PIPE 25
#define SYS_POLL 26
#define SYS_UNLINK 27
#define SYS_RENAME 28
#define SYS_MKDIR 29
#define SYS_RMDIR 30
#define SYS_FTRUNCATE 33
#define SYS_FCNTL 34
#define SYS_CHOWN 36
#define SYS_TIME 37
#define SYS_SOCKET 38
#define SYS_BIND 39
#define SYS_SENDTO 40
#define SYS_RECVFROM 41
#define SYS_LISTEN 42
#define SYS_ACCEPT 43
#define SYS_CONNECT 44
#define SYS_RESOLVE 45
#define SYS_SYSINFO 46
#define SYS_MMAP 54
#define SYS_MUNMAP 55
#define SYS_NANOSLEEP 57

static int sysret(long r) {
    if (r < 0) { errno = (int)-r; return -1; }
    return (int)r;
}

static long sysret_long(long r) {
    if (r < 0) { errno = (int)-r; return -1; }
    return r;
}

#ifndef EAFNOSUPPORT
#define EAFNOSUPPORT 97
#endif
#ifndef EPROTONOSUPPORT
#define EPROTONOSUPPORT 93
#endif
#ifndef EOPNOTSUPP
#define EOPNOTSUPP 95
#endif
#ifndef ENOTSOCK
#define ENOTSOCK 88
#endif
#ifndef EDESTADDRREQ
#define EDESTADDRREQ 89
#endif
#ifndef ENOPROTOOPT
#define ENOPROTOOPT 92
#endif

// newlib's fcntl (sysfcntl.o) is a hard ENOSYS stub that never reaches a syscall
// stub, so override the symbol here (strong, pulled before libc). The busybox
// shell saves/restores descriptors around redirects with F_DUPFD_CLOEXEC; the
// kernel handles the command set (kernel/vfs/vfs.swift vfsFcntl).
int fcntl(int fd, int cmd, ...) {
    va_list ap;
    va_start(ap, cmd);
    int arg = va_arg(ap, int);
    va_end(ap);
    return sysret(sys3(SYS_FCNTL, fd, cmd, arg));
}

// ---- process ---------------------------------------------------------------
W pid_t fork(void) { return (pid_t)sys3(SYS_FORK, 0, 0, 0); }
W pid_t vfork(void) { return (pid_t)sys3(SYS_FORK, 0, 0, 0); }
W int execve(const char *path, char *const argv[], char *const envp[]) {
    return (int)sys3(SYS_EXECVE, (long)path, (long)argv, (long)envp);
}
W int execv(const char *path, char *const argv[]) { return execve(path, argv, environ); }
W int execvp(const char *file, char *const argv[]) {
    if (strchr(file, '/')) { return execve(file, argv, environ); }
    char buf[128];
    // Try /bin/<file> then /<file>.
    buf[0] = '/'; buf[1] = 'b'; buf[2] = 'i'; buf[3] = 'n'; buf[4] = '/';
    size_t n = strlen(file);
    if (n < sizeof(buf) - 6) { memcpy(buf + 5, file, n + 1); execve(buf, argv, environ); }
    buf[0] = '/'; if (n < sizeof(buf) - 2) { memcpy(buf + 1, file, n + 1); execve(buf, argv, environ); }
    errno = ENOENT;
    return -1;
}
W int execvpe(const char *file, char *const argv[], char *const envp[]) {
    (void)envp; return execvp(file, argv);
}
W pid_t waitpid(pid_t pid, int *status, int options) {
    return (pid_t)sys3(SYS_WAITPID, pid, (long)status, options);
}
W pid_t wait(int *status) { return waitpid(-1, status, 0); }

// ---- ids / process groups (single-user; we are root) -----------------------
W uid_t getuid(void) { return 0; }
W uid_t geteuid(void) { return 0; }
W gid_t getgid(void) { return 0; }
W gid_t getegid(void) { return 0; }
W int setuid(uid_t u) { (void)u; return 0; }
W int setgid(gid_t g) { (void)g; return 0; }
W int seteuid(uid_t u) { (void)u; return 0; }
W int setegid(gid_t g) { (void)g; return 0; }
W int getgroups(int n, gid_t *l) { (void)n; (void)l; return 0; }
W int initgroups(const char *user, gid_t group) { (void)user; (void)group; return 0; }
W pid_t getppid(void) { return 1; }
W pid_t setsid(void) { return 0; }
W int setpgid(pid_t a, pid_t b) { (void)a; (void)b; return 0; }
W pid_t getpgrp(void) { return 1; }
W pid_t getpgid(pid_t p) { (void)p; return 1; }
W pid_t tcgetpgrp(int fd) { (void)fd; return 1; }
W int tcsetpgrp(int fd, pid_t pgrp) { (void)fd; (void)pgrp; return 0; }
// newlib has no getpagesize; libbb/procps.c and coreutils/dd.c reference it.
W int getpagesize(void) { return 4096; }
// No on-disk mode bits to change: base files are read-only and tmpfs nodes get
// their mode at creation (kernel/vfs/vfs.swift). busybox mkdir chmod()s the new
// directory to the requested mode; accepting it as a no-op leaves the kernel's
// 0755 default, which is what mkdir wants anyway.
W int chmod(const char *path, mode_t m) { (void)path; (void)m; return 0; }
W int fchmod(int fd, mode_t m) { (void)fd; (void)m; return 0; }

// ---- passwd / group (resolved from /etc/passwd + /etc/group) ---------------
// busybox `ls -l` (FEATURE_LS_USERNAME) maps st_uid/st_gid to names via these.
// We parse the generated compat views so owners show as "root"/"user"/… ; an
// unknown id returns NULL and busybox falls back to printing the number.

// Copy at most cap-1 bytes of [s, end) into dst and NUL-terminate.
static void copy_field(char *dst, size_t cap, const char *s, const char *end) {
    size_t n = (size_t)(end - s);
    if (n >= cap) n = cap - 1;
    memcpy(dst, s, n);
    dst[n] = 0;
}

// Split a colon-delimited line in place into up to max fields (pointers into
// the line buffer); returns the field count. Trailing newline is trimmed.
static int split_colon(char *line, char **fields, int max) {
    int n = 0;
    char *p = line;
    fields[n++] = p;
    while (*p && n < max) {
        if (*p == ':') { *p = 0; fields[n++] = p + 1; }
        p++;
    }
    // Trim newline from the last field.
    for (char *q = fields[n - 1]; *q; q++) {
        if (*q == '\n' || *q == '\r') { *q = 0; break; }
    }
    return n;
}

static struct passwd g_pw;
static char g_pw_name[64], g_pw_dir[64], g_pw_shell[64];

// Find a /etc/passwd line by uid (byUid != 0) or by name. Returns &g_pw or NULL.
static struct passwd *pw_lookup(int byUid, uid_t uid, const char *name) {
    FILE *f = fopen("/etc/passwd", "r");
    if (!f) return 0;
    char line[256];
    struct passwd *res = 0;
    while (fgets(line, sizeof(line), f)) {
        if (line[0] == '#' || line[0] == '\n') continue;
        char *fl[7];
        if (split_colon(line, fl, 7) < 4) continue;   // name:passwd:uid:gid:...
        char *endp;
        long fuid = strtol(fl[2], &endp, 10);
        int match = byUid ? (fuid == (long)uid) : (strcmp(fl[0], name) == 0);
        if (!match) continue;
        copy_field(g_pw_name, sizeof(g_pw_name), fl[0], fl[0] + strlen(fl[0]));
        g_pw.pw_name = g_pw_name;
        g_pw.pw_passwd = (char *)"x";
        g_pw.pw_uid = (uid_t)fuid;
        g_pw.pw_gid = (gid_t)strtol(fl[3], &endp, 10);
        g_pw.pw_comment = (char *)"";
        g_pw.pw_gecos = (char *)"";
        g_pw.pw_dir = g_pw_dir; g_pw_dir[0] = 0;
        g_pw.pw_shell = g_pw_shell; g_pw_shell[0] = 0;
        res = &g_pw;
        break;
    }
    fclose(f);
    return res;
}

W struct passwd *getpwuid(uid_t uid) { return pw_lookup(1, uid, 0); }
W struct passwd *getpwnam(const char *name) { return pw_lookup(0, 0, name); }
W struct passwd *getpwent(void) { return 0; }
W void setpwent(void) {}
W void endpwent(void) {}

static struct group g_gr;
static char g_gr_name[64];
static char *g_gr_mem[1] = { 0 };

// Find an /etc/group line by gid (byGid != 0) or by name. Returns &g_gr or NULL.
static struct group *gr_lookup(int byGid, gid_t gid, const char *name) {
    FILE *f = fopen("/etc/group", "r");
    if (!f) return 0;
    char line[256];
    struct group *res = 0;
    while (fgets(line, sizeof(line), f)) {
        if (line[0] == '#' || line[0] == '\n') continue;
        char *fl[4];
        if (split_colon(line, fl, 4) < 3) continue;    // name:passwd:gid:members
        char *endp;
        long fgid = strtol(fl[2], &endp, 10);
        int match = byGid ? (fgid == (long)gid) : (strcmp(fl[0], name) == 0);
        if (!match) continue;
        copy_field(g_gr_name, sizeof(g_gr_name), fl[0], fl[0] + strlen(fl[0]));
        g_gr.gr_name = g_gr_name;
        g_gr.gr_passwd = (char *)"x";
        g_gr.gr_gid = (gid_t)fgid;
        g_gr.gr_mem = g_gr_mem;
        res = &g_gr;
        break;
    }
    fclose(f);
    return res;
}

W struct group *getgrgid(gid_t gid) { return gr_lookup(1, gid, 0); }
W struct group *getgrnam(const char *name) { return gr_lookup(0, 0, name); }
W struct group *getgrent(void) { return 0; }
W void setgrent(void) {}
W void endgrent(void) {}

// ---- directories over getdents --------------------------------------------
struct DIR { int fd; long pos; long len; char buf[2048]; };
W DIR *opendir(const char *name) {
    int fd = open(name, 0 /*O_RDONLY*/);
    if (fd < 0) { return 0; }
    DIR *d = (DIR *)malloc(sizeof(DIR));
    if (!d) { close(fd); return 0; }
    d->fd = fd; d->pos = 0; d->len = 0;
    return d;
}
W struct dirent *readdir(DIR *d) {
    if (!d) { return 0; }
    if (d->pos >= d->len) {
        long n = sys3(SYS_GETDENTS, d->fd, (long)d->buf, (long)sizeof(d->buf));
        if (n <= 0) { return 0; }
        d->len = n; d->pos = 0;
    }
    struct dirent *de = (struct dirent *)(d->buf + d->pos);
    d->pos += de->d_reclen;
    return de;
}
W int closedir(DIR *d) { if (!d) { return -1; } int fd = d->fd; free(d); return close(fd); }
W int dirfd(DIR *d) { return d ? d->fd : -1; }
W void rewinddir(DIR *d) { if (d) { d->pos = d->len = 0; lseek(d->fd, 0, 0); } }

// ---- termios over syscalls 7/8 --------------------------------------------
W int tcgetattr(int fd, struct termios *t) { (void)fd; return (int)sys3(SYS_TCGETATTR, fd, (long)t, 0); }
W int tcsetattr(int fd, int act, const struct termios *t) { return (int)sys3(SYS_TCSETATTR, fd, act, (long)t); }
W int tcflush(int fd, int q) { (void)fd; (void)q; return 0; }
W int tcdrain(int fd) { (void)fd; return 0; }
W int tcsendbreak(int fd, int d) { (void)fd; (void)d; return 0; }
W int tcflow(int fd, int a) { (void)fd; (void)a; return 0; }
W speed_t cfgetispeed(const struct termios *t) { return t ? t->c_ispeed : 0; }
W speed_t cfgetospeed(const struct termios *t) { return t ? t->c_ospeed : 0; }
W int cfsetispeed(struct termios *t, speed_t s) { if (t) t->c_ispeed = s; return 0; }
W int cfsetospeed(struct termios *t, speed_t s) { if (t) t->c_ospeed = s; return 0; }
W void cfmakeraw(struct termios *t) { if (t) { t->c_lflag &= ~(ICANON | ECHO | ISIG); } }

// ---- ioctl (terminal queries busybox/ash make) -----------------------------
W int ioctl(int fd, unsigned long req, ...) {
    __builtin_va_list ap;
    __builtin_va_start(ap, req);
    void *arg = __builtin_va_arg(ap, void *);
    __builtin_va_end(ap);
    switch (req) {
    case 0x5413: { // TIOCGWINSZ
        unsigned short *ws = (unsigned short *)arg; // row, col, xpix, ypix
        if (ws) { ws[0] = 24; ws[1] = 80; ws[2] = 0; ws[3] = 0; }
        return 0;
    }
    case 0x5401: return tcgetattr(fd, (struct termios *)arg); // TCGETS
    case 0x5402: return tcsetattr(fd, 0, (struct termios *)arg); // TCSETS
    default: return 0;
    }
}

// ---- misc libc gaps --------------------------------------------------------
W int ftruncate(int fd, off_t length) { return sysret(sys3(SYS_FTRUNCATE, fd, (long)length, 0)); }
W int lstat(const char *path, struct stat *st) { return stat(path, st); }
W int mknod(const char *p, mode_t m, dev_t d) { (void)p; (void)m; (void)d; errno = ENOSYS; return -1; }
W int uname(struct utsname *u) {
    if (!u) { errno = EFAULT; return -1; }
    strcpy(u->sysname, "swift-os"); strcpy(u->nodename, "swiftos");
    strcpy(u->release, "0.1"); strcpy(u->version, "M8"); strcpy(u->machine, "aarch64");
    return 0;
}
W int clearenv(void) { if (environ) environ[0] = 0; return 0; }
struct swiftos_sysinfo_legacy {
    unsigned long uptime_ticks;
    unsigned long idle_ticks;
    unsigned long mem_total;
    unsigned long mem_free;
    unsigned long kernel_image;
    unsigned long kernel_heap;
    unsigned int hz;
    unsigned int proc_total;
    unsigned int proc_running;
    unsigned int reserved;
};

static int swiftos_monotonic_timespec(struct timespec *tp, unsigned int *hz_out) {
    struct swiftos_sysinfo_legacy info;
    memset(&info, 0, sizeof(info));
    long r = sys3(SYS_SYSINFO, (long)&info, sizeof(info), 0);
    if (r < 0) { return sysret(r); }
    if (info.hz == 0) { errno = EIO; return -1; }
    if (hz_out) { *hz_out = info.hz; }
    if (tp) {
        unsigned long ticks = info.uptime_ticks;
        unsigned long hz = info.hz;
        tp->tv_sec = (time_t)(ticks / hz);
        tp->tv_nsec = (long)(((ticks % hz) * 1000000000UL) / hz);
    }
    return 0;
}

static int swiftos_realtime_timespec(struct timespec *tp) {
    long sec = sys3(SYS_TIME, 0, 0, 0);
    if (tp) {
        tp->tv_sec = (time_t)sec;
        tp->tv_nsec = 0;
    }
    return 0;
}

W int clock_gettime(clockid_t clock_id, struct timespec *tp) {
    if (!tp) { errno = EFAULT; return -1; }
    switch (clock_id) {
    case CLOCK_REALTIME:
    case CLOCK_REALTIME_COARSE:
        return swiftos_realtime_timespec(tp);
    case CLOCK_MONOTONIC:
    case CLOCK_MONOTONIC_RAW:
    case CLOCK_MONOTONIC_COARSE:
    case CLOCK_BOOTTIME:
        return swiftos_monotonic_timespec(tp, 0);
    default:
        errno = EINVAL;
        return -1;
    }
}

W int clock_getres(clockid_t clock_id, struct timespec *res) {
    switch (clock_id) {
    case CLOCK_REALTIME:
    case CLOCK_REALTIME_COARSE:
        if (res) { res->tv_sec = 1; res->tv_nsec = 0; }
        return 0;
    case CLOCK_MONOTONIC:
    case CLOCK_MONOTONIC_RAW:
    case CLOCK_MONOTONIC_COARSE:
    case CLOCK_BOOTTIME: {
        unsigned int hz = 0;
        if (swiftos_monotonic_timespec(0, &hz) < 0) { return -1; }
        if (res) {
            if (hz <= 1) {
                res->tv_sec = 1;
                res->tv_nsec = 0;
            } else {
                res->tv_sec = 0;
                res->tv_nsec = (long)(1000000000UL / hz);
                if (res->tv_nsec == 0) { res->tv_nsec = 1; }
            }
        }
        return 0;
    }
    default:
        errno = EINVAL;
        return -1;
    }
}

// Real blocking sleep over SYS_NANOSLEEP: the kernel parks us until the
// requested time elapses (resolution = one timer tick). The kernel never
// returns early (blocked syscalls aren't signal-interrupted yet), so there is
// no remaining time — zero *rem when asked.
W int nanosleep(const struct timespec *req, struct timespec *rem) {
    if (!req) { errno = EFAULT; return -1; }
    long r = sys3(SYS_NANOSLEEP, (long)req->tv_sec, (long)req->tv_nsec, 0);
    if (rem) { rem->tv_sec = 0; rem->tv_nsec = 0; }
    return sysret(r);
}
W int usleep(useconds_t usec) {
    struct timespec ts = { (time_t)(usec / 1000000UL), (long)((usec % 1000000UL) * 1000UL) };
    return nanosleep(&ts, 0);
}
W unsigned int sleep(unsigned int s) {
    struct timespec ts = { (time_t)s, 0 };
    nanosleep(&ts, 0);
    return 0; // no early wake, so no unslept remainder
}
W long sysconf(int name) {
    switch (name) {
    case 2: return 100;   // _SC_CLK_TCK
    case 8: return 4096;  // _SC_PAGESIZE (newlib value varies; harmless)
    case 4: return 32;    // _SC_OPEN_MAX
    default: return -1;
    }
}
W ssize_t getdelim(char **lineptr, size_t *n, int delim, FILE *stream) {
    if (!lineptr || !n) { errno = EINVAL; return -1; }
    if (!*lineptr || *n == 0) { *n = 128; *lineptr = (char *)malloc(*n); if (!*lineptr) return -1; }
    size_t len = 0;
    int c;
    while ((c = fgetc(stream)) != EOF) {
        if (len + 1 >= *n) { *n *= 2; char *p = (char *)realloc(*lineptr, *n); if (!p) return -1; *lineptr = p; }
        (*lineptr)[len++] = (char)c;
        if (c == delim) { break; }
    }
    if (len == 0) { return -1; }
    (*lineptr)[len] = 0;
    return (ssize_t)len;
}
W ssize_t getline(char **lineptr, size_t *n, FILE *stream) { return getdelim(lineptr, n, '\n', stream); }

W int sched_getaffinity(int pid, unsigned long sz, void *mask) { (void)pid; (void)sz; (void)mask; errno = ENOSYS; return -1; }
W int sched_setaffinity(int pid, unsigned long sz, const void *mask) { (void)pid; (void)sz; (void)mask; errno = ENOSYS; return -1; }
W int getrlimit(int r, struct rlimit *l) {
    if (!l) { errno = EFAULT; return -1; }
    switch (r) {
    case RLIMIT_NOFILE:
        l->rlim_cur = 32;
        l->rlim_max = 32;
        return 0;
    case RLIMIT_CORE:
        l->rlim_cur = 0;
        l->rlim_max = 0;
        return 0;
    case RLIMIT_STACK:
        l->rlim_cur = 8 * 1024 * 1024;
        l->rlim_max = 8 * 1024 * 1024;
        return 0;
    case RLIMIT_CPU:
    case RLIMIT_FSIZE:
    case RLIMIT_DATA:
    case RLIMIT_RSS:
    case RLIMIT_NPROC:
    case RLIMIT_MEMLOCK:
    case RLIMIT_AS:
        l->rlim_cur = RLIM_INFINITY;
        l->rlim_max = RLIM_INFINITY;
        return 0;
    default:
        errno = EINVAL;
        return -1;
    }
}
W int setrlimit(int r, const struct rlimit *l) { (void)r; (void)l; return 0; }
W int getrusage(int who, struct rusage *u) {
    (void)who;
    if (!u) { errno = EFAULT; return -1; }
    memset(u, 0, sizeof(*u));
    return 0;
}
W int getpriority(int w, id_t who) { (void)w; (void)who; return 0; }
W int setpriority(int w, id_t who, int p) { (void)w; (void)who; (void)p; return 0; }
W int statfs(const char *p, void *b) { (void)p; (void)b; errno = ENOSYS; return -1; }
W int fstatfs(int fd, void *b) { (void)fd; (void)b; errno = ENOSYS; return -1; }
W int sysinfo(void *info) { (void)info; errno = ENOSYS; return -1; }
W void *mmap(void *a, size_t l, int p, int f, int fd, long o) {
    (void)f; (void)fd; (void)o;
    long r = sys3(SYS_MMAP, (long)a, (long)l, p);
    if (r < 0 && r >= -4095) { errno = (int)-r; return (void *)-1; }
    return (void *)r;
}
W int munmap(void *a, size_t l) { return sysret(sys3(SYS_MUNMAP, (long)a, (long)l, 0)); }
W int poll(void *fds, unsigned long n, int timeout) { return sysret(sys3(SYS_POLL, (long)fds, (long)n, timeout)); }

W ssize_t readv(int fd, const struct iovec *iov, int iovcnt) {
    if (!iov || iovcnt < 0) { errno = EINVAL; return -1; }
    ssize_t total = 0;
    for (int i = 0; i < iovcnt; i++) {
        char *base = (char *)iov[i].iov_base;
        size_t left = iov[i].iov_len;
        while (left > 0) {
            size_t requested = left;
            ssize_t n = read(fd, base, left);
            if (n < 0) { return total > 0 ? total : -1; }
            if (n == 0) { return total; }
            total += n;
            base += n;
            left -= (size_t)n;
            if ((size_t)n < requested) { return total; }
        }
    }
    return total;
}

W ssize_t writev(int fd, const struct iovec *iov, int iovcnt) {
    if (!iov || iovcnt < 0) { errno = EINVAL; return -1; }
    ssize_t total = 0;
    for (int i = 0; i < iovcnt; i++) {
        const char *base = (const char *)iov[i].iov_base;
        size_t left = iov[i].iov_len;
        while (left > 0) {
            ssize_t n = write(fd, base, left);
            if (n < 0) { return total > 0 ? total : -1; }
            if (n == 0) { return total; }
            total += n;
            base += n;
            left -= (size_t)n;
        }
    }
    return total;
}

W ssize_t pwritev(int fd, const struct iovec *iov, int iovcnt, off_t offset) {
    off_t saved = lseek(fd, 0, SEEK_CUR);
    if (saved == (off_t)-1) { return -1; }
    if (lseek(fd, offset, SEEK_SET) == (off_t)-1) { return -1; }
    ssize_t r = writev(fd, iov, iovcnt);
    off_t ignored = lseek(fd, saved, SEEK_SET);
    (void)ignored;
    return r;
}
W int ppoll(void *fds, unsigned long n, const void *ts, const void *sig) {
    (void)sig;
    int timeout = -1;
    if (ts) {
        const long *p = (const long *)ts;
        timeout = (int)(p[0] * 1000 + p[1] / 1000000);
    }
    return poll(fds, n, timeout);
}

// ---- networking -----------------------------------------------------------
// POSIX-shaped wrappers over swift-os's intentionally small socket syscalls.
// The kernel ABI is not Linux: bind/connect take port/ip scalars, and UDP
// sendto/recvfrom carry their extra arguments in swiftos_udp_msg.
#define SOCKET_META_MAX 64
#define COMPAT_POLLIN  0x001
#define COMPAT_POLLOUT 0x004
#define COMPAT_POLLERR 0x008
#define COMPAT_POLLHUP 0x010
#define COMPAT_POLLNVAL 0x020

struct socket_meta { int used; int domain; int type; int protocol; int error; };
static struct socket_meta g_sockmeta[SOCKET_META_MAX];

struct swiftos_udp_msg {
    unsigned long buf;
    unsigned int len;
    unsigned int ip;       // host-order IPv4
    unsigned short port;   // host-order UDP port
    unsigned short pad;
};

struct __attribute__((packed)) swiftos_udp_msg_v6 {
    unsigned long buf;
    unsigned int len;
    unsigned char ip6[16];
    unsigned short port;   // host-order UDP port
    unsigned int scope;
};

struct compat_pollfd { int fd; short events; short revents; };

static int socket_type_base(int type) {
    return type & ~(SOCK_NONBLOCK | SOCK_CLOEXEC);
}

static void socket_meta_set(int fd, int domain, int type, int protocol) {
    if (fd < 0 || fd >= SOCKET_META_MAX) { return; }
    g_sockmeta[fd].used = 1;
    g_sockmeta[fd].domain = domain;
    g_sockmeta[fd].type = socket_type_base(type);
    g_sockmeta[fd].protocol = protocol;
    g_sockmeta[fd].error = 0;
}

static void socket_meta_copy(int dst, int src) {
    if (dst < 0 || dst >= SOCKET_META_MAX) { return; }
    if (src >= 0 && src < SOCKET_META_MAX && g_sockmeta[src].used) {
        g_sockmeta[dst] = g_sockmeta[src];
    } else {
        g_sockmeta[dst].used = 0;
    }
}

static struct socket_meta *socket_meta_get(int fd) {
    if (fd >= 0 && fd < SOCKET_META_MAX && g_sockmeta[fd].used) {
        return &g_sockmeta[fd];
    }
    return 0;
}

static int socket_protocol_ok(int type, int protocol) {
    if (protocol == 0) { return 1; }
    if (type == SOCK_STREAM) { return protocol == IPPROTO_TCP; }
    if (type == SOCK_DGRAM) { return protocol == IPPROTO_UDP; }
    return 0;
}

static int socket_ready_now(int fd, short events) {
    struct compat_pollfd p;
    p.fd = fd;
    p.events = events;
    p.revents = 0;
    long r = sys3(SYS_POLL, (long)&p, 1, 0);
    if (r < 0) { errno = (int)-r; return -1; }
    if (p.revents & COMPAT_POLLNVAL) { errno = EBADF; return -1; }
    if (p.revents & (events | COMPAT_POLLERR | COMPAT_POLLHUP)) { return 1; }
    errno = EAGAIN;
    return 0;
}

static int sockaddr_endpoint(const struct sockaddr *addr, socklen_t len,
                             unsigned int *ip, unsigned short *port) {
    if (!addr) { errno = EFAULT; return -1; }
    if (len < sizeof(sa_family_t)) { errno = EINVAL; return -1; }
    if (addr->sa_family == AF_INET) {
        const struct sockaddr_in *in = (const struct sockaddr_in *)addr;
        if (len < sizeof(*in)) { errno = EINVAL; return -1; }
        if (ip) { *ip = ntohl(in->sin_addr.s_addr); }
        if (port) { *port = ntohs(in->sin_port); }
        return AF_INET;
    }
    if (addr->sa_family == AF_INET6) {
        const struct sockaddr_in6 *in6 = (const struct sockaddr_in6 *)addr;
        if (len < sizeof(*in6)) { errno = EINVAL; return -1; }
        if (port) { *port = ntohs(in6->sin6_port); }
        return AF_INET6;
    }
    errno = EAFNOSUPPORT;
    return -1;
}

static void copy_sockaddr_out(struct sockaddr *addr, socklen_t *len,
                              const void *src, socklen_t srclen) {
    if (!addr || !len) { return; }
    socklen_t cap = *len < srclen ? *len : srclen;
    if (cap > 0) { memcpy(addr, src, cap); }
    *len = srclen;
}

static int write_sockopt_int(void *val, socklen_t *len, int value) {
    if (!val || !len) { errno = EFAULT; return -1; }
    if (*len < sizeof(int)) { errno = EINVAL; return -1; }
    *(int *)val = value;
    *len = sizeof(int);
    return 0;
}

W int socket(int domain, int type, int protocol) {
    int base = socket_type_base(type);
    if (domain != AF_INET && domain != AF_INET6) { errno = EAFNOSUPPORT; return -1; }
    if (base != SOCK_STREAM && base != SOCK_DGRAM) { errno = EPROTONOSUPPORT; return -1; }
    if (!socket_protocol_ok(base, protocol)) { errno = EPROTONOSUPPORT; return -1; }
    int fd = sysret(sys3(SYS_SOCKET, domain, base, protocol));
    if (fd >= 0) { socket_meta_set(fd, domain, base, protocol); }
    return fd;
}

W int bind(int fd, const struct sockaddr *addr, socklen_t len) {
    unsigned short port = 0;
    int family = sockaddr_endpoint(addr, len, 0, &port);
    if (family < 0) { return -1; }
    return sysret(sys3(SYS_BIND, fd, (long)port, 0));
}

W int connect(int fd, const struct sockaddr *addr, socklen_t len) {
    unsigned int ip = 0;
    unsigned short port = 0;
    int family = sockaddr_endpoint(addr, len, &ip, &port);
    if (family < 0) { return -1; }
    if (family != AF_INET) { errno = EAFNOSUPPORT; return -1; }
    return sysret(sys3(SYS_CONNECT, fd, (long)ip, (long)port));
}

W int listen(int fd, int backlog) {
    return sysret(sys3(SYS_LISTEN, fd, backlog, 0));
}

W int accept(int fd, struct sockaddr *addr, socklen_t *len) {
    if (addr && !len) { errno = EFAULT; return -1; }
    int cfd = sysret(sys3(SYS_ACCEPT, fd, 0, 0));
    if (cfd < 0) { return -1; }

    struct socket_meta *m = socket_meta_get(fd);
    int family = m ? m->domain : AF_INET;
    socket_meta_set(cfd, family, SOCK_STREAM, IPPROTO_TCP);

    if (addr && len) {
        if (family == AF_INET6) {
            struct sockaddr_in6 sa6;
            memset(&sa6, 0, sizeof(sa6));
            sa6.sin6_family = AF_INET6;
            copy_sockaddr_out(addr, len, &sa6, sizeof(sa6));
        } else {
            struct sockaddr_in sa;
            memset(&sa, 0, sizeof(sa));
            sa.sin_family = AF_INET;
            copy_sockaddr_out(addr, len, &sa, sizeof(sa));
        }
    }
    return cfd;
}

W long send(int fd, const void *buf, size_t n, int flags) {
    if (flags & ~(MSG_NOSIGNAL | MSG_DONTWAIT)) { errno = EOPNOTSUPP; return -1; }
    if ((flags & MSG_DONTWAIT) && socket_ready_now(fd, COMPAT_POLLOUT) <= 0) { return -1; }
    return sysret_long(sys3(SYS_WRITE, fd, (long)buf, (long)n));
}

W long recv(int fd, void *buf, size_t n, int flags) {
    if (flags & ~MSG_DONTWAIT) { errno = EOPNOTSUPP; return -1; }
    if ((flags & MSG_DONTWAIT) && socket_ready_now(fd, COMPAT_POLLIN) <= 0) { return -1; }
    return sysret_long(sys3(SYS_READ, fd, (long)buf, (long)n));
}

W long sendto(int fd, const void *buf, size_t n, int flags,
              const struct sockaddr *addr, socklen_t len) {
    if (flags & ~(MSG_NOSIGNAL | MSG_DONTWAIT)) { errno = EOPNOTSUPP; return -1; }
    struct socket_meta *m = socket_meta_get(fd);
    if (m && m->type == SOCK_STREAM) {
        if (addr) { errno = EOPNOTSUPP; return -1; }
        return send(fd, buf, n, flags);
    }
    if (!addr) { errno = EDESTADDRREQ; return -1; }
    if (n > 65507) { errno = EINVAL; return -1; }
    if ((flags & MSG_DONTWAIT) && socket_ready_now(fd, COMPAT_POLLOUT) <= 0) { return -1; }

    unsigned int ip = 0;
    unsigned short port = 0;
    int family = sockaddr_endpoint(addr, len, &ip, &port);
    if (family < 0) { return -1; }
    if (family == AF_INET6) {
        const struct sockaddr_in6 *in6 = (const struct sockaddr_in6 *)addr;
        struct swiftos_udp_msg_v6 msg;
        msg.buf = (unsigned long)buf;
        msg.len = (unsigned int)n;
        memcpy(msg.ip6, in6->sin6_addr.s6_addr, 16);
        msg.port = port;
        msg.scope = in6->sin6_scope_id;
        return sysret_long(sys3(SYS_SENDTO, fd, (long)&msg, 0));
    }

    struct swiftos_udp_msg msg;
    msg.buf = (unsigned long)buf;
    msg.len = (unsigned int)n;
    msg.ip = ip;
    msg.port = port;
    msg.pad = 0;
    return sysret_long(sys3(SYS_SENDTO, fd, (long)&msg, 0));
}

W long recvfrom(int fd, void *buf, size_t n, int flags,
                struct sockaddr *addr, socklen_t *len) {
    if (addr && !len) { errno = EFAULT; return -1; }
    if (flags & ~MSG_DONTWAIT) { errno = EOPNOTSUPP; return -1; }
    struct socket_meta *m = socket_meta_get(fd);
    if (m && m->type == SOCK_STREAM) {
        long r = recv(fd, buf, n, flags);
        if (r >= 0 && len) { *len = 0; }
        return r;
    }
    if (n > 65507) { errno = EINVAL; return -1; }
    if ((flags & MSG_DONTWAIT) && socket_ready_now(fd, COMPAT_POLLIN) <= 0) { return -1; }

    if (m && m->domain == AF_INET6) {
        struct swiftos_udp_msg_v6 msg;
        msg.buf = (unsigned long)buf;
        msg.len = (unsigned int)n;
        memset(msg.ip6, 0, sizeof(msg.ip6));
        msg.port = 0;
        msg.scope = 0;
        long r = sysret_long(sys3(SYS_RECVFROM, fd, (long)&msg, 0));
        if (r >= 0 && addr && len) {
            struct sockaddr_in6 sa6;
            memset(&sa6, 0, sizeof(sa6));
            sa6.sin6_family = AF_INET6;
            sa6.sin6_port = htons(msg.port);
            memcpy(sa6.sin6_addr.s6_addr, msg.ip6, 16);
            sa6.sin6_scope_id = msg.scope;
            copy_sockaddr_out(addr, len, &sa6, sizeof(sa6));
        }
        return r;
    }

    struct swiftos_udp_msg msg;
    msg.buf = (unsigned long)buf;
    msg.len = (unsigned int)n;
    msg.ip = 0;
    msg.port = 0;
    msg.pad = 0;
    long r = sysret_long(sys3(SYS_RECVFROM, fd, (long)&msg, 0));
    if (r >= 0 && addr && len) {
        struct sockaddr_in sa;
        memset(&sa, 0, sizeof(sa));
        sa.sin_family = AF_INET;
        sa.sin_port = htons(msg.port);
        sa.sin_addr.s_addr = htonl(msg.ip);
        copy_sockaddr_out(addr, len, &sa, sizeof(sa));
    }
    return r;
}

W long sendmsg(int a, const struct msghdr *b, int c) { (void)a; (void)b; (void)c; errno = ENOSYS; return -1; }
W long recvmsg(int a, struct msghdr *b, int c) { (void)a; (void)b; (void)c; errno = ENOSYS; return -1; }

W int setsockopt(int fd, int level, int opt, const void *val, socklen_t len) {
    (void)fd; (void)val; (void)len;
    if (level == IPPROTO_TCP && opt == TCP_NODELAY) { return 0; }
    if (level != SOL_SOCKET) { errno = ENOPROTOOPT; return -1; }
    switch (opt) {
    case SO_REUSEADDR:
    case SO_REUSEPORT:
    case SO_KEEPALIVE:
    case SO_RCVBUF:
    case SO_SNDBUF:
    case SO_RCVLOWAT:
    case SO_SNDLOWAT:
    case SO_LINGER:
    case SO_BROADCAST:
        return 0;
    default:
        errno = ENOPROTOOPT;
        return -1;
    }
}

W int getsockopt(int fd, int level, int opt, void *val, socklen_t *len) {
    if (level != SOL_SOCKET) { errno = ENOPROTOOPT; return -1; }
    struct socket_meta *m = socket_meta_get(fd);
    switch (opt) {
    case SO_TYPE:
        if (!m) { errno = ENOTSOCK; return -1; }
        return write_sockopt_int(val, len, m->type);
    case SO_ERROR:
        return write_sockopt_int(val, len, m ? m->error : 0);
    default:
        errno = ENOPROTOOPT;
        return -1;
    }
}

W int getsockname(int fd, struct sockaddr *addr, socklen_t *len) {
    if (!addr || !len) { errno = EFAULT; return -1; }
    struct socket_meta *m = socket_meta_get(fd);
    if (m && m->domain == AF_INET6) {
        struct sockaddr_in6 sa6;
        memset(&sa6, 0, sizeof(sa6));
        sa6.sin6_family = AF_INET6;
        copy_sockaddr_out(addr, len, &sa6, sizeof(sa6));
        return 0;
    }
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    copy_sockaddr_out(addr, len, &sa, sizeof(sa));
    return 0;
}

W int getpeername(int fd, struct sockaddr *addr, socklen_t *len) {
    return getsockname(fd, addr, len);
}
W int shutdown(int a, int b) { (void)a; (void)b; return 0; }
W int socketpair(int a, int b, int c, int d[2]) { (void)a; (void)b; (void)c; (void)d; errno = ENOSYS; return -1; }
W int h_errno;

static int c_isdigit(char c) { return c >= '0' && c <= '9'; }

static void copy_cstr(char *dst, size_t cap, const char *src) {
    if (!dst || cap == 0) { return; }
    size_t i = 0;
    if (src) {
        while (src[i] && i + 1 < cap) { dst[i] = src[i]; i++; }
    }
    dst[i] = 0;
}

static char *dup_cstr(const char *src) {
    if (!src) { return 0; }
    size_t n = strlen(src);
    char *p = (char *)malloc(n + 1);
    if (!p) { return 0; }
    memcpy(p, src, n + 1);
    return p;
}

static int parse_ipv4_literal(const char *s, unsigned int *out_host) {
    if (!s || !*s) { return 0; }
    unsigned int part[4];
    const char *p = s;
    for (int i = 0; i < 4; i++) {
        if (!c_isdigit(*p)) { return 0; }
        unsigned int v = 0;
        while (c_isdigit(*p)) {
            v = v * 10u + (unsigned int)(*p - '0');
            if (v > 255u) { return 0; }
            p++;
        }
        part[i] = v;
        if (i != 3) {
            if (*p != '.') { return 0; }
            p++;
        }
    }
    if (*p != 0) { return 0; }
    if (out_host) {
        *out_host = (part[0] << 24) | (part[1] << 16) | (part[2] << 8) | part[3];
    }
    return 1;
}

static int parse_service_port(const char *service, unsigned short *port) {
    if (!service) { *port = 0; return 0; }
    if (c_isdigit(service[0])) {
        char *endp;
        long v = strtol(service, &endp, 10);
        if (*endp || v < 0 || v > 65535) { return EAI_SERVICE; }
        *port = (unsigned short)v;
        return 0;
    }
    if (strcmp(service, "http") == 0) { *port = 80; return 0; }
    if (strcmp(service, "https") == 0) { *port = 443; return 0; }
    if (strcmp(service, "domain") == 0 || strcmp(service, "dns") == 0) { *port = 53; return 0; }
    return EAI_SERVICE;
}

static int resolve_ipv4_host(const char *node, int numeric_only, unsigned int *ip) {
    if (!node || !*node) { return EAI_NONAME; }
    if (strcmp(node, "localhost") == 0) { *ip = INADDR_LOOPBACK; return 0; }
    if (parse_ipv4_literal(node, ip)) { return 0; }
    if (numeric_only) { return EAI_NONAME; }
    unsigned int resolved = (unsigned int)sys3(SYS_RESOLVE, (long)node, 0, 0);
    if (resolved == 0) { return EAI_NONAME; }
    *ip = resolved;
    return 0;
}

static struct hostent g_hostent;
static char g_host_name[256];
static char *g_host_aliases[1] = { 0 };
static char *g_host_addr_list[2] = { 0, 0 };
static struct in_addr g_host_addr;

static struct hostent *fill_hostent(const char *name, unsigned int host_order_ip) {
    copy_cstr(g_host_name, sizeof(g_host_name), name);
    g_host_addr.s_addr = htonl(host_order_ip);
    g_host_addr_list[0] = (char *)&g_host_addr;
    g_hostent.h_name = g_host_name;
    g_hostent.h_aliases = g_host_aliases;
    g_hostent.h_addrtype = AF_INET;
    g_hostent.h_length = 4;
    g_hostent.h_addr_list = g_host_addr_list;
    h_errno = 0;
    return &g_hostent;
}

W struct hostent *gethostbyname(const char *name) {
    unsigned int ip = 0;
    int rc = resolve_ipv4_host(name, 0, &ip);
    if (rc != 0) { h_errno = HOST_NOT_FOUND; return 0; }
    return fill_hostent(name, ip);
}

W struct hostent *gethostbyaddr(const void *addr, socklen_t len, int type) {
    if (!addr || len < 4 || type != AF_INET) { h_errno = HOST_NOT_FOUND; return 0; }
    struct in_addr in;
    memcpy(&in, addr, sizeof(in));
    if (!inet_ntop(AF_INET, &in, g_host_name, sizeof(g_host_name))) {
        h_errno = HOST_NOT_FOUND;
        return 0;
    }
    g_host_addr = in;
    g_host_addr_list[0] = (char *)&g_host_addr;
    g_hostent.h_name = g_host_name;
    g_hostent.h_aliases = g_host_aliases;
    g_hostent.h_addrtype = AF_INET;
    g_hostent.h_length = 4;
    g_hostent.h_addr_list = g_host_addr_list;
    h_errno = 0;
    return &g_hostent;
}

W int getaddrinfo(const char *node, const char *service,
                  const struct addrinfo *hints, struct addrinfo **res) {
    if (!res) { return EAI_FAIL; }
    *res = 0;
    if (hints) {
        int known = AI_PASSIVE | AI_CANONNAME | AI_NUMERICHOST | AI_NUMERICSERV |
                    AI_V4MAPPED | AI_ALL | AI_ADDRCONFIG;
        if (hints->ai_flags & ~known) { return EAI_BADFLAGS; }
        if (hints->ai_family != AF_UNSPEC && hints->ai_family != AF_INET) { return EAI_FAMILY; }
    }

    int socktype = hints && hints->ai_socktype ? hints->ai_socktype : SOCK_STREAM;
    if (socktype != SOCK_STREAM && socktype != SOCK_DGRAM) { return EAI_SOCKTYPE; }
    int protocol = hints && hints->ai_protocol ? hints->ai_protocol
        : (socktype == SOCK_DGRAM ? IPPROTO_UDP : IPPROTO_TCP);
    if (!socket_protocol_ok(socktype, protocol)) { return EAI_SERVICE; }

    unsigned short port = 0;
    int rc = parse_service_port(service, &port);
    if (rc != 0) { return rc; }
    if ((hints && (hints->ai_flags & AI_NUMERICSERV)) && service && !c_isdigit(service[0])) {
        return EAI_SERVICE;
    }

    unsigned int ip = 0;
    if (!node) {
        ip = (hints && (hints->ai_flags & AI_PASSIVE)) ? INADDR_ANY : INADDR_LOOPBACK;
    } else {
        rc = resolve_ipv4_host(node, hints && (hints->ai_flags & AI_NUMERICHOST), &ip);
        if (rc != 0) { return rc; }
    }

    struct addrinfo *ai = (struct addrinfo *)calloc(1, sizeof(*ai));
    struct sockaddr_in *sa = (struct sockaddr_in *)calloc(1, sizeof(*sa));
    if (!ai || !sa) {
        free(ai);
        free(sa);
        return EAI_MEMORY;
    }
    sa->sin_family = AF_INET;
    sa->sin_port = htons(port);
    sa->sin_addr.s_addr = htonl(ip);
    ai->ai_family = AF_INET;
    ai->ai_socktype = socktype;
    ai->ai_protocol = protocol;
    ai->ai_addrlen = sizeof(*sa);
    ai->ai_addr = (struct sockaddr *)sa;
    if (hints && (hints->ai_flags & AI_CANONNAME) && node) {
        ai->ai_canonname = dup_cstr(node);
        if (!ai->ai_canonname) {
            free(sa);
            free(ai);
            return EAI_MEMORY;
        }
    }
    *res = ai;
    return 0;
}

W void freeaddrinfo(struct addrinfo *res) {
    while (res) {
        struct addrinfo *next = res->ai_next;
        free(res->ai_addr);
        free(res->ai_canonname);
        free(res);
        res = next;
    }
}

W const char *gai_strerror(int errcode) {
    switch (errcode) {
    case 0: return "success";
    case EAI_BADFLAGS: return "bad flags";
    case EAI_NONAME: return "name not found";
    case EAI_AGAIN: return "temporary failure";
    case EAI_FAIL: return "resolver failure";
    case EAI_FAMILY: return "address family unsupported";
    case EAI_MEMORY: return "out of memory";
    case EAI_SERVICE: return "service unsupported";
    case EAI_SOCKTYPE: return "socket type unsupported";
    default: return "resolver error";
    }
}

W int getnameinfo(const struct sockaddr *addr, socklen_t addrlen,
                  char *host, socklen_t hostlen, char *serv, socklen_t servlen, int flags) {
    if (!addr) { return EAI_FAIL; }
    if (host && hostlen == 0) { return EAI_MEMORY; }
    if (serv && servlen == 0) { return EAI_MEMORY; }
    if (flags & NI_NAMEREQD) { return EAI_NONAME; }

    unsigned short port = 0;
    if (addr->sa_family == AF_INET) {
        if (addrlen < sizeof(struct sockaddr_in)) { return EAI_FAIL; }
        const struct sockaddr_in *sa = (const struct sockaddr_in *)addr;
        port = ntohs(sa->sin_port);
        if (host && !inet_ntop(AF_INET, &sa->sin_addr, host, hostlen)) { return EAI_MEMORY; }
    } else if (addr->sa_family == AF_INET6) {
        if (addrlen < sizeof(struct sockaddr_in6)) { return EAI_FAIL; }
        const struct sockaddr_in6 *sa6 = (const struct sockaddr_in6 *)addr;
        port = ntohs(sa6->sin6_port);
        if (host && !inet_ntop(AF_INET6, &sa6->sin6_addr, host, hostlen)) { return EAI_FAMILY; }
    } else {
        return EAI_FAMILY;
    }

    if (serv) {
        int n = snprintf(serv, servlen, "%u", (unsigned int)port);
        if (n < 0 || (unsigned int)n >= servlen) { return EAI_MEMORY; }
    }
    return 0;
}

W const char *hstrerror(int err) {
    switch (err) {
    case 0: return "success";
    case HOST_NOT_FOUND: return "host not found";
    case TRY_AGAIN: return "try again";
    case NO_RECOVERY: return "resolver failure";
    case NO_DATA: return "no address";
    default: return "host lookup error";
    }
}

W in_addr_t inet_addr(const char *cp) {
    unsigned int ip = 0;
    if (!parse_ipv4_literal(cp, &ip)) { return INADDR_NONE; }
    return htonl(ip);
}

W int inet_aton(const char *cp, struct in_addr *inp) {
    unsigned int ip = 0;
    if (!parse_ipv4_literal(cp, &ip)) { return 0; }
    if (inp) { inp->s_addr = htonl(ip); }
    return 1;
}

W char *inet_ntoa(struct in_addr in) {
    static char buf[INET_ADDRSTRLEN];
    return (char *)inet_ntop(AF_INET, &in, buf, sizeof(buf));
}

W int inet_pton(int af, const char *src, void *dst) {
    if (af != AF_INET) { errno = EAFNOSUPPORT; return -1; }
    if (!dst) { errno = EFAULT; return -1; }
    unsigned int ip = 0;
    if (!parse_ipv4_literal(src, &ip)) { return 0; }
    ((struct in_addr *)dst)->s_addr = htonl(ip);
    return 1;
}

W const char *inet_ntop(int af, const void *src, char *dst, socklen_t size) {
    if (!src || !dst) { errno = EFAULT; return 0; }
    if (af == AF_INET) {
        if (size < INET_ADDRSTRLEN) { errno = ENOSPC; return 0; }
        const unsigned char *b = (const unsigned char *)src;
        snprintf(dst, size, "%u.%u.%u.%u",
                 (unsigned int)b[0], (unsigned int)b[1],
                 (unsigned int)b[2], (unsigned int)b[3]);
        return dst;
    }
    if (af == AF_INET6) {
        if (size < INET6_ADDRSTRLEN) { errno = ENOSPC; return 0; }
        const unsigned char *b = (const unsigned char *)src;
        snprintf(dst, size, "%x:%x:%x:%x:%x:%x:%x:%x",
                 ((unsigned int)b[0] << 8) | b[1],
                 ((unsigned int)b[2] << 8) | b[3],
                 ((unsigned int)b[4] << 8) | b[5],
                 ((unsigned int)b[6] << 8) | b[7],
                 ((unsigned int)b[8] << 8) | b[9],
                 ((unsigned int)b[10] << 8) | b[11],
                 ((unsigned int)b[12] << 8) | b[13],
                 ((unsigned int)b[14] << 8) | b[15]);
        return dst;
    }
    errno = EAFNOSUPPORT;
    return 0;
}

W unsigned int if_nametoindex(const char *name) {
    if (!name) { return 0; }
    if (strcmp(name, "eth0") == 0) { return 1; }
    return 0;
}

W char *if_indextoname(unsigned int index, char *name) {
    if (index != 1 || !name) { return 0; }
    copy_cstr(name, IFNAMSIZ, "eth0");
    return name;
}

W FILE *setmntent(const char *f, const char *m) { (void)f; (void)m; return 0; }
W void *getmntent(FILE *fp) { (void)fp; return 0; }
W int addmntent(FILE *fp, const void *m) { (void)fp; (void)m; return 1; }
W int endmntent(FILE *fp) { (void)fp; return 1; }
W char *hasmntopt(const void *m, const char *o) { (void)m; (void)o; return 0; }

W void setutxent(void) {}
W void endutxent(void) {}
W void *getutxent(void) { return 0; }
W void *pututxline(const void *u) { (void)u; return 0; }
W struct spwd *getspnam(const char *n) { (void)n; return 0; }

// ---- fs / fd / signals additionally referenced by busybox ------------------
#define SYS_CHDIR 17
#define SYS_GETCWD 18
W int chdir(const char *p) { return (int)sys3(SYS_CHDIR, (long)p, 0, 0); }
W int fchdir(int fd) { (void)fd; errno = ENOSYS; return -1; }
W char *getcwd(char *buf, size_t n) { long r = sys3(SYS_GETCWD, (long)buf, (long)n, 0); return r < 0 ? 0 : buf; }
W int chroot(const char *p) { (void)p; errno = ENOSYS; return -1; }
W int dup(int fd) {
    int nfd = sysret(sys3(SYS_DUP, fd, 0, 0));
    if (nfd >= 0) { socket_meta_copy(nfd, fd); }
    return nfd;
}
W int dup2(int o, int n) {
    int nfd = sysret(sys3(SYS_DUP2, o, n, 0));
    if (nfd >= 0) { socket_meta_copy(nfd, o); }
    return nfd;
}
W int pipe(int fds[2]) { return sysret(sys3(SYS_PIPE, (long)fds, 0, 0)); }
W int unlink(const char *p) { return sysret(sys3(SYS_UNLINK, (long)p, 0, 0)); }
W int rename(const char *o, const char *n) { return sysret(sys3(SYS_RENAME, (long)o, (long)n, 0)); }
W int mkdir(const char *p, mode_t m) { return sysret(sys3(SYS_MKDIR, (long)p, m, 0)); }
W int rmdir(const char *p) { return sysret(sys3(SYS_RMDIR, (long)p, 0, 0)); }
W int chown(const char *p, uid_t owner, gid_t group) {
    (void)group;
    return sysret(sys3(SYS_CHOWN, (long)p, (long)owner, 0));
}
W int fchown(int fd, uid_t owner, gid_t group) { (void)fd; (void)owner; (void)group; return 0; }
W int fsync(int fd) { (void)fd; return 0; }
W int symlink(const char *target, const char *linkpath) {
    (void)target; (void)linkpath; errno = ENOSYS; return -1;
}
W int utimes(const char *p, const struct timeval tv[2]) { (void)p; (void)tv; return 0; }
W mode_t umask(mode_t m) { (void)m; return 0; }
W FILE *popen(const char *cmd, const char *mode) {
    (void)cmd; (void)mode; errno = ENOSYS; return 0;
}
W int pclose(FILE *fp) { (void)fp; errno = ENOSYS; return -1; }
W int settimeofday(const struct timeval *tv, const struct timezone *tz) {
    (void)tv; (void)tz; errno = ENOSYS; return -1;
}
W int setitimer(int which, const struct itimerval *value, struct itimerval *old) {
    (void)which; (void)value;
    if (old) { memset(old, 0, sizeof(*old)); }
    return 0;
}
W int gethostname(char *buf, size_t n) {
    const char *name = "swift-os";
    if (!buf || n == 0) { errno = EINVAL; return -1; }
    size_t i = 0;
    while (name[i] && i + 1 < n) { buf[i] = name[i]; i++; }
    buf[i] = 0;
    return 0;
}
W int ttyname_r(int fd, char *buf, size_t n) {
    (void)fd; const char *s = "/dev/console";
    size_t i = 0; while (s[i] && i + 1 < n) { buf[i] = s[i]; i++; } if (n) buf[i] = 0;
    return 0;
}

// signals: route to our minimal kernel disposition (syscall 9); masks are no-ops.
#define SWIFTOS_NSIG 64
static void (*swiftos_siginfo_handlers[SWIFTOS_NSIG])(int, siginfo_t *, void *);

static void swiftos_siginfo_trampoline(int sig) {
    if (sig > 0 && sig < SWIFTOS_NSIG && swiftos_siginfo_handlers[sig]) {
        swiftos_siginfo_handlers[sig](sig, NULL, NULL);
    }
}

W int sigaction(int sig, const struct sigaction *act, struct sigaction *old) {
    (void)old;
    if (act) {
        void (*handler)(int) = act->sa_handler;
        if ((act->sa_flags & SA_SIGINFO) && sig > 0 && sig < SWIFTOS_NSIG) {
            swiftos_siginfo_handlers[sig] = act->sa_sigaction;
            handler = swiftos_siginfo_trampoline;
        }
        sys3(9, sig, (long)handler, 0);
    }
    return 0;
}
W int sigprocmask(int how, const sigset_t *set, sigset_t *old) { (void)how; (void)set; (void)old; return 0; }
W int sigsuspend(const sigset_t *mask) { (void)mask; errno = EINTR; return -1; }

// fnmatch / glob: minimal pattern matcher; glob is unsupported.
#define FNM_NOMATCH 1
W int fnmatch(const char *p, const char *s, int flags) {
    (void)flags;
    while (*p) {
        if (*p == '*') {
            p++;
            if (!*p) { return 0; }
            while (*s) { if (fnmatch(p, s, 0) == 0) { return 0; } s++; }
            return FNM_NOMATCH;
        } else if (*p == '?') {
            if (!*s) { return FNM_NOMATCH; }
            p++; s++;
        } else {
            if (*p != *s) { return FNM_NOMATCH; }
            p++; s++;
        }
    }
    return *s ? FNM_NOMATCH : 0;
}
#define GLOB_NOMATCH 3
W int glob(const char *pat, int flags, void *errfn, void *pglob) { (void)pat; (void)flags; (void)errfn; (void)pglob; return GLOB_NOMATCH; }
W void globfree(void *pglob) { (void)pglob; }

// ---- path helpers additionally referenced ---------------------------------
W int access(const char *p, int mode) { (void)mode; struct stat st; return stat(p, &st) == 0 ? 0 : -1; }
W ssize_t readlink(const char *p, char *buf, size_t n) { (void)p; (void)buf; (void)n; errno = EINVAL; return -1; }
W char *realpath(const char *p, char *resolved) {
    if (!p) { errno = EINVAL; return 0; }
    char *out = resolved ? resolved : (char *)malloc(1024);
    if (!out) { return 0; }
    size_t i = 0; while (p[i] && i < 1023) { out[i] = p[i]; i++; } out[i] = 0;
    return out;
}
