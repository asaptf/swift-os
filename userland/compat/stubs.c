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
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <termios.h>
#include <pwd.h>
#include <grp.h>
#include <sys/utsname.h>

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

static int sysret(long r) {
    if (r < 0) { errno = (int)-r; return -1; }
    return (int)r;
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
W pid_t getppid(void) { return 1; }
W pid_t setsid(void) { return 0; }
W int setpgid(pid_t a, pid_t b) { (void)a; (void)b; return 0; }
W pid_t getpgrp(void) { return 1; }
W pid_t getpgid(pid_t p) { (void)p; return 1; }
W pid_t tcgetpgrp(int fd) { (void)fd; return 1; }
W int tcsetpgrp(int fd, pid_t pgrp) { (void)fd; (void)pgrp; return 0; }

// ---- passwd / group (minimal "root") --------------------------------------
static struct passwd g_root_pw = { (char *)"root", (char *)"x", 0, 0, (char *)"root", (char *)"/", (char *)"/bin/sh" };
W struct passwd *getpwuid(uid_t uid) { (void)uid; return &g_root_pw; }
W struct passwd *getpwnam(const char *name) { (void)name; return &g_root_pw; }
W struct passwd *getpwent(void) { return 0; }
W void setpwent(void) {}
W void endpwent(void) {}
static struct group g_root_gr = { (char *)"root", (char *)"x", 0, 0 };
W struct group *getgrgid(gid_t gid) { (void)gid; return &g_root_gr; }
W struct group *getgrnam(const char *name) { (void)name; return &g_root_gr; }
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
W int lstat(const char *path, struct stat *st) { return stat(path, st); }
W int mknod(const char *p, mode_t m, dev_t d) { (void)p; (void)m; (void)d; errno = ENOSYS; return -1; }
W int uname(struct utsname *u) {
    if (!u) { errno = EFAULT; return -1; }
    strcpy(u->sysname, "swift-os"); strcpy(u->nodename, "swiftos");
    strcpy(u->release, "0.1"); strcpy(u->version, "M8"); strcpy(u->machine, "aarch64");
    return 0;
}
W int clearenv(void) { if (environ) environ[0] = 0; return 0; }
W unsigned int sleep(unsigned int s) { (void)s; return 0; }
W int nanosleep(const struct timespec *req, struct timespec *rem) { (void)req; (void)rem; return 0; }
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
W int getrlimit(int r, void *l) { (void)r; (void)l; return 0; }
W int setrlimit(int r, const void *l) { (void)r; (void)l; return 0; }
W int getrusage(int who, void *u) { (void)who; (void)u; errno = ENOSYS; return -1; }
W int getpriority(int w, id_t who) { (void)w; (void)who; return 0; }
W int setpriority(int w, id_t who, int p) { (void)w; (void)who; (void)p; return 0; }
W int statfs(const char *p, void *b) { (void)p; (void)b; errno = ENOSYS; return -1; }
W int fstatfs(int fd, void *b) { (void)fd; (void)b; errno = ENOSYS; return -1; }
W int sysinfo(void *info) { (void)info; errno = ENOSYS; return -1; }
W void *mmap(void *a, size_t l, int p, int f, int fd, long o) { (void)a; (void)l; (void)p; (void)f; (void)fd; (void)o; return (void *)-1; }
W int munmap(void *a, size_t l) { (void)a; (void)l; return 0; }
W int poll(void *fds, unsigned long n, int timeout) { return sysret(sys3(SYS_POLL, (long)fds, (long)n, timeout)); }
W int ppoll(void *fds, unsigned long n, const void *ts, const void *sig) {
    (void)sig;
    int timeout = -1;
    if (ts) {
        const long *p = (const long *)ts;
        timeout = (int)(p[0] * 1000 + p[1] / 1000000);
    }
    return poll(fds, n, timeout);
}

// ---- networking / mount / utmp / shadow: not supported (ENOSYS / NULL) -----
W int socket(int a, int b, int c) { (void)a; (void)b; (void)c; errno = ENOSYS; return -1; }
W int bind(int a, const void *b, unsigned c) { (void)a; (void)b; (void)c; errno = ENOSYS; return -1; }
W int connect(int a, const void *b, unsigned c) { (void)a; (void)b; (void)c; errno = ENOSYS; return -1; }
W int listen(int a, int b) { (void)a; (void)b; errno = ENOSYS; return -1; }
W int accept(int a, void *b, unsigned *c) { (void)a; (void)b; (void)c; errno = ENOSYS; return -1; }
W long send(int a, const void *b, size_t c, int d) { (void)a; (void)b; (void)c; (void)d; errno = ENOSYS; return -1; }
W long recv(int a, void *b, size_t c, int d) { (void)a; (void)b; (void)c; (void)d; errno = ENOSYS; return -1; }
W long sendto(int a, const void *b, size_t c, int d, const void *e, unsigned f) { (void)a; (void)b; (void)c; (void)d; (void)e; (void)f; errno = ENOSYS; return -1; }
W long recvfrom(int a, void *b, size_t c, int d, void *e, unsigned *f) { (void)a; (void)b; (void)c; (void)d; (void)e; (void)f; errno = ENOSYS; return -1; }
W long sendmsg(int a, const void *b, int c) { (void)a; (void)b; (void)c; errno = ENOSYS; return -1; }
W long recvmsg(int a, void *b, int c) { (void)a; (void)b; (void)c; errno = ENOSYS; return -1; }
W int setsockopt(int a, int b, int c, const void *d, unsigned e) { (void)a; (void)b; (void)c; (void)d; (void)e; return 0; }
W int getsockopt(int a, int b, int c, void *d, unsigned *e) { (void)a; (void)b; (void)c; (void)d; (void)e; errno = ENOSYS; return -1; }
W int getsockname(int a, void *b, unsigned *c) { (void)a; (void)b; (void)c; errno = ENOSYS; return -1; }
W int getpeername(int a, void *b, unsigned *c) { (void)a; (void)b; (void)c; errno = ENOSYS; return -1; }
W int shutdown(int a, int b) { (void)a; (void)b; return 0; }
W int socketpair(int a, int b, int c, int d[2]) { (void)a; (void)b; (void)c; (void)d; errno = ENOSYS; return -1; }
W void *gethostbyname(const char *n) { (void)n; return 0; }
W void *gethostbyaddr(const void *a, unsigned l, int t) { (void)a; (void)l; (void)t; return 0; }
W int getaddrinfo(const char *n, const char *s, const void *h, void **r) { (void)n; (void)s; (void)h; (void)r; return -2; }
W void freeaddrinfo(void *r) { (void)r; }
W const char *gai_strerror(int e) { (void)e; return "unsupported"; }
W int getnameinfo(const void *a, unsigned al, char *h, unsigned hl, char *s, unsigned sl, int f) { (void)a; (void)al; (void)h; (void)hl; (void)s; (void)sl; (void)f; return -2; }
W unsigned int inet_addr(const char *c) { (void)c; return 0xffffffffu; }
W char *inet_ntoa(/* struct in_addr */ ...) { return (char *)"0.0.0.0"; }
W int inet_pton(int af, const char *src, void *dst) { (void)af; (void)src; (void)dst; return 0; }
W const char *inet_ntop(int af, const void *src, char *dst, unsigned size) { (void)af; (void)src; (void)dst; (void)size; return 0; }
W unsigned int if_nametoindex(const char *n) { (void)n; return 0; }
W char *if_indextoname(unsigned int i, char *n) { (void)i; (void)n; return 0; }

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
W int dup(int fd) { return sysret(sys3(SYS_DUP, fd, 0, 0)); }
W int dup2(int o, int n) { return sysret(sys3(SYS_DUP2, o, n, 0)); }
W int pipe(int fds[2]) { return sysret(sys3(SYS_PIPE, (long)fds, 0, 0)); }
W int unlink(const char *p) { return sysret(sys3(SYS_UNLINK, (long)p, 0, 0)); }
W int rename(const char *o, const char *n) { return sysret(sys3(SYS_RENAME, (long)o, (long)n, 0)); }
W int mkdir(const char *p, mode_t m) { return sysret(sys3(SYS_MKDIR, (long)p, m, 0)); }
W int rmdir(const char *p) { return sysret(sys3(SYS_RMDIR, (long)p, 0, 0)); }
W mode_t umask(mode_t m) { (void)m; return 0; }
W int settimeofday(const void *tv, const void *tz) { (void)tv; (void)tz; errno = ENOSYS; return -1; }
W int ttyname_r(int fd, char *buf, size_t n) {
    (void)fd; const char *s = "/dev/console";
    size_t i = 0; while (s[i] && i + 1 < n) { buf[i] = s[i]; i++; } if (n) buf[i] = 0;
    return 0;
}

// signals: route to our minimal kernel disposition (syscall 9); masks are no-ops.
struct __sigaction_compat { void (*sa_handler)(int); unsigned long sa_mask; int sa_flags; void *sa_restorer; };
W int sigaction(int sig, const void *act, void *old) {
    (void)old;
    if (act) {
        const struct __sigaction_compat *a = (const struct __sigaction_compat *)act;
        sys3(9, sig, (long)a->sa_handler, 0);
    }
    return 0;
}
W int sigprocmask(int how, const void *set, void *old) { (void)how; (void)set; (void)old; return 0; }
W int sigsuspend(const void *mask) { (void)mask; errno = EINTR; return -1; }

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
