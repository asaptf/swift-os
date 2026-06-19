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
#define SYS_SYSINFO       46
#define SYS_PROCSTAT      47
#define SYS_THREAD_CREATE 48
#define SYS_FUTEX         49
#define SYS_CONFINE       50
#define SYS_ENDPOINT_CREATE 51
#define SYS_IPC_SEND      52
#define SYS_IPC_RECV      53
#define SYS_MMAP          54
#define SYS_MUNMAP        55
#define SYS_MPROTECT      56
#define SYS_NANOSLEEP     57
#define SYS_MMAP_FILE     59
#define SYS_SPAWN_HANDLES 58
#define SYS_PKG_INSTALL   60
#define SYS_PKG_INFO      61
#define SYS_DEVICE_CLAIM  62
#define SYS_DEVICE_INFO   63
#define SYS_DEVICE_DISCOVER 64
#define SYS_UPDATE_CONFIRM 65
#define SYS_UPDATE_ACTIVATE 66
#define SYS_UPDATE_STAGE 67
#define SYS_KERNEL_STAGE 68
#define SYS_KERNEL_ACTIVATE 69
#define SYS_KERNEL_CONFIRM 70
#define SYS_EVENTFD        71
#define SYS_PKG_STREAM_BEGIN 72
#define SYS_PKG_STREAM_WRITE 73
#define SYS_PKG_STREAM_COMMIT 74
#define SYS_PKG_STREAM_ABORT 75
#define SYS_SIGRETURN      76
#define SYS_LOG_READ       77
#define SYS_SOCKETPAIR     78
#define SYS_PKG_FILES      79
#define SYS_RANDOM         80
#define SYS_PKG_REMOVE     81
#define SYS_LOG_STATS      82
#define SYS_NETINFO        83
#define SYS_OPENPTY        84
#define SYS_PTY_SET_FOREGROUND 85
#define SYS_SECURITY_INFO_EX   86
#define SYS_FSYNC          87
#define SYS_SYNC           88
#define SYS_RECV           89
#define SYS_REBOOT         90
#define SYS_IPC_CALL       91
#define SYS_IPC_REPLY_RECV 92
#define SYS_IPC_BADGE      93
#define SYS_UPDATE_STAGE_BEGIN  94
#define SYS_UPDATE_STAGE_WRITE  95
#define SYS_UPDATE_STAGE_COMMIT 96
#define SYS_UPDATE_STAGE_ABORT  97
#define SYS_SPAWN_HANDLES_ASYNC 98
#define SYS_NAME_REGISTER       99
#define SYS_NAME_LOOKUP         100
#define SYS_SHMRING_CREATE      101
#define SYS_SHMRING_MAP         102
#define SYS_SHMRING_CLOSE       103

// reboot(cmd) command selectors (must match kernel/power/power.swift).
#define SWIFTOS_POWER_RESET 0  // PSCI SYSTEM_RESET — warm reboot
#define SWIFTOS_POWER_OFF   1  // PSCI SYSTEM_OFF   — power off / QEMU exit

// mmap protection bits (Track B). PROT_WRITE|PROT_EXEC is rejected (W^X).
#define PROT_NONE  0x0
#define PROT_READ  0x1
#define PROT_WRITE 0x2
#define PROT_EXEC  0x4
// mmap flags. Only anonymous private mappings are supported; fixed mappings are
// accepted inside an existing anonymous reservation.
#define MAP_PRIVATE   0x02
#define MAP_FIXED     0x10
#define MAP_ANONYMOUS 0x20
#define MAP_ANON      MAP_ANONYMOUS
#define MAP_NORESERVE 0x4000
#define MAP_FIXED_NOREPLACE 0x100000
#define MAP_FAILED    ((void *)-1)

// Handle rights and C2 spawn-with-handles ABI. Rights match
// kernel/vfs/handle.swift; the mask attenuates the inherited handle and can never
// add rights the source fd does not hold.
#define SWIFTOS_RIGHT_READ      (1u << 0)
#define SWIFTOS_RIGHT_WRITE     (1u << 1)
#define SWIFTOS_RIGHT_EXECUTE   (1u << 2)
#define SWIFTOS_RIGHT_MAP       (1u << 3)
#define SWIFTOS_RIGHT_DUPLICATE (1u << 4)
#define SWIFTOS_RIGHT_TRANSFER  (1u << 5)
#define SWIFTOS_RIGHT_GETATTR   (1u << 6)
#define SWIFTOS_RIGHT_SETATTR   (1u << 7)
#define SWIFTOS_RIGHT_ALL       (SWIFTOS_RIGHT_READ | SWIFTOS_RIGHT_WRITE | \
                                 SWIFTOS_RIGHT_EXECUTE | SWIFTOS_RIGHT_MAP | \
                                 SWIFTOS_RIGHT_DUPLICATE | SWIFTOS_RIGHT_TRANSFER | \
                                 SWIFTOS_RIGHT_GETATTR | SWIFTOS_RIGHT_SETATTR)
#define SWIFTOS_SPAWN_HANDLE_CLOEXEC (1u << 0)
// QW5: ipc_send `requested_rights` sentinel — "grant everything I hold". The
// kernel intersects requested ∩ held, and intersecting with all-ones is the
// identity, so this preserves the pre-QW5 move-everything behavior.
#define SWIFTOS_RIGHTS_ALL_INHERIT 0xFFFFFFFFu

#define SWIFTOS_DEVICE_KIND_PSEUDO_INPUT 1u
#define SWIFTOS_DEVICE_KIND_VIRTIO_INPUT 2u
#define SWIFTOS_DEVICE_BUS_PSEUDO        1u
#define SWIFTOS_DEVICE_BUS_VIRTIO_MMIO   2u
#define SWIFTOS_DEVICE_FLAG_NO_MMIO_GRANT (1u << 0)
#define SWIFTOS_DEVICE_FLAG_DISCOVERED    (1u << 1)
#define SWIFTOS_DEVICE_FLAG_DISCOVERED_MMIO SWIFTOS_DEVICE_FLAG_DISCOVERED
#define SWIFTOS_DEVICE_FLAG_MMIO_GRANT    (1u << 2)
#define SWIFTOS_DEVICE_FLAG_IRQ_GRANT     (1u << 3)
#define SWIFTOS_DEVICE_FLAG_DMA_GRANT     (1u << 4)
#define SWIFTOS_DEVICE_FLAG_HARDWARE_AUTHORITY \
    (SWIFTOS_DEVICE_FLAG_MMIO_GRANT | SWIFTOS_DEVICE_FLAG_IRQ_GRANT | SWIFTOS_DEVICE_FLAG_DMA_GRANT)

#ifndef __ASSEMBLER__

typedef unsigned long size_t;
typedef long ssize_t;

struct swiftos_log_stats {
    unsigned long capacity;
    unsigned long available;
    unsigned long total_written;
    unsigned long overwritten;
};

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

static inline long __syscall4(long n, long a0, long a1, long a2, long a3) {
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a0;
    register long x1 __asm__("x1") = a1;
    register long x2 __asm__("x2") = a2;
    register long x3 __asm__("x3") = a3;
    __asm__ volatile("svc #0"
                     : "+r"(x0)
                     : "r"(x8), "r"(x1), "r"(x2), "r"(x3)
                     : "memory");
    return x0;
}

static inline long __syscall6(long n, long a0, long a1, long a2, long a3, long a4, long a5) {
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a0;
    register long x1 __asm__("x1") = a1;
    register long x2 __asm__("x2") = a2;
    register long x3 __asm__("x3") = a3;
    register long x4 __asm__("x4") = a4;
    register long x5 __asm__("x5") = a5;
    __asm__ volatile("svc #0"
                     : "+r"(x0)
                     : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5)
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

// C3: confine this process's filesystem access to a subtree. Subsequent opens of
// paths outside it are denied. Confine-only (cannot widen). Negative on error.
static inline int confine(const char *path) {
    return (int)__syscall3(SYS_CONFINE, (long)path, 0, 0);
}

// C4a: message-passing IPC. endpoint_create fills ends[2] = {send, recv}.
// ipc_send copies `len` bytes from `buf` and, if handle_fd >= 0, transfers that
// handle to the peer; ipc_recv blocks until a message arrives, copies up to `cap`
// bytes into `buf`, stores any received handle's new fd in *out_handle_fd (else -1),
// and returns the byte count. Extra args ride a small msg struct (the 3-arg syscall
// ABI carries only (fd, &msg)), like sendto/recvfrom. Negative on error.
//
// QW5: ipc_send takes `requested_rights` — the rights the sender is willing to
// grant on the moved handle. The receiver gets held ∩ requested, a subset of what
// the sender held: monotonic attenuation that can never widen authority (e.g. a
// sender holding READ|WRITE|TRANSFER can hand over READ|TRANSFER only). Pass
// SWIFTOS_RIGHTS_ALL_INHERIT to grant everything held (the identity intersection,
// preserving the pre-QW5 behavior). Ignored when handle_fd < 0. See
// docs/CAPABILITIES.md §4.2.
//
// QW4: the recv msg struct grew to 32 bytes with a trailing out_badge VA — the
// sender send-capability's server-chosen badge (0 = unbadged). ipc_recv passes a
// zero out_badge VA (don't report); ipc_recv_badged supplies one. A server stamps
// a distinct badge into each client's send handle with ipc_badge, so one shared
// endpoint can tell its clients apart. See docs/CAPABILITIES.md §4.2.
static inline int endpoint_create(int ends[2]) {
    return (int)__syscall3(SYS_ENDPOINT_CREATE, (long)ends, 0, 0);
}
static inline long ipc_send(int fd, const void *buf, unsigned long len, int handle_fd,
                            unsigned int requested_rights) {
    // QW5: requested_rights appended at offset 20; buf/len/handle_fd keep their
    // pre-QW5 offsets 0/8/16 so the kernel's LE parse is unchanged for them.
    struct { unsigned long buf; unsigned long len; int handle_fd;
             unsigned int requested_rights; } m;
    m.buf = (unsigned long)buf;
    m.len = len;
    m.handle_fd = handle_fd;
    m.requested_rights = requested_rights;
    return __syscall3(SYS_IPC_SEND, fd, (long)&m, 0);
}
// QW4: like ipc_recv, but also reports the sender send-capability's badge (0 =
// unbadged) into *out_badge. Pass out_badge = 0 to skip reporting.
static inline long ipc_recv_badged(int fd, void *buf, unsigned long cap,
                                   int *out_handle_fd, unsigned int *out_badge) {
    struct { unsigned long buf; unsigned long cap;
             unsigned long out_handle_fd; unsigned long out_badge; } m;
    m.buf = (unsigned long)buf;
    m.cap = cap;
    m.out_handle_fd = (unsigned long)out_handle_fd;
    m.out_badge = (unsigned long)out_badge;
    return __syscall3(SYS_IPC_RECV, fd, (long)&m, 0);
}
static inline long ipc_recv(int fd, void *buf, unsigned long cap, int *out_handle_fd) {
    // Always sends the 32-byte struct with a zero out_badge VA, keeping the
    // kernel and ABI in lockstep (the kernel always reads 32 bytes).
    return ipc_recv_badged(fd, buf, cap, out_handle_fd, 0);
}
// QW4: stamp a server-chosen client tag onto a send-end endpoint handle. The badge
// travels with the send-capability and is reported to the receiver by
// ipc_recv_badged. 0 clears it. Rejected on a non-endpoint or recv-end fd.
static inline int ipc_badge(int fd, unsigned int badge) {
    return (int)__syscall3(SYS_IPC_BADGE, fd, (long)badge, 0);
}

// QW1: synchronous request/reply IPC over a transient kernel reply port — the
// L4/seL4-family call / reply_recv verbs in our 256-byte byte-message model.
// ipc_call sends `len` bytes from `buf` (and, if handle_fd >= 0, moves that
// handle) on an endpoint SEND end, then BLOCKS until the server replies; the
// reply bytes land in reply_buf (≤ reply_cap), any replied handle's new fd in
// *out_handle_fd (else -1), and the reply byte count is returned.
// ipc_reply_recv is the server hot loop: it replies to the previous request named
// by `reply_port` (pass 0 on the first turn / to skip the reply), then blocks for
// the next request, returning its bytes and writing the new request's reply token
// to *out_reply_port so the server can reply to it next turn. The msg-struct field
// order/offsets are byte-for-byte the kernel's LE parse in vfs.swift (u64 fields
// lead so the trailing int needs no struct padding). Negative errno on error.
static inline long ipc_call(int fd, const void *buf, unsigned long len, int handle_fd,
                            void *reply_buf, unsigned long reply_cap, int *out_handle_fd) {
    struct {
        unsigned long buf; unsigned long len;
        unsigned long reply_buf; unsigned long reply_cap;
        unsigned long out_handle_fd; int handle_fd;
    } m;
    m.buf = (unsigned long)buf;
    m.len = len;
    m.reply_buf = (unsigned long)reply_buf;
    m.reply_cap = reply_cap;
    m.out_handle_fd = (unsigned long)out_handle_fd;
    m.handle_fd = handle_fd;
    return __syscall3(SYS_IPC_CALL, fd, (long)&m, 0);
}
static inline long ipc_reply_recv(int fd, unsigned long reply_port,
                                  const void *reply_buf, unsigned long reply_len, int reply_handle_fd,
                                  void *recv_buf, unsigned long recv_cap, int *out_handle_fd,
                                  unsigned long *out_reply_port) {
    struct {
        unsigned long reply_port; unsigned long reply_buf; unsigned long reply_len;
        unsigned long recv_buf; unsigned long recv_cap;
        unsigned long out_handle_fd; unsigned long out_reply_port; int reply_handle_fd;
    } m;
    m.reply_port = reply_port;
    m.reply_buf = (unsigned long)reply_buf;
    m.reply_len = reply_len;
    m.recv_buf = (unsigned long)recv_buf;
    m.recv_cap = recv_cap;
    m.out_handle_fd = (unsigned long)out_handle_fd;
    m.out_reply_port = (unsigned long)out_reply_port;
    m.reply_handle_fd = reply_handle_fd;
    return __syscall3(SYS_IPC_REPLY_RECV, fd, (long)&m, 0);
}

// LA3 shared-memory ring (data-plane IPC). shmring_create reserves a full-duplex
// channel of `pages` contiguous pages (even, 2..8) and returns its id (needs the
// net capability); shmring_map maps a channel's pages read/write into the caller
// and returns the base VA (or a negative errno); shmring_close drops the
// creator's base reference. Records cross via the mapped pages with no syscall in
// the reserve/commit/peek/release path — see kernel/ipc/shmring.swift.
static inline long shmring_create(unsigned long pages) {
    return __syscall3(SYS_SHMRING_CREATE, (long)pages, 0, 0);
}
static inline long shmring_map(int id) {
    return __syscall3(SYS_SHMRING_MAP, id, 0, 0);
}
static inline int shmring_close(int id) {
    return (int)__syscall3(SYS_SHMRING_CLOSE, id, 0, 0);
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

struct swiftos_spawn_handle {
    int source_fd;
    int target_fd;
    unsigned int rights;
    unsigned int flags;
};

static inline long spawn_handles(const char *path, char *const argv[],
                                 const struct swiftos_spawn_handle *handles,
                                 size_t handle_count) {
    return __syscall4(SYS_SPAWN_HANDLES, (long)path, (long)argv,
                      (long)handles, (long)handle_count);
}

// LA1: non-blocking variant of spawn_handles. Same explicit-handle ABI, but the
// child runs concurrently and this returns the child pid immediately (negative on
// error) instead of blocking until it exits. The caller reaps it with waitpid.
static inline long spawn_handles_async(const char *path, char *const argv[],
                                       const struct swiftos_spawn_handle *handles,
                                       size_t handle_count) {
    return __syscall4(SYS_SPAWN_HANDLES_ASYNC, (long)path, (long)argv,
                      (long)handles, (long)handle_count);
}

// LA1 name registry. name_register publishes the RECV end of an endpoint under a
// short name (privileged, needs CAP_CONSOLE); name_lookup resolves a name and
// installs a fresh SEND-end handle into the caller, returning the new fd (or
// -ENOENT). See docs/CAPABILITIES.md / kernel/vfs/vfs.swift.
static inline int name_register(const char *name, int endpoint_fd) {
    return (int)__syscall3(SYS_NAME_REGISTER, (long)name, endpoint_fd, 0);
}
static inline int name_lookup(const char *name) {
    return (int)__syscall3(SYS_NAME_LOOKUP, (long)name, 0, 0);
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

// Effective + real identity (the swift-os ruid/euid analogue). After a
// setuid-on-exec the effective fields hold the file owner's authority while the
// real fields preserve the invoker; for an ordinary process they are equal.
struct security_info_ex {
    unsigned int principal;
    unsigned int session;
    unsigned long caps;
    unsigned int real_principal;
    unsigned int real_session;
    unsigned long real_caps;
};

static inline int security_info_ex(struct security_info_ex *info) {
    return (int)__syscall3(SYS_SECURITY_INFO_EX, (long)info, 0, 0);
}

// Replace the caller's security context after authenticating a principal.
// Privileged: only a process holding CAP_CONSOLE may call it. 0 on success,
// negative on error (e.g. -1 EPERM). The new context survives execve.
static inline int login(unsigned int principal, unsigned int session, unsigned long caps) {
    return (int)__syscall3(SYS_LOGIN, (long)principal, (long)session, (long)caps);
}

static inline int pkg_install(int fd, const char *name, const char *version_revision) {
    return (int)__syscall3(SYS_PKG_INSTALL, fd, (long)name, (long)version_revision);
}

static inline int pkg_info(int index, char *buf, size_t cap) {
    return (int)__syscall3(SYS_PKG_INFO, index, (long)buf, (long)cap);
}

static inline int pkg_files(const char *name, char *buf, size_t cap) {
    return (int)__syscall3(SYS_PKG_FILES, (long)name, (long)buf, (long)cap);
}

static inline int pkg_remove(const char *name) {
    return (int)__syscall3(SYS_PKG_REMOVE, (long)name, 0, 0);
}

struct swiftos_pkg_stream_begin_desc {
    char name[32];
    char version_revision[16];
    unsigned long payload_size;
    unsigned char payload_sha256[32];
};

static inline int pkg_stream_begin(const struct swiftos_pkg_stream_begin_desc *desc) {
    return (int)__syscall3(SYS_PKG_STREAM_BEGIN, (long)desc, 0, 0);
}

static inline int pkg_stream_write(const void *buf, size_t count) {
    return (int)__syscall3(SYS_PKG_STREAM_WRITE, (long)buf, (long)count, 0);
}

static inline int pkg_stream_commit(void) {
    return (int)__syscall3(SYS_PKG_STREAM_COMMIT, 0, 0, 0);
}

static inline int pkg_stream_abort(void) {
    return (int)__syscall3(SYS_PKG_STREAM_ABORT, 0, 0, 0);
}

// Guarded so the identical declaration in swift_user.h (the Swift-imported
// bridge header) does not clash when both headers are included together (LA1).
#ifndef SWIFTOS_DEVICE_INFO_T
#define SWIFTOS_DEVICE_INFO_T
struct swiftos_device_info {
    unsigned int kind;
    unsigned int bus;
    unsigned long mmio_base;
    unsigned long mmio_len;
    unsigned int irq;
    unsigned int flags;
    unsigned int generation;
    unsigned int claimed;
    char name[24];
};
#endif

static inline int device_claim(const char *name, struct swiftos_device_info *info) {
    return (int)__syscall3(SYS_DEVICE_CLAIM, (long)name, (long)info, 0);
}

static inline int device_info(int fd, struct swiftos_device_info *info) {
    return (int)__syscall3(SYS_DEVICE_INFO, fd, (long)info, 0);
}

static inline int device_discover(int index, struct swiftos_device_info *info) {
    return (int)__syscall3(SYS_DEVICE_DISCOVER, index, (long)info, 0);
}

// U1c: mark the A/B slot booted this session healthy (CONFIRMED), so it stops
// accruing boot attempts and is never rolled back. Privileged: needs CAP_CONSOLE.
// 0 on success; negative on error (-1 EPERM, -19 ENODEV when not store-booted).
static inline int update_confirm(void) {
    return (int)__syscall3(SYS_UPDATE_CONFIRM, 0, 0, 0);
}

// Power control: reboot the machine (SWIFTOS_POWER_RESET) or power it off
// (SWIFTOS_POWER_OFF). Privileged: needs CAP_CONSOLE. Returns negative on
// failure (-1 EPERM); on success the machine resets/powers off and never returns.
static inline int sys_reboot(unsigned long cmd) {
    return (int)__syscall3(SYS_REBOOT, (long)cmd, 0, 0);
}

// U1e: promote the inactive A/B slot to active for the next boot (the current
// slot becomes the fallback); the new active boots "on trial". Needs CAP_CONSOLE.
// 0 on success; negative on error (-1 EPERM, -19 ENODEV, -2 no inactive slot).
static inline int update_activate(void) {
    return (int)__syscall3(SYS_UPDATE_ACTIVATE, 0, 0, 0);
}

// U1f-2b: copy the attached read-only payload disk (a signed SWOSBASE image)
// into the inactive A/B slot, ready for update_activate + reboot. Needs
// CAP_CONSOLE. 0 on success; negative on error (-1 EPERM, -19 ENODEV when not
// store-booted or no payload disk, -22 EINVAL bad/non-v3 payload, -27 EFBIG
// payload too big for the slot, -5 EIO copy/write-back failure).
static inline int update_stage(void) {
    return (int)__syscall3(SYS_UPDATE_STAGE, 0, 0, 0);
}

// U1g-4c: copy the active kernel slot's image into the inactive ESP slot, in
// place, and verify it. Needs CAP_CONSOLE. 0 on success; negative on error
// (-1 EPERM, -19 ENODEV no ESP disk, -2 ENOENT missing file, -22 EINVAL size
// mismatch/bad manifest, -5 EIO copy/verify failure).
static inline int kernel_stage(void) {
    return (int)__syscall3(SYS_KERNEL_STAGE, 0, 0, 0);
}

// U1g-5d: flip the active kernel slot for the next boot by updating the
// loader-managed kernel-state on the ESP. Needs CAP_CONSOLE. 0 on success;
// negative on error (-1 EPERM, -19 ENODEV, -2 ENOENT, -22 EINVAL, -5 EIO).
static inline int kernel_activate(void) {
    return (int)__syscall3(SYS_KERNEL_ACTIVATE, 0, 0, 0);
}

// U1g-5c: mark the ESP kernel slot booted by the loader healthy (CONFIRMED), so
// it stops accruing attempts and is never rolled back. Needs CAP_CONSOLE.
// 0 on success; negative on error (-1 EPERM, -19 ENODEV, -2 ENOENT, -22 EINVAL,
// -5 EIO).
static inline int kernel_confirm(void) {
    return (int)__syscall3(SYS_KERNEL_CONFIRM, 0, 0, 0);
}

// OS-3b: stream a signed base image into the inactive A/B slot. begin reserves
// the slot ('version' is the monotonic OS version, which must exceed the store's
// anti-rollback floor; 'total' is the image length, which must fit the slot);
// write appends bytes; commit validates the SWOSBASE header + flushes + marks the
// slot present/untried; abort discards. All need CAP_CONSOLE. 0 on success;
// negative errno (-1 EPERM incl. anti-rollback, -19 ENODEV not store-booted,
// -27 EFBIG too big, -22 EINVAL bad request/header, -14 EFAULT bad buffer,
// -11 EAGAIN no active stage / wrong owner, -5 EIO write/flush failure).
static inline int update_stage_begin(unsigned long version, unsigned long total) {
    return (int)__syscall3(SYS_UPDATE_STAGE_BEGIN, (long)version, (long)total, 0);
}
static inline int update_stage_write(const void *buf, unsigned long count) {
    return (int)__syscall3(SYS_UPDATE_STAGE_WRITE, (long)buf, (long)count, 0);
}
static inline int update_stage_commit(void) {
    return (int)__syscall3(SYS_UPDATE_STAGE_COMMIT, 0, 0, 0);
}
static inline int update_stage_abort(void) {
    return (int)__syscall3(SYS_UPDATE_STAGE_ABORT, 0, 0, 0);
}

// Export a serialized tail of the kernel log ring into buf. Returns bytes
// written, or a negative errno-style value. Privileged: needs CAP_LOG_EXPORT.
static inline long log_read(void *buf, size_t cap, size_t max_count) {
    return __syscall3(SYS_LOG_READ, (long)buf, (long)cap, (long)max_count);
}

// Export in-memory log ring statistics. Layout is struct swiftos_log_stats.
// Privileged: needs CAP_LOG_EXPORT.
static inline int log_stats(struct swiftos_log_stats *out, size_t cap) {
    return (int)__syscall3(SYS_LOG_STATS, (long)out, (long)cap, 0);
}

// Grow the process heap by `incr` bytes; returns the previous break, or (void*)-1.
static inline void *sbrk(long incr) {
    return (void *)__syscall3(SYS_SBRK, incr, 0, 0);
}

// Anonymous mmap (Track B). Only MAP_ANONYMOUS|MAP_PRIVATE|MAP_NORESERVE plus
// MAP_FIXED/MAP_FIXED_NOREPLACE inside existing anonymous reservations is
// meaningful; fd and offset are ignored. PROT_NONE reserves VA without resident
// frames; mprotect or MAP_FIXED commits/decommits pages later. The raw syscall
// returns a base VA or a small negative errno; we convert the error range to
// MAP_FAILED. PROT_WRITE|PROT_EXEC is rejected (W^X).
static inline void *mmap(void *addr, size_t length, int prot, int flags, int fd, long offset) {
    long r = __syscall6(SYS_MMAP, (long)addr, (long)length, prot, flags, fd, offset);
    if (r < 0 && r >= -4095) {
        return MAP_FAILED;
    }
    return (void *)r;
}

static inline int munmap(void *addr, size_t length) {
    return (int)__syscall3(SYS_MUNMAP, (long)addr, (long)length, 0);
}

// Change protection on [addr, addr+length). RW->RX is the JIT path; RWX is
// rejected (W^X). 0 on success, negative errno otherwise.
static inline int mprotect(void *addr, size_t length, int prot) {
    return (int)__syscall3(SYS_MPROTECT, (long)addr, (long)length, prot);
}

#endif // __ASSEMBLER__
#endif // SWIFTOS_USER_SYSCALL_H
