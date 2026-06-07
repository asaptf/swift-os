// syscall.h — swift-os userland syscall ABI.
//
// Our own POSIX-like ABI (NOT Linux): the syscall number goes in x8, arguments
// in x0..x5, the return value comes back in x0, via `svc #0`. Numbers must match
// kernel/syscall/syscall.swift.

#ifndef SWIFTOS_USER_SYSCALL_H
#define SWIFTOS_USER_SYSCALL_H

#define SYS_OPEN      1
#define SYS_READ      2
#define SYS_WRITE     3
#define SYS_CLOSE     4
#define SYS_EXIT      5
#define SYS_LSEEK     6
#define SYS_TCGETATTR 7
#define SYS_TCSETATTR 8
#define SYS_SIGACTION 9
#define SYS_KILL      10
#define SYS_GETPID    11
#define SYS_SPAWN     12
#define SYS_WAITPID   13
#define SYS_STAT      14
#define SYS_FSTAT     15
#define SYS_GETDENTS  16
#define SYS_CHDIR     17
#define SYS_GETCWD    18
#define SYS_SBRK      19
#define SYS_FORK      20
#define SYS_EXECVE    21
#define SYS_PSINFO    22
#define SYS_DUP       23
#define SYS_DUP2      24
#define SYS_PIPE      25
#define SYS_POLL      26
#define SYS_UNLINK    27
#define SYS_RENAME    28
#define SYS_MKDIR     29
#define SYS_RMDIR     30
#define SYS_SECURITY_INFO 31
#define SYS_LOGIN         32
#define SYS_FTRUNCATE     33
#define SYS_FCNTL         34
#define SYS_CHMOD         35
#define SYS_CHOWN         36
#define SYS_TIME          37
#define SYS_SOCKET        38
#define SYS_BIND          39
#define SYS_SENDTO        40
#define SYS_RECVFROM      41
#define SYS_LISTEN        42
#define SYS_ACCEPT        43
#define SYS_CONNECT       44
#define SYS_RESOLVE       45

#ifndef __ASSEMBLER__

typedef unsigned long size_t;
typedef long ssize_t;

static inline long __syscall3(long n, long a0, long a1, long a2) {
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a0;
    register long x1 __asm__("x1") = a1;
    register long x2 __asm__("x2") = a2;
    __asm__ volatile("svc #0"
                     : "+r"(x0)
                     : "r"(x8), "r"(x1), "r"(x2)
                     : "memory");
    return x0;
}

static inline ssize_t write(int fd, const void *buf, size_t count) {
    return __syscall3(SYS_WRITE, fd, (long)buf, (long)count);
}

static inline ssize_t read(int fd, void *buf, size_t count) {
    return __syscall3(SYS_READ, fd, (long)buf, (long)count);
}

static inline int open(const char *path, int flags) {
    return (int)__syscall3(SYS_OPEN, (long)path, flags, 0);
}

static inline int close(int fd) {
    return (int)__syscall3(SYS_CLOSE, fd, 0, 0);
}

static inline long lseek(int fd, long offset, int whence) {
    return __syscall3(SYS_LSEEK, fd, offset, whence);
}

static inline void _exit(int code) {
    __syscall3(SYS_EXIT, code, 0, 0);
    __builtin_unreachable();
}

// Launch a program by path with argv (NULL-terminated). Runs synchronously and
// returns the child's exit status (spawn = fork+exec+wait, since we have no
// COW fork). Negative on error.
static inline long spawn(const char *path, char *const argv[]) {
    return __syscall3(SYS_SPAWN, (long)path, (long)argv, 0);
}

static inline int getpid(void) {
    return (int)__syscall3(SYS_GETPID, 0, 0, 0);
}

static inline int fork(void) {
    return (int)__syscall3(SYS_FORK, 0, 0, 0);
}

static inline int waitpid(int pid, int *status, int options) {
    return (int)__syscall3(SYS_WAITPID, pid, (long)status, options);
}

static inline int execve(const char *path, char *const argv[], char *const envp[]) {
    (void)envp;
    return (int)__syscall3(SYS_EXECVE, (long)path, (long)argv, (long)envp);
}

static inline int dup(int fd) {
    return (int)__syscall3(SYS_DUP, fd, 0, 0);
}

static inline int dup2(int oldfd, int newfd) {
    return (int)__syscall3(SYS_DUP2, oldfd, newfd, 0);
}

static inline int pipe(int fds[2]) {
    return (int)__syscall3(SYS_PIPE, (long)fds, 0, 0);
}

static inline int unlink(const char *path) {
    return (int)__syscall3(SYS_UNLINK, (long)path, 0, 0);
}

static inline int rename(const char *oldpath, const char *newpath) {
    return (int)__syscall3(SYS_RENAME, (long)oldpath, (long)newpath, 0);
}

static inline int mkdir(const char *path, int mode) {
    (void)mode;
    return (int)__syscall3(SYS_MKDIR, (long)path, mode, 0);
}

static inline int rmdir(const char *path) {
    return (int)__syscall3(SYS_RMDIR, (long)path, 0, 0);
}

struct security_info {
    unsigned int principal;
    unsigned int session;
    unsigned long caps;
};

static inline int security_info(struct security_info *info) {
    return (int)__syscall3(SYS_SECURITY_INFO, (long)info, 0, 0);
}

// Replace the caller's security context after authenticating a principal.
// Privileged: only a process holding CAP_CONSOLE may call it. 0 on success,
// negative on error (e.g. -1 EPERM). The new context survives execve.
static inline int login(unsigned int principal, unsigned int session, unsigned long caps) {
    return (int)__syscall3(SYS_LOGIN, (long)principal, (long)session, (long)caps);
}

// Grow the process heap by `incr` bytes; returns the previous break, or (void*)-1.
static inline void *sbrk(long incr) {
    return (void *)__syscall3(SYS_SBRK, incr, 0, 0);
}

#endif // __ASSEMBLER__
#endif // SWIFTOS_USER_SYSCALL_H
