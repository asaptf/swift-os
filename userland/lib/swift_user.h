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
// Flush an open file's data to stable media (datafs durability). 0 on success.
int  swiftos_fsync(int fd);
// Reposition fd offset (whence: 0=SET, 1=CUR, 2=END). Returns new offset or <0.
long swiftos_lseek(int fd, long offset, int whence);
// Resize an open file to length bytes (tmpfs only). 0 on success, else <0.
int  swiftos_ftruncate(int fd, long length);
// Allocate a pseudo-terminal pair; writes the master fd to *master and the
// slave fd to *slave. Returns 0 on success, else <0.
int  swiftos_openpty(int *master, int *slave);
// Set the foreground process (target of tty-generated signals like Ctrl-C) for
// the PTY referenced by `fd` (either end). `pid` of 0 clears it. Returns 0/-errno.
int  swiftos_pty_set_foreground(int fd, int pid);
int  swiftos_pipe(int fds[2]);
long swiftos_spawn_handles_raw(const char *path, void *argv, const void *handles,
                               unsigned long handle_count);

// LA1: IPC + endpoint + fork + device + name-registry bridge for native Swift
// services (the documented low-level bridge exception to Swift-by-default — these
// just forward to the C-only inline syscalls in syscall.h). See
// userland/lib/userland_service.swift and userland/svc-*.swift.

// Device grant metadata (must stay byte-identical to syscall.h's struct).
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

// C6a: aggregate resource-accounting domain for one Cell (matches the kernel's
// 32-byte cell_stat record). `cell` echoes the queried CellId; the rest sum the
// live processes tagged with that cell.
#ifndef SWIFTOS_CELL_STAT_T
#define SWIFTOS_CELL_STAT_T
struct swiftos_cell_stat {
    unsigned int cell;
    unsigned int processes;
    unsigned long resident_pages;
    unsigned long cpu_ticks;
    unsigned int handles;
    unsigned int reserved;
};
#endif

// Device kind/bus/flag constants (mirror syscall.h; identical macro values).
#define SWIFTOS_DEVICE_KIND_PSEUDO_INPUT 1u
#define SWIFTOS_DEVICE_KIND_VIRTIO_INPUT 2u
#define SWIFTOS_DEVICE_KIND_VIRTIO_NET   3u
#define SWIFTOS_DEVICE_BUS_PSEUDO        1u
#define SWIFTOS_DEVICE_BUS_VIRTIO_MMIO   2u
#define SWIFTOS_DEVICE_FLAG_NO_MMIO_GRANT (1u << 0)
#define SWIFTOS_DEVICE_FLAG_DISCOVERED    (1u << 1)
#define SWIFTOS_DEVICE_FLAG_MMIO_GRANT    (1u << 2)
#define SWIFTOS_DEVICE_FLAG_IRQ_GRANT     (1u << 3)
#define SWIFTOS_DEVICE_FLAG_DMA_GRANT     (1u << 4)
#define SWIFTOS_DEVICE_FLAG_HARDWARE_AUTHORITY \
    (SWIFTOS_DEVICE_FLAG_MMIO_GRANT | SWIFTOS_DEVICE_FLAG_IRQ_GRANT | SWIFTOS_DEVICE_FLAG_DMA_GRANT)

// Create an IPC endpoint pair; ends[0] = send end, ends[1] = recv end. 0 on success.
int  swiftos_endpoint_create(int ends[2]);
// Send `len` bytes on an endpoint send end and, if handle_fd >= 0, transfer that
// handle to the peer (granting every right the sender holds). 0 on success, else <0.
long swiftos_ipc_send(int fd, const void *buf, unsigned long len, int handle_fd);
// Receive one message (blocking): copy up to `cap` bytes into buf, store any
// transferred handle's new fd in *out_handle_fd (-1 if none). Returns the byte
// count, or a negative errno.
long swiftos_ipc_recv(int fd, void *buf, unsigned long cap, int *out_handle_fd);
// Fork the calling process (COW): 0 in the child, the child pid in the parent,
// negative on error.
int  swiftos_fork(void);
// Claim / inspect / discover an opaque device grant (metadata-only authority).
// claim needs CAP_CONSOLE and returns an fd; info/discover return 0 or <0.
int  swiftos_device_claim(const char *name, struct swiftos_device_info *info);
// Named _query (not _info) to avoid clashing with the struct tag when imported
// into Swift, which shares one namespace for types and functions.
int  swiftos_device_query(int fd, struct swiftos_device_info *info);
int  swiftos_device_discover(int index, struct swiftos_device_info *info);
// C5h: map the MMIO window of the device claimed on `fd` into this process,
// gated on the grant's `.map` right (deviceFlagMmioGrant). Returns the mapped
// base VA (>= 0) on success, or a small negative errno (e.g. -13 EACCES when the
// grant is metadata-only). Returning a raw long keeps the Swift caller simple:
// test `< 0` for failure, otherwise reinterpret the value as the base pointer.
long swiftos_device_mmap(int fd, unsigned long len);
// C5i: resolve a VA in this process to its physical address, for a userland device
// driver programming DMA/virtqueue registers. Gated on `handle_fd` being a mappable
// device grant the caller owns. Returns the PA (>= RAM base) or a negative errno.
long swiftos_virt_to_phys(unsigned long va, int handle_fd);

// C5i: volatile MMIO/DMA-ring accessors — the low-level bridge Embedded Swift
// cannot express directly (a plain UnsafePointer load/store is not guaranteed
// volatile). Used by the userland virtio-input driver to touch device registers
// and the shared virtqueue. swiftos_dmb is a full data memory barrier (dsb sy),
// ordering ring writes before a device notification (and notifications before
// used-ring reads).
// C5j: inject one byte into the kernel tty input (as if typed on the console).
// Needs CAP_CONSOLE; returns 0, or -1 (EPERM) without it. Used by the userland
// virtio-input driver to feed decoded keystrokes to the line discipline.
int swiftos_tty_inject(unsigned char byte);

// C6a: read a CellId's aggregate resource-accounting domain into *out. Named
// _query (not _stat) so it does not clash with the swiftos_cell_stat struct tag
// when imported into Swift (one namespace for types and functions). Needs
// CAP_PROCESS_INSPECT. Returns the live process count in the cell (>= 0), or a
// negative errno.
int swiftos_cell_query(unsigned int cell, struct swiftos_cell_stat *out);

// C6b/C6c/C6d: allocate a fresh cell and return a control-handle fd (negative errno
// on failure); writes the new CellId to *out_cell_id when non-NULL. `root` is the
// cell's VFS namespace root (NULL or "/" = unconfined); `page_cap` is an optional
// hard resident-page ceiling (0 = unlimited). Needs CAP_CONSOLE.
int  swiftos_cell_create(const char *root, unsigned long page_cap,
                         unsigned int *out_cell_id);
// C6b: launch a process into the cell named by `cell_fd` (a control handle the
// caller holds), with the same explicit-handle inheritance ABI as
// swiftos_spawn_handles_async. Returns the child pid, or a negative errno (EBADF if
// cell_fd is not a cell handle the caller holds). Reap the child with swiftos_waitpid.
long swiftos_cell_spawn(int cell_fd, const char *path, void *argv,
                        const void *handles, unsigned long handle_count);
// C6d: enumerate the cell's live members into `buf` (up to `cap` u32 pids); returns
// the live member count. Needs the control handle.
int  swiftos_cell_pids(int cell_fd, void *buf, unsigned long cap);
// C6d: free the cell's CellId; returns 0, or EBUSY (negative) while members live.
int  swiftos_cell_destroy(int cell_fd);

unsigned int swiftos_mmio_read32(unsigned long addr);
void         swiftos_mmio_write32(unsigned long addr, unsigned int value);
unsigned short swiftos_mmio_read16(unsigned long addr);
void         swiftos_mmio_write16(unsigned long addr, unsigned short value);
void         swiftos_mmio_write64(unsigned long addr, unsigned long value);
void         swiftos_dmb(void);
// LA1 name registry: publish the recv end of an endpoint under a short name
// (needs CAP_CONSOLE), or resolve a name to a fresh send-end fd (negative /
// -ENOENT on failure).
int  swiftos_name_register(const char *name, int endpoint_fd);
int  swiftos_name_lookup(const char *name);
// Non-blocking explicit-handle spawn (LA1): the child runs concurrently and this
// returns its pid immediately (negative on error); reap it with swiftos_waitpid.
long swiftos_spawn_handles_async(const char *path, void *argv, const void *handles,
                                 unsigned long handle_count);
// Synchronously run `path` with a NULL-terminated argv (fork + exec + wait;
// stdin/stdout/stderr inherited). Returns the child's exit status, negative on
// error. Used by /bin/crond to launch scheduled jobs — argv[0] selects the
// busybox applet when path is /bin/sh (see kernel/user/exec.swift execResolve).
long swiftos_run(const char *path, char *const *argv);
// Read directory entries (kernel dirent layout) into buf; returns bytes used.
long swiftos_getdents(int fd, void *buf, unsigned long count);
// Stat a path. Fills the provided fields (any may be NULL). Returns 0 on success.
int  swiftos_stat(const char *path, unsigned int *mode, unsigned int *uid,
                  unsigned int *gid, unsigned int *nlink, unsigned long *size,
                  unsigned long *mtime);
int  swiftos_login(unsigned int principal, unsigned int session, unsigned long caps);
// Power control. Needs CAP_CONSOLE. Returns negative on failure (-1 EPERM); on
// success the machine reboots/powers off and never returns.
int  swiftos_reboot(void);
int  swiftos_poweroff(void);
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
// OS-3b: stream a signed base image into the inactive A/B slot from a userland
// buffer (begin/write*/commit/abort). 'version' is the monotonic OS version
// (must exceed the store's anti-rollback floor), 'total' the image length.
// All need CAP_CONSOLE. 0 on success; negative errno on error.
int  swiftos_update_stage_begin(unsigned long version, unsigned long total);
int  swiftos_update_stage_write(const void *buf, unsigned long count);
int  swiftos_update_stage_commit(void);
int  swiftos_update_stage_abort(void);
// OS-1c-2b: stream a NEW host-signed kernel into the inactive ESP slot, then
// commit its 104-byte signed manifest entry (the kernel verifies hash + per-slot
// Ed25519 signature). All need CAP_CONSOLE.
int  swiftos_kernel_install_begin(void);
int  swiftos_kernel_install_write(const void *buf, unsigned long count);
int  swiftos_kernel_install_commit(const void *entry);
int  swiftos_kernel_install_abort(void);
// Fetch the current security context; returns 0 on success.
int  swiftos_context(unsigned int *principal, unsigned int *session, unsigned long *caps);
// Fetch the effective AND real security identity (any out-param may be NULL).
// Effective = what the process can do now; real = who invoked it. They differ
// only after a setuid-on-exec (e.g. /bin/sudo). Returns 0 on success.
int  swiftos_context_ex(unsigned int *principal, unsigned int *session, unsigned long *caps,
                        unsigned int *real_principal, unsigned int *real_session,
                        unsigned long *real_caps);
// Replace this image with `path`, passing the given NULL-terminated argv. Returns
// only on error (negative). Used by /bin/sudo to become the target command.
int  swiftos_execv(const char *path, char *const argv[]);
// Export a serialized tail of the kernel log ring. Returns bytes written, or a
// negative errno-style value. Needs capLogExport.
long swiftos_log_read(void *buf, unsigned long cap, unsigned long max_count);
// Export in-memory log ring stats. Returns 0 or a negative errno-style value.
// Needs capLogExport.
int  swiftos_log_stats(unsigned long *capacity, unsigned long *available,
                       unsigned long *total_written, unsigned long *overwritten);
// Runtime entropy from the kernel RNG source. Returns bytes written, or a
// negative errno-style value when no source is attached.
long swiftos_random(void *buf, unsigned long count);

// Network status snapshot (SYS_NETINFO). Flags:
//   bit 0 ready, bit 1 DHCPv4 lease, bit 2 static IPv6 config, bit 3 IPv6 gateway.
#define SWIFTOS_NETINFO_READY   (1u << 0)
#define SWIFTOS_NETINFO_DHCP4   (1u << 1)
#define SWIFTOS_NETINFO_STATIC6 (1u << 2)
#define SWIFTOS_NETINFO_GW6     (1u << 3)
int swiftos_netinfo_refresh(void);
unsigned int swiftos_net_flags(void);
unsigned int swiftos_net_ipv4(void);
unsigned int swiftos_net_gateway4(void);
unsigned int swiftos_net_dns4(void);
unsigned int swiftos_net_mask4(void);
unsigned int swiftos_net_ipv6_prefix_len(void);
unsigned char swiftos_net_ipv6_byte(unsigned int index);
unsigned char swiftos_net_gateway6_byte(unsigned int index);

int  swiftos_pkg_install(int fd, const char *name, const char *version_revision);
int  swiftos_pkg_info(int index, char *buf, unsigned long cap);
int  swiftos_pkg_files(const char *name, char *buf, unsigned long cap);
int  swiftos_pkg_remove(const char *name);
int  swiftos_pkg_stream_begin(const char *name, const char *version_revision,
                              unsigned long payload_size,
                              const unsigned char *payload_sha256);
int  swiftos_pkg_stream_write(const void *buf, unsigned long count);
int  swiftos_pkg_stream_commit(void);
int  swiftos_pkg_stream_abort(void);
// Replace this image with `path`, passing argv = { "sh", NULL }. Returns on error.
int  swiftos_exec_shell(const char *path);
// HC35: fork and exec an interactive shell with slave_fd wired to the child's
// stdin/stdout/stderr (and all other fds closed). Returns the child pid in the
// parent, or <0 on fork error; never returns in the child.
int  swiftos_pty_spawn_shell(const char *path, int slave_fd);
// Wait for `pid` to exit; writes the wait-encoded status to *status (use
// (status >> 8) & 0xff for the exit code). Returns the pid, or <0 on error.
int  swiftos_waitpid(int pid, int *status);
// Toggle terminal echo on fd 0 (off while reading a password). Non-zero = on.
void swiftos_set_echo(int on);
// Toggle raw mode on fd 0 (off = canonical). Raw clears ICANON+ECHO so a single
// keypress is delivered without Enter and is not echoed (for /bin/top's 'q');
// ISIG is kept so Ctrl-C still works. set_raw(0) restores the saved flags.
void swiftos_set_raw(int on);

// Per-fd c_lflag (third termios word) accessor + setter. Unlike set_echo/set_raw
// (which act on fd 0), these take an explicit fd so a test can prove tcgetattr/
// tcsetattr route to the terminal behind that fd (pty end vs console).
unsigned int swiftos_tcget_lflag(int fd);
int swiftos_tcset_lflag(int fd, unsigned int lflag);

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
// Atomic load / store / fetch-add on a 32-bit word (SEQ_CST). The shared-memory
// ring (kernel/ipc/shmring.swift, built -D SHMRING_USER) uses load/store to
// publish and consume its cursors with acquire/release ordering across processes.
unsigned int swiftos_atomic_load(unsigned int *p);
void         swiftos_atomic_store(unsigned int *p, unsigned int v);
unsigned int swiftos_atomic_add(unsigned int *p, unsigned int delta);

// LA3 shared-memory ring. create returns a channel id (needs CAP_NET); map
// returns the base VA of the channel's pages mapped into this process (0 / a
// small negative on failure); close drops the creator's base reference.
long swiftos_shmring_create(unsigned long pages);
long swiftos_shmring_map(int id);
int  swiftos_shmring_close(int id);

#endif // SWIFTOS_USER_SWIFT_USER_H
