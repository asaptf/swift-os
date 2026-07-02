// SPDX-License-Identifier: Apache-2.0
// node_compat.c - implementation of the Linux-API shims libuv's linux backend
// references on SwiftOS (the Node.js --dest-os=linux masquerade).
//
// The centrepiece is an epoll emulation over poll(): SwiftOS provides poll,
// eventfd, and futex but no epoll. Each epoll instance is backed by a real
// eventfd (so libuv's close() on the backend fd works and the descriptor is
// unique) and keeps a dynamic interest list that epoll_pwait() turns into a
// pollfd[] for poll(), translating revents back into epoll events.
//
// The remaining shims are deliberate no-ops/ENOSYS so libuv falls back to its
// portable paths: no inotify (fs watching degrades), no sendfile/recvmmsg/
// sendmmsg (libuv uses read/write and recvmsg loops), no raw syscall, and no
// dynamic loading (static-only OS).

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <dirent.h>
#include <pwd.h>
#include <grp.h>
#include <pthread.h>
#include <sched.h>
#include <sys/eventfd.h>
#include <sys/random.h>
#include <sys/mman.h>      /* mmap/munmap, routed by the syscall() shim below */
#include <sys/stat.h>      /* fchmodat / mode_t */

#include <sys/socket.h>
#include <sys/epoll.h>
#include <sys/inotify.h>
#include <sys/sendfile.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <dlfcn.h>
#include <link.h>
#include <ucontext.h>

/* ----- epoll over poll ---------------------------------------------------- */

struct epoll_reg {
    int          fd;
    uint32_t     events;
    epoll_data_t data;
};

struct epoll_inst {
    int               used;         /* 0 (BSS default) means slot free */
    int               backing_fd;   /* real eventfd backing this epoll */
    struct epoll_reg *regs;
    int               count;
    int               cap;
};

#define EPOLL_MAX_INST 16
static struct epoll_inst epoll_table[EPOLL_MAX_INST];

static struct epoll_inst *epoll_find(int epfd) {
    if (epfd < 0) return NULL;
    for (int i = 0; i < EPOLL_MAX_INST; i++)
        if (epoll_table[i].used && epoll_table[i].backing_fd == epfd)
            return &epoll_table[i];
    return NULL;
}

int epoll_create1(int flags) {
    (void)flags;
    int slot = -1;
    for (int i = 0; i < EPOLL_MAX_INST; i++) {
        if (!epoll_table[i].used) { slot = i; break; }
    }
    if (slot < 0) { errno = EMFILE; return -1; }

    int fd = eventfd(0, 0);
    if (fd < 0) return -1;            /* errno set by eventfd */

    epoll_table[slot].used = 1;
    epoll_table[slot].backing_fd = fd;
    epoll_table[slot].regs = NULL;
    epoll_table[slot].count = 0;
    epoll_table[slot].cap = 0;
    return fd;
}

static struct epoll_reg *epoll_reg_find(struct epoll_inst *e, int fd) {
    for (int i = 0; i < e->count; i++)
        if (e->regs[i].fd == fd) return &e->regs[i];
    return NULL;
}

int epoll_ctl(int epfd, int op, int fd, struct epoll_event *event) {
    struct epoll_inst *e = epoll_find(epfd);
    if (!e) { errno = EBADF; return -1; }

    struct epoll_reg *r = epoll_reg_find(e, fd);

    if (op == EPOLL_CTL_DEL) {
        if (!r) { errno = ENOENT; return -1; }
        int idx = (int)(r - e->regs);
        e->regs[idx] = e->regs[e->count - 1];
        e->count--;
        return 0;
    }

    if (!event) { errno = EFAULT; return -1; }

    if (op == EPOLL_CTL_ADD) {
        if (r) { errno = EEXIST; return -1; }
        if (e->count == e->cap) {
            int ncap = e->cap ? e->cap * 2 : 8;
            struct epoll_reg *nr = realloc(e->regs, (size_t)ncap * sizeof(*nr));
            if (!nr) { errno = ENOMEM; return -1; }
            e->regs = nr;
            e->cap = ncap;
        }
        e->regs[e->count].fd = fd;
        e->regs[e->count].events = event->events;
        e->regs[e->count].data = event->data;
        e->count++;
        return 0;
    }

    if (op == EPOLL_CTL_MOD) {
        if (!r) { errno = ENOENT; return -1; }
        r->events = event->events;
        r->data = event->data;
        return 0;
    }

    errno = EINVAL;
    return -1;
}

static short epoll_to_poll(uint32_t e) {
    short ev = 0;
    if (e & EPOLLIN)  ev |= POLLIN;
    if (e & EPOLLOUT) ev |= POLLOUT;
    if (e & EPOLLPRI) ev |= POLLPRI;
#ifdef POLLRDHUP
    if (e & EPOLLRDHUP) ev |= POLLRDHUP;
#endif
    return ev;
}

static uint32_t poll_to_epoll(short re) {
    uint32_t e = 0;
    if (re & POLLIN)   e |= EPOLLIN;
    if (re & POLLOUT)  e |= EPOLLOUT;
    if (re & POLLPRI)  e |= EPOLLPRI;
    if (re & POLLERR)  e |= EPOLLERR;
    if (re & POLLHUP)  e |= EPOLLHUP;
    if (re & POLLNVAL) e |= EPOLLERR;
    return e;
}

int epoll_pwait(int epfd, struct epoll_event *events, int maxevents,
                int timeout, const sigset_t *sigmask) {
    (void)sigmask;   /* SwiftOS has no atomic signal-mask poll; libuv passes 0 */
    struct epoll_inst *e = epoll_find(epfd);
    if (!e) { errno = EBADF; return -1; }
    if (maxevents <= 0) { errno = EINVAL; return -1; }
    if (e->count == 0) {
        /* Nothing registered: emulate epoll's idle wait via poll(NULL). */
        return poll(NULL, 0, timeout);
    }

    struct pollfd *pfds = calloc((size_t)e->count, sizeof(*pfds));
    if (!pfds) { errno = ENOMEM; return -1; }
    for (int i = 0; i < e->count; i++) {
        pfds[i].fd = e->regs[i].fd;
        pfds[i].events = epoll_to_poll(e->regs[i].events);
    }

    int n = poll(pfds, (nfds_t)e->count, timeout);
    if (n <= 0) { free(pfds); return n; }

    int out = 0;
    for (int i = 0; i < e->count && out < maxevents; i++) {
        if (pfds[i].revents == 0) continue;
        events[out].events = poll_to_epoll(pfds[i].revents);
        events[out].data = e->regs[i].data;
        out++;
    }
    free(pfds);
    return out;
}

int epoll_wait(int epfd, struct epoll_event *events, int maxevents, int timeout) {
    return epoll_pwait(epfd, events, maxevents, timeout, NULL);
}

/* ----- inotify (no fs watching) ------------------------------------------- */

int inotify_init1(int flags) { (void)flags; errno = ENOSYS; return -1; }
int inotify_add_watch(int fd, const char *path, uint32_t mask) {
    (void)fd; (void)path; (void)mask; errno = ENOSYS; return -1;
}
int inotify_rm_watch(int fd, int wd) { (void)fd; (void)wd; errno = ENOSYS; return -1; }

/* ----- interface enumeration (empty list first pass) ---------------------- */

int getifaddrs(struct ifaddrs **ifap) { if (ifap) *ifap = NULL; return 0; }
void freeifaddrs(struct ifaddrs *ifa) { (void)ifa; }

/* ----- unsupported fast paths (libuv has portable fallbacks) -------------- */

ssize_t sendfile(int out_fd, int in_fd, off_t *offset, size_t count) {
    (void)out_fd; (void)in_fd; (void)offset; (void)count;
    errno = ENOSYS; return -1;
}

// Minimal syscall() router. Abseil/V8/libuv call syscall(__NR_*, ...) directly
// for a few fast paths; route the ones with real SwiftOS backings (mmap/munmap/
// write) and return -ENOSYS for the rest so callers fall back.
long syscall(long number, ...) {
    va_list ap;
    va_start(ap, number);
    long a0 = va_arg(ap, long), a1 = va_arg(ap, long), a2 = va_arg(ap, long);
    long a3 = va_arg(ap, long), a4 = va_arg(ap, long), a5 = va_arg(ap, long);
    va_end(ap);
    switch (number) {
    case __NR_write:
        return (long)write((int)a0, (const void *)a1, (size_t)a2);
    case SYS_close:
        /* libuv's uv__close_nocancel() closes fds via syscall(SYS_close) rather
         * than close() under __linux__ (deps/uv/src/unix/core.c). Without this
         * every uv_fs_close fails -> node aborts on the first file read
         * (ReadFileSync CHECK_EQ), e.g. running any .js file such as npm. */
        return (long)close((int)a0);
    case SYS_gettid:
        /* Each SwiftOS thread is its own scheduler entity with a distinct pid,
         * so getpid() is a valid, stable per-thread id for libuv's gettid(). */
        return (long)getpid();
    case __NR_mmap:
#if __NR_mmap2 != __NR_mmap   /* aarch64 aliases mmap2->mmap; avoid duplicate case */
    case __NR_mmap2:
#endif
        return (long)mmap((void *)a0, (size_t)a1, (int)a2, (int)a3, (int)a4, (off_t)a5);
    case __NR_munmap:
        return (long)munmap((void *)a0, (size_t)a1);
    case __NR_getrandom:
        /* OpenSSL's DRBG seeds via syscall(__NR_getrandom) on Linux; route it to
         * the SwiftOS virtio-rng entropy source so RAND_status() reports ready. */
        return (long)getrandom((void *)a0, (size_t)a1, (unsigned int)a2);
    default:
        errno = ENOSYS;
        return -1;
    }
}

/* getrandom via the SwiftOS virtio-rng entropy stub (_getentropy in
 * newlib_syscalls.c), chunked to its 256-byte limit. */
extern int _getentropy(void *buf, size_t len);
ssize_t getrandom(void *buf, size_t buflen, unsigned int flags) {
    (void)flags;
    size_t off = 0;
    while (off < buflen) {
        size_t chunk = buflen - off;
        if (chunk > 256) chunk = 256;
        if (_getentropy((char *)buf + off, chunk) != 0) return -1;
        off += chunk;
    }
    return (ssize_t)buflen;
}

/* Service-by-port reverse lookup: SwiftOS has no services DB, so report
 * not-found (success with NULL result) and let c-ares use the numeric port. */
struct servent;
int getservbyport_r(int port, const char *proto, struct servent *result_buf,
                    char *buf, size_t buflen, struct servent **result) {
    (void)port; (void)proto; (void)result_buf; (void)buf; (void)buflen;
    if (result) *result = (struct servent *)0;
    return 0;
}

// SwiftOS does not page user memory, so madvise hints (MADV_DONTNEED/FREE) are
// accepted as no-ops; the memory simply stays mapped.
int madvise(void *addr, size_t length, int advice) {
    (void)addr; (void)length; (void)advice; return 0;
}

/* SwiftOS cannot relocate a mapping; fail so callers fall back to munmap+mmap. */
void *mremap(void *old_address, size_t old_size, size_t new_size, int flags, ...) {
    (void)old_address; (void)old_size; (void)new_size; (void)flags;
    errno = ENOSYS;
    return (void *)-1;   /* MAP_FAILED */
}

/* Page locking is advisory and unsupported; succeed as a no-op. */
int mlock(const void *addr, size_t len) { (void)addr; (void)len; return 0; }
int munlock(const void *addr, size_t len) { (void)addr; (void)len; return 0; }
int mlockall(int flags) { (void)flags; return 0; }
int munlockall(void) { return 0; }

// No ELF auxiliary vector on SwiftOS: report no optional CPU-feature bits, so
// V8's cpu.cc falls back to the AArch64 baseline.
unsigned long getauxval(unsigned long type) { (void)type; return 0; }

// pthread_getattr_np is implemented in userland/compat/stubs.c, where the
// per-thread stack records (and the main-thread bounds) live; V8 needs the REAL
// stack base/size for its conservative GC stack scan (a bogus base trips
// CHECK_GE(stack_start, sp) when a GC runs).

int recvmmsg(int fd, struct mmsghdr *msgvec, unsigned int vlen, int flags,
             struct timespec *timeout) {
    (void)fd; (void)msgvec; (void)vlen; (void)flags; (void)timeout;
    errno = ENOSYS; return -1;
}
int sendmmsg(int fd, struct mmsghdr *msgvec, unsigned int vlen, int flags) {
    (void)fd; (void)msgvec; (void)vlen; (void)flags;
    errno = ENOSYS; return -1;
}

/* ----- dynamic loading (static-only OS) ----------------------------------- */

static const char *node_compat_dlerr;

void *dlopen(const char *filename, int flags) {
    (void)filename; (void)flags;
    node_compat_dlerr = "dynamic loading is not supported on SwiftOS";
    return NULL;
}
void *dlsym(void *handle, const char *symbol) {
    (void)handle; (void)symbol;
    node_compat_dlerr = "dynamic loading is not supported on SwiftOS";
    return NULL;
}
int dlclose(void *handle) { (void)handle; return 0; }
int dladdr(const void *addr, Dl_info *info) {
    (void)addr; (void)info;
    return 0;   /* dladdr returns 0 on failure (no dynamic symbol info) */
}
char *dlerror(void) {
    const char *m = node_compat_dlerr;
    node_compat_dlerr = NULL;
    return (char *)m;
}

/* ----- POSIX functions newlib lacks (implemented over what we have) ------- */

ssize_t pread(int fd, void *buf, size_t count, off_t offset) {
    off_t cur = lseek(fd, 0, SEEK_CUR);
    if (cur < 0) return -1;
    if (lseek(fd, offset, SEEK_SET) < 0) return -1;
    ssize_t r = read(fd, buf, count);
    int e = errno;
    (void)lseek(fd, cur, SEEK_SET);
    if (r < 0) errno = e;
    return r;
}

ssize_t pwrite(int fd, const void *buf, size_t count, off_t offset) {
    off_t cur = lseek(fd, 0, SEEK_CUR);
    if (cur < 0) return -1;
    if (lseek(fd, offset, SEEK_SET) < 0) return -1;
    ssize_t r = write(fd, buf, count);
    int e = errno;
    (void)lseek(fd, cur, SEEK_SET);
    if (r < 0) errno = e;
    return r;
}

int dup3(int oldfd, int newfd, int flags) {
    if (oldfd == newfd) { errno = EINVAL; return -1; }
    int r = dup2(oldfd, newfd);
    if (r < 0) return r;
    if (flags & O_CLOEXEC) (void)fcntl(newfd, F_SETFD, FD_CLOEXEC);
    return r;
}

int fdatasync(int fd) { (void)fd; return 0; }   /* tmpfs: data loss on reboot ok */

long pathconf(const char *path, int name) { (void)path; (void)name; return 4096; }

/* No per-file timestamps yet (see docs/NOTES.md utimes gap). */
int futimens(int fd, const struct timespec times[2]) {
    (void)fd; (void)times; errno = ENOSYS; return -1;
}
int utimensat(int dirfd, const char *path, const struct timespec times[2], int flags) {
    (void)dirfd; (void)path; (void)times; (void)flags; errno = ENOSYS; return -1;
}
int lchown(const char *path, uid_t owner, gid_t group) {
    (void)path; (void)owner; (void)group; errno = ENOSYS; return -1;
}

/* SwiftOS is effectively single-user; no group lists. */
int setgroups(int ngroups, const gid_t *list) { (void)ngroups; (void)list; return 0; }
static int swos_fill_passwd(struct passwd *pwd, char *buf, size_t buflen,
                            const char *name, uid_t uid, gid_t gid,
                            const char *dir, const char *shell,
                            struct passwd **result) {
    size_t need, nlen, dlen, slen;
    char *p;
    if (!pwd || !buf || !result) { return EINVAL; }
    nlen = strlen(name) + 1;
    dlen = strlen(dir) + 1;
    slen = strlen(shell) + 1;
    need = nlen + dlen + slen;
    if (buflen < need) { *result = NULL; return ERANGE; }
    p = buf;
    pwd->pw_name = p;
    memcpy(p, name, nlen);
    p += nlen;
    pwd->pw_dir = p;
    memcpy(p, dir, dlen);
    p += dlen;
    pwd->pw_shell = p;
    memcpy(p, shell, slen);
    pwd->pw_uid = uid;
    pwd->pw_gid = gid;
    pwd->pw_passwd = (char *)"";
    *result = pwd;
    return 0;
}

int getpwuid_r(uid_t uid, struct passwd *pwd, char *buf, size_t buflen,
               struct passwd **result) {
    if (!result) { return EINVAL; }
    if (uid != 0) { *result = NULL; return 0; }
    return swos_fill_passwd(pwd, buf, buflen, "root", 0, 0, "/root",
                            "/bin/busybox", result);
}
int getgrgid_r(gid_t gid, struct group *grp, char *buf, size_t buflen,
               struct group **result) {
    (void)gid; (void)grp; (void)buf; (void)buflen;
    if (result) *result = NULL;
    return ENOSYS;
}

/* Scheduling: SwiftOS exposes no POSIX priorities/affinity to userland yet. */
int sched_yield(void) { return 0; }
int sched_getcpu(void) { return 0; }
int sched_get_priority_max(int policy) { (void)policy; return 0; }
int sched_get_priority_min(int policy) { (void)policy; return 0; }
int pthread_getschedparam(pthread_t t, int *policy, struct sched_param *param) {
    (void)t;
    if (policy) *policy = SCHED_OTHER;
    if (param) param->sched_priority = 0;
    return 0;
}
int pthread_setschedparam(pthread_t t, int policy, const struct sched_param *param) {
    (void)t; (void)policy; (void)param; return 0;
}
int pthread_getaffinity_np(pthread_t t, size_t sz, cpu_set_t *set) {
    (void)t; (void)sz;
    if (!set) { errno = EFAULT; return -1; }
    CPU_ZERO(set);
    CPU_SET(0, set);
    return 0;
}
int pthread_setaffinity_np(pthread_t t, size_t sz, const cpu_set_t *set) {
    (void)t; (void)sz; (void)set; return 0;   /* affinity not enforced */
}

int scandir(const char *dirp, struct dirent ***namelist,
            int (*filter)(const struct dirent *),
            int (*compar)(const struct dirent **, const struct dirent **)) {
    DIR *d = opendir(dirp);
    if (!d) return -1;
    struct dirent **list = NULL;
    size_t n = 0, cap = 0;
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        if (filter && !filter(ent)) continue;
        if (n == cap) {
            size_t ncap = cap ? cap * 2 : 16;
            struct dirent **nl = realloc(list, ncap * sizeof(*nl));
            if (!nl) goto fail;
            list = nl; cap = ncap;
        }
        struct dirent *copy = malloc(sizeof(*copy));
        if (!copy) goto fail;
        memcpy(copy, ent, sizeof(*copy));
        list[n++] = copy;
    }
    closedir(d);
    if (compar && n > 1)
        qsort(list, n, sizeof(*list),
              (int (*)(const void *, const void *))compar);
    *namelist = list;
    return (int)n;
fail:
    for (size_t i = 0; i < n; i++) free(list[i]);
    free(list);
    closedir(d);
    errno = ENOMEM;
    return -1;
}

/* ----- dynamic-link introspection (static-only OS: nothing to report) ----- */

struct r_debug _r_debug;   /* zeroed: no dynamic link map */

int dl_iterate_phdr(int (*callback)(struct dl_phdr_info *, size_t, void *),
                    void *data) {
    (void)callback; (void)data;
    return 0;   /* no shared objects to iterate */
}

/* ucontext coroutines are unsupported (no makecontext-based fibers). */
int getcontext(ucontext_t *ucp) { (void)ucp; errno = ENOSYS; return -1; }
int setcontext(const ucontext_t *ucp) { (void)ucp; errno = ENOSYS; return -1; }
void makecontext(ucontext_t *ucp, void (*func)(void), int argc, ...) {
    (void)ucp; (void)func; (void)argc;
}
int swapcontext(ucontext_t *oucp, const ucontext_t *ucp) {
    (void)oucp; (void)ucp; errno = ENOSYS; return -1;
}

/* ----- OpenSSL CPU-probe suppression --------------------------------------
 * OpenSSL detects optional Arm crypto extensions (AES, SHA, PMULL, and also
 * SM3/SM4/SVE2) by *executing* a candidate instruction and catching the SIGILL
 * the CPU raises when the extension is absent (e.g. SM3 on cortex-a72). SwiftOS
 * does not yet deliver SIGILL to EL0 for an undefined instruction -- it panics
 * the kernel -- so the probe is fatal. OpenSSL skips the whole SIGILL dance when
 * the OPENSSL_armcap env var is set, falling back to portable C crypto. Set it
 * to 0 from a high-priority constructor so it lands before OpenSSL's own
 * cpuid-setup constructor reads it. (environ is live: crt0 sets it before the
 * .init_array loop that runs these constructors.) */
__attribute__((constructor(101)))
static void swos_disable_openssl_cpu_probe(void) {
    setenv("OPENSSL_armcap", "0", 1);
}

/* ----- freestanding-link support ------------------------------------------
 * Symbols that V8 and libstdc++ reference but a bare-metal newlib/libstdc++ on
 * a static-only OS doesn't provide. We link Node with -nostartfiles, so the
 * crtbegin.o that would define __dso_handle is absent; provide it ourselves.
 * The rest are user/group/fs/signal calls Node touches at startup; SwiftOS has
 * no passwd/group database and a minimal fs surface, so they degrade safely. */
void *__dso_handle = 0;   /* anchor for __cxa_atexit global-dtor registration */

int truncate(const char *path, off_t length) {
    (void)path; (void)length; errno = ENOSYS; return -1;
}
int fchmodat(int fd, const char *path, mode_t mode, int flag) {
    (void)fd; (void)path; (void)mode; (void)flag; errno = ENOSYS; return -1;
}
int pthread_kill(pthread_t thread, int sig) {
    (void)thread; (void)sig; return 0;   /* no cross-thread signalling */
}
int getpwnam_r(const char *name, struct passwd *pwd, char *buf, size_t buflen,
               struct passwd **result) {
    if (!name || !result) { return EINVAL; }
    if (strcmp(name, "root") != 0) { *result = NULL; return 0; }
    return swos_fill_passwd(pwd, buf, buflen, "root", 0, 0, "/root",
                            "/bin/busybox", result);
}
int getgrnam_r(const char *name, struct group *grp, char *buf, size_t buflen,
               struct group **result) {
    (void)name; (void)grp; (void)buf; (void)buflen;
    *result = NULL; return 0;   /* not found: no group database */
}

/* ----- data symbol -------------------------------------------------------- */

const struct in6_addr in6addr_any = { { 0 } };
