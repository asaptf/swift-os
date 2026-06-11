// swift_user.h — C bridge used by Embedded Swift userland programs.

#ifndef SWIFTOS_USER_SWIFT_USER_H
#define SWIFTOS_USER_SWIFT_USER_H

#define SWIFTOS_PS_MAX 16

struct swiftos_ps_entry {
    unsigned int pid;
    unsigned int ppid;
    unsigned int state;
    char name[20];
};

int swiftos_ps_refresh(void);
unsigned int swiftos_ps_pid(int index);
unsigned int swiftos_ps_ppid(int index);
unsigned int swiftos_ps_state(int index);
const char *swiftos_ps_name(int index);

void swiftos_putc(unsigned char c);
void swiftos_puts(const char *s);
// Write count bytes to fd; returns bytes written (or negative errno).
long swiftos_write(int fd, const void *buf, unsigned long count);
// Current working directory into buf (size bytes); returns length or negative.
long swiftos_getcwd(char *buf, unsigned long size);
// Filesystem mutations (tmpfs only; the base is read-only). 0 on success, else
// a negative errno.
int swiftos_mkdir(const char *path);
int swiftos_rmdir(const char *path);
int swiftos_unlink(const char *path);
int swiftos_rename(const char *oldpath, const char *newpath);
int swiftos_chmod(const char *path, unsigned int mode);
int swiftos_chown(const char *path, unsigned int owner);
// Current wall-clock time in Unix seconds (0 if no RTC).
unsigned long swiftos_time(void);
// Current program break (sbrk(0)) — for reporting bounded heap growth.
unsigned long swiftos_heap_break(void);
// Format Unix seconds as UTC "YYYY-MM-DD HH:MM:SS" into out (>= 20 bytes).
void swiftos_fmt_time(unsigned long t, char *out);
// Block the calling process for at least sec seconds + nsec nanoseconds
// (resolution = one timer tick). Yields the CPU meanwhile.
void swiftos_nanosleep(unsigned long sec, unsigned long nsec);

// Thin syscall bridges for Swift userland (e.g. console-login).
int  swiftos_open(const char *path, int flags);
long swiftos_read(int fd, void *buf, unsigned long count);
int  swiftos_close(int fd);
int  swiftos_pipe(int fds[2]);
long swiftos_spawn_handles_raw(const char *path, void *argv, const void *handles,
                               unsigned long handle_count);
// Read directory entries (kernel dirent layout) into buf; returns bytes used.
long swiftos_getdents(int fd, void *buf, unsigned long count);
// Stat a path. Fills the provided fields (any may be NULL). Returns 0 on success.
int  swiftos_stat(const char *path, unsigned int *mode, unsigned int *uid,
                  unsigned int *gid, unsigned int *nlink, unsigned long *size,
                  unsigned long *mtime);
int  swiftos_login(unsigned int principal, unsigned int session, unsigned long caps);
// U1c: confirm the booted A/B update slot healthy (CONFIRMED). Needs CAP_CONSOLE.
// 0 on success; negative on error (-1 EPERM, -19 ENODEV when not store-booted).
int  swiftos_update_confirm(void);
// U1e: promote the inactive A/B slot to active for the next boot (on trial).
// Needs CAP_CONSOLE. 0 on success; negative on error.
int  swiftos_update_activate(void);
// U1f-2b: copy the attached payload disk into the inactive A/B slot. Needs
// CAP_CONSOLE. 0 on success; negative on error.
int  swiftos_update_stage(void);
// U1g-4c: copy the active kernel slot's image into the inactive ESP slot. Needs
// CAP_CONSOLE. 0 on success; negative on error.
int  swiftos_kernel_stage(void);
// U1g-5d: flip the active kernel slot via the loader-managed kernel-state.
// Needs CAP_CONSOLE. 0 on success; negative on error.
int  swiftos_kernel_activate(void);
// U1g-5c: mark the booted ESP kernel slot healthy (CONFIRMED). Needs
// CAP_CONSOLE. 0 on success; negative on error.
int  swiftos_kernel_confirm(void);
// Fetch the current security context; returns 0 on success.
int  swiftos_context(unsigned int *principal, unsigned int *session, unsigned long *caps);
int  swiftos_pkg_install(int fd, const char *name, const char *version_revision);
int  swiftos_pkg_info(int index, char *buf, unsigned long cap);
int  swiftos_pkg_stream_begin(const char *name, const char *version_revision,
                              unsigned long payload_size,
                              const unsigned char *payload_sha256);
int  swiftos_pkg_stream_write(const void *buf, unsigned long count);
int  swiftos_pkg_stream_commit(void);
int  swiftos_pkg_stream_abort(void);
// Replace this image with `path`, passing argv = { "sh", NULL }. Returns on error.
int  swiftos_exec_shell(const char *path);
// Toggle terminal echo on fd 0 (off while reading a password). Non-zero = on.
void swiftos_set_echo(int on);
// Toggle raw mode on fd 0 (off = canonical). Raw clears ICANON+ECHO so a single
// keypress is delivered without Enter and is not echoed (for /bin/top's 'q');
// ISIG is kept so Ctrl-C still works. set_raw(0) restores the saved flags.
void swiftos_set_raw(int on);

// ---- /bin/top: system + per-process statistics --------------------------
#define SWIFTOS_TOP_MAX 16
#define SWIFTOS_CPU_MAX 8

// Refresh the cached system-stats blob (SYS_SYSINFO). 0 on success, else < 0.
int swiftos_sysinfo_refresh(void);
unsigned long swiftos_sys_uptime_ticks(void);
unsigned long swiftos_sys_idle_ticks(void);
unsigned long swiftos_sys_mem_total(void);   // bytes of physical RAM
unsigned long swiftos_sys_mem_free(void);    // bytes of free frames
unsigned long swiftos_sys_kernel_image(void);// bytes the kernel statically occupies
unsigned long swiftos_sys_kernel_heap(void); // bytes used in the kernel bump heap
unsigned int  swiftos_sys_hz(void);          // scheduler ticks per second
unsigned int  swiftos_sys_proc_total(void);
unsigned int  swiftos_sys_proc_running(void);
unsigned int  swiftos_sys_cpu_count(void);
unsigned int  swiftos_sys_cpu_capacity(void);
unsigned long swiftos_sys_cpu_ticks(unsigned int cpu);
unsigned long swiftos_sys_cpu_idle_ticks(unsigned int cpu);

// Refresh the cached per-process table (SYS_PROCSTAT). Returns the process
// count (< 0 on error); accessors below are valid for index 0..count-1.
int  swiftos_top_refresh(void);
unsigned int  swiftos_top_pid(int i);
unsigned int  swiftos_top_ppid(int i);
unsigned int  swiftos_top_state(int i);
unsigned int  swiftos_top_principal(int i);
unsigned long swiftos_top_cpu_ticks(int i);
unsigned long swiftos_top_start_tick(int i);
unsigned long swiftos_top_res_bytes(int i);
const char   *swiftos_top_name(int i);

// UDP sockets (net-b). IPv4 addresses are host order (e.g. 0x0A000202 = 10.0.2.2).
// swiftos_socket() opens a SOCK_DGRAM / AF_INET socket (needs the net capability)
// and returns an fd, or a negative errno. Use the _ipv6 variants for AF_INET6=10.
// For AF_INET6 sockets, sendto/recvfrom must use the v6 extended msg layout
// (34 bytes: buf u64@0, len u32@8, 16-byte IPv6@12, port u16@28, scope u32@30).
int  swiftos_socket(void);
int  swiftos_socket_ipv6(void);
int  swiftos_bind(int fd, unsigned short port);
long swiftos_sendto(int fd, const void *buf, unsigned long len,
                    unsigned int ip, unsigned short port);
// Receive one datagram (blocking, bounded). Fills *ip/*port (may be NULL) with
// the sender. Returns the byte count or a negative errno.
long swiftos_recvfrom(int fd, void *buf, unsigned long cap,
                      unsigned int *ip, unsigned short *port);

// IPv6 variants for UDP send/recv (use only on AF_INET6 sockets created via
// swiftos_socket_ipv6). ip6 is 16 bytes in network (big-endian) order.
long swiftos_sendto_ipv6(int fd, const void *buf, unsigned long len,
                         const unsigned char ip6[16], unsigned short port);
long swiftos_recvfrom_ipv6(int fd, void *buf, unsigned long cap,
                           unsigned char ip6[16], unsigned short *port);

// TCP (net-c2). swiftos_socket_stream() opens a SOCK_STREAM / AF_INET socket; data is read
// and written with swiftos_read/swiftos_write on the (accepted) connection fd.
// Use swiftos_socket_stream_ipv6() for AF_INET6 listeners (dual-stack passive TCPv6
// works via kernel; active v6 connect is not yet exposed for userland).
int swiftos_socket_stream(void);
int swiftos_socket_stream_ipv6(void);
int swiftos_listen(int fd, int backlog);
int swiftos_accept(int fd);
// Active open to (ip, port) — ip is host order (e.g. 0x0A000202 = 10.0.2.2).
int swiftos_connect(int fd, unsigned int ip, unsigned short port);
// Wait for events on a set of fds. `fds` points at an array of pollfd records
// (fd:int32 @0, events:int16 @4, revents:int16 @6 — 8 bytes each). POLLIN=0x001,
// POLLOUT=0x004, POLLHUP=0x010. Returns the number of ready fds, 0 on timeout.
long swiftos_poll(void *fds, unsigned long nfds, long timeout_ms);

#define AF_INET6 10  // for use with the _ipv6 socket creators (matches kernel)
// Resolve a hostname to an IPv4 (host order, e.g. 0x0A000202). server_ip 0 uses
// the slirp DNS (10.0.2.3); server_port 0 uses 53. Returns 0 on failure.
unsigned int swiftos_resolve(const char *name, unsigned int server_ip, unsigned short server_port);

// Threads + futex (rt-a). swiftos_thread_create spawns a new EL0 thread that
// shares this process's address space and runs entry(arg) on the given stack
// top; returns a thread id (>0) or a negative errno. The futex helpers operate
// on a 32-bit word at *uaddr: WAIT blocks while *uaddr == val; WAKE wakes up to
// `val` waiters and returns the number woken.
#define SWIFTOS_FUTEX_WAIT 0
#define SWIFTOS_FUTEX_WAKE 1
int swiftos_thread_create(unsigned long entry, unsigned long arg, unsigned long stack_top);
int swiftos_futex(unsigned int *uaddr, int op, unsigned int val);
long swiftos_getpid(void);
// Terminate the calling thread (frees just this thread; the shared address
// space lives on for the others). A thread's entry function must call this
// rather than return — it was entered via eret with no valid return address.
void swiftos_thread_exit(void) __attribute__((noreturn));

// Anonymous mmap / munmap / mprotect (Track B). swiftos_mmap reserves `len`
// bytes of fresh zero-filled RAM with the given PROT bits and returns its base
// address (0 on failure — convenient for Swift, which has no errno). munmap and
// mprotect return 0 on success or a negative errno. PROT_NONE reserves VA without
// resident frames; mprotect commits/decommits pages. PROT_WRITE|PROT_EXEC is
// rejected (W^X); the JIT pattern is mmap RW, write code, mprotect RX, call.
#define SWIFTOS_PROT_NONE  0x0
#define SWIFTOS_PROT_READ  0x1
#define SWIFTOS_PROT_WRITE 0x2
#define SWIFTOS_PROT_EXEC  0x4
unsigned long swiftos_mmap(unsigned long len, int prot);
// File-backed read-only mmap (I2a): map [0, len) of the file open on `fd`,
// eagerly loaded from the read-only base image. Returns base VA, 0 on failure.
unsigned long swiftos_mmap_file(int fd, unsigned long len, int prot);
int swiftos_munmap(unsigned long addr, unsigned long len);
int swiftos_mprotect(unsigned long addr, unsigned long len, int prot);

// Atomic primitives over a 32-bit word (low-level LL/SC the Swift layer cannot
// express directly). CAS returns the value read before the attempt; the swap
// succeeded iff that equals `expected`. Used to build a futex mutex in Swift.
unsigned int swiftos_atomic_cas(unsigned int *p, unsigned int expected, unsigned int desired);
unsigned int swiftos_atomic_swap(unsigned int *p, unsigned int desired);
// Atomic load / fetch-add on a 32-bit word.
unsigned int swiftos_atomic_load(unsigned int *p);
unsigned int swiftos_atomic_add(unsigned int *p, unsigned int delta);

#endif // SWIFTOS_USER_SWIFT_USER_H
