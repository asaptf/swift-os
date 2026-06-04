// newlib_syscalls.c — newlib's libc bottom end on the swift-os syscall ABI.
//
// Built newlib with --disable-newlib-supplied-syscalls, so libc references the
// `_*` stubs below; we implement them via our own `svc #0` ABI (number in x8,
// args x0..x2, return in x0). This is the "newlib port" layer.
//
// Do NOT include our lib/syscall.h here: it defines read/write/open as inline
// functions that would collide with newlib's <unistd.h> declarations.

#include <sys/stat.h>
#include <sys/types.h>
#include <sys/times.h>
#include <errno.h>

#define SYS_OPEN  1
#define SYS_READ  2
#define SYS_WRITE 3
#define SYS_CLOSE 4
#define SYS_EXIT  5
#define SYS_LSEEK 6
#define SYS_STAT  14
#define SYS_FSTAT 15
#define SYS_KILL  10
#define SYS_GETPID 11
#define SYS_SBRK  19
#define SYS_UNLINK 27

static long sys3(long n, long a0, long a1, long a2) {
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a0;
    register long x1 __asm__("x1") = a1;
    register long x2 __asm__("x2") = a2;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
    return x0;
}

// Kernel stat layout (kernel/vfs/vfs.swift): u32 mode, u32 pad, u64 size.
struct kstat { unsigned int mode; unsigned int pad; unsigned long size; };

char *__env[1] = { 0 };
char **environ = __env;

void _exit(int code) {
    sys3(SYS_EXIT, code, 0, 0);
    for (;;) {}
}

int _close(int fd) { return (int)sys3(SYS_CLOSE, fd, 0, 0); }

int _read(int fd, char *buf, int len) { return (int)sys3(SYS_READ, fd, (long)buf, len); }

int _write(int fd, const char *buf, int len) { return (int)sys3(SYS_WRITE, fd, (long)buf, len); }

_off_t _lseek(int fd, _off_t off, int whence) { return (_off_t)sys3(SYS_LSEEK, fd, off, whence); }

int _open(const char *path, int flags, int mode) {
    (void)mode;
    return (int)sys3(SYS_OPEN, (long)path, flags, 0);
}

int _isatty(int fd) { return fd < 3 ? 1 : 0; }

int _kill(int pid, int sig) { return (int)sys3(SYS_KILL, pid, sig, 0); }

int _getpid(void) { return (int)sys3(SYS_GETPID, 0, 0, 0); }

void *_sbrk(int incr) { return (void *)sys3(SYS_SBRK, incr, 0, 0); }

int _fstat(int fd, struct stat *st) {
    if (fd < 3) {            // stdin/out/err are the console (a char device)
        st->st_mode = S_IFCHR;
        return 0;
    }
    struct kstat k;
    if (sys3(SYS_FSTAT, fd, (long)&k, 0) != 0) { errno = EBADF; return -1; }
    st->st_mode = k.mode ? k.mode : S_IFREG;
    st->st_size = (off_t)k.size;
    return 0;
}

int _stat(const char *path, struct stat *st) {
    struct kstat k;
    if (sys3(SYS_STAT, (long)path, (long)&k, 0) != 0) { errno = ENOENT; return -1; }
    st->st_mode = k.mode;
    st->st_size = (off_t)k.size;
    return 0;
}

// Stubs newlib may pull in but that we don't support yet.
int _link(const char *a, const char *b) { (void)a; (void)b; errno = EMLINK; return -1; }
int _unlink(const char *a) {
    long r = sys3(SYS_UNLINK, (long)a, 0, 0);
    if (r < 0) { errno = (int)-r; return -1; }
    return (int)r;
}
int _times(struct tms *t) { (void)t; return -1; }
int _gettimeofday(void *tv, void *tz) { (void)tv; (void)tz; return -1; }
int _wait(int *status) { (void)status; errno = ECHILD; return -1; }
