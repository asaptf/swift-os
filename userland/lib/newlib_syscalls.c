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
#include <sys/time.h>
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
#define SYS_TIME 37

static long sys3(long n, long a0, long a1, long a2) {
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a0;
    register long x1 __asm__("x1") = a1;
    register long x2 __asm__("x2") = a2;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
    return x0;
}

static int ret_int(long r) {
    if (r < 0) { errno = (int)-r; return -1; }
    return (int)r;
}

static _off_t ret_off(long r) {
    if (r < 0) { errno = (int)-r; return (_off_t)-1; }
    return (_off_t)r;
}

// Kernel stat layout (kernel/vfs/vfs.swift writeStatMode), 24 bytes:
//   u32 mode, u32 uid, u64 size, u32 gid, u32 nlink.
struct kstat {
    unsigned int mode;
    unsigned int uid;
    unsigned long size;
    unsigned int gid;
    unsigned int nlink;
    unsigned long mtime;
};

char *__env[1] = { 0 };
char **environ = __env;

void _exit(int code) {
    sys3(SYS_EXIT, code, 0, 0);
    for (;;) {}
}

int _close(int fd) { return ret_int(sys3(SYS_CLOSE, fd, 0, 0)); }

int _read(int fd, char *buf, int len) { return ret_int(sys3(SYS_READ, fd, (long)buf, len)); }

int _write(int fd, const char *buf, int len) { return ret_int(sys3(SYS_WRITE, fd, (long)buf, len)); }

_off_t _lseek(int fd, _off_t off, int whence) { return ret_off(sys3(SYS_LSEEK, fd, off, whence)); }

// Translate newlib's BSD-style open flags into the kernel ABI (kernel/vfs/
// vfs.swift). The access mode bits (O_RDONLY 0, O_WRONLY 1, O_RDWR 2) already
// match; only the create/truncate/append bits differ.
#define NL_O_CREAT 0x0200
#define NL_O_TRUNC 0x0400
#define NL_O_APPEND 0x0008
#define NL_O_CLOEXEC 0x40000
#define K_O_CREAT 0x40
#define K_O_TRUNC 0x80
#define K_O_APPEND 0x100
#define K_O_CLOEXEC 0x200

int _open(const char *path, int flags, int mode) {
    (void)mode;
    int k = flags & 0x3;                       // RDONLY/WRONLY/RDWR
    if (flags & NL_O_CREAT)   k |= K_O_CREAT;
    if (flags & NL_O_TRUNC)   k |= K_O_TRUNC;
    if (flags & NL_O_APPEND)  k |= K_O_APPEND;
    if (flags & NL_O_CLOEXEC) k |= K_O_CLOEXEC;
    long r = sys3(SYS_OPEN, (long)path, k, 0);
    if (r < 0) { errno = (int)-r; return -1; }
    return (int)r;
}

int _isatty(int fd) { return fd < 3 ? 1 : 0; }

int _kill(int pid, int sig) { return (int)sys3(SYS_KILL, pid, sig, 0); }

int _getpid(void) { return (int)sys3(SYS_GETPID, 0, 0, 0); }

void *_sbrk(int incr) { return (void *)sys3(SYS_SBRK, incr, 0, 0); }

int _fstat(int fd, struct stat *st) {
    if (fd < 3) {            // stdin/out/err are the console (a char device)
        st->st_mode = S_IFCHR;
        st->st_uid = 0;
        st->st_gid = 0;
        st->st_nlink = 1;
        return 0;
    }
    struct kstat k;
    if (sys3(SYS_FSTAT, fd, (long)&k, 0) != 0) { errno = EBADF; return -1; }
    st->st_mode = k.mode ? k.mode : S_IFREG;
    st->st_size = (off_t)k.size;
    st->st_uid = k.uid;
    st->st_gid = k.gid;
    st->st_nlink = k.nlink ? k.nlink : 1;
    st->st_mtim.tv_sec = (time_t)k.mtime;
    st->st_ctim.tv_sec = (time_t)k.mtime;
    st->st_atim.tv_sec = (time_t)k.mtime;
    return 0;
}

int _stat(const char *path, struct stat *st) {
    struct kstat k;
    if (sys3(SYS_STAT, (long)path, (long)&k, 0) != 0) { errno = ENOENT; return -1; }
    st->st_mode = k.mode;
    st->st_size = (off_t)k.size;
    st->st_uid = k.uid;
    st->st_gid = k.gid;
    st->st_nlink = k.nlink ? k.nlink : 1;
    st->st_mtim.tv_sec = (time_t)k.mtime;
    st->st_ctim.tv_sec = (time_t)k.mtime;
    st->st_atim.tv_sec = (time_t)k.mtime;
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
int _gettimeofday(struct timeval *tv, void *tz) {
    if (!tv) { errno = EFAULT; return -1; }
    tv->tv_sec = (time_t)sys3(SYS_TIME, 0, 0, 0);
    tv->tv_usec = 0;
    if (tz) {
        struct timezone *zone = (struct timezone *)tz;
        zone->tz_minuteswest = 0;
        zone->tz_dsttime = DST_NONE;
    }
    return 0;
}
int _wait(int *status) { (void)status; errno = ECHILD; return -1; }
