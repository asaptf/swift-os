// swift_user.c — syscall bridge and tiny runtime hooks for Swift EL0 tools.

#include "swift_user.h"
#include "syscall.h"

unsigned long __stack_chk_guard = 0x53574946544f5355UL;

static struct swiftos_ps_entry ps_entries[SWIFTOS_PS_MAX];
static int ps_count;

static unsigned long align_up(unsigned long value, unsigned long alignment) {
    return (value + alignment - 1) & ~(alignment - 1);
}

static unsigned long c_strlen(const char *s) {
    unsigned long n = 0;
    while (s[n] != 0) {
        n += 1;
    }
    return n;
}

static int copy_cstr_bounded(char *dst, unsigned long cap, const char *src) {
    if (!dst || !src || cap == 0) return -22;
    unsigned long n = 0;
    while (n < cap && src[n] != 0) {
        dst[n] = src[n];
        n += 1;
    }
    if (n == 0 || n >= cap) return -22;
    dst[n] = 0;
    while (++n < cap) dst[n] = 0;
    return 0;
}

int swiftos_ps_refresh(void) {
    ps_count = (int)__syscall3(SYS_PSINFO, (long)ps_entries, SWIFTOS_PS_MAX, 0);
    return ps_count;
}

unsigned int swiftos_ps_pid(int index) {
    return (index >= 0 && index < ps_count && index < SWIFTOS_PS_MAX) ? ps_entries[index].pid : 0;
}

unsigned int swiftos_ps_ppid(int index) {
    return (index >= 0 && index < ps_count && index < SWIFTOS_PS_MAX) ? ps_entries[index].ppid : 0;
}

unsigned int swiftos_ps_state(int index) {
    return (index >= 0 && index < ps_count && index < SWIFTOS_PS_MAX) ? ps_entries[index].state : 0;
}

const char *swiftos_ps_name(int index) {
    if (index < 0 || index >= ps_count || index >= SWIFTOS_PS_MAX) {
        return "?";
    }
    return ps_entries[index].name;
}

void swiftos_putc(unsigned char c) {
    (void)write(1, &c, 1);
}

void swiftos_puts(const char *s) {
    (void)write(1, s, c_strlen(s));
}

long swiftos_write(int fd, const void *buf, unsigned long count) {
    return write(fd, buf, count);
}

long swiftos_getcwd(char *buf, unsigned long size) {
    return __syscall3(SYS_GETCWD, (long)buf, (long)size, 0);
}

int swiftos_mkdir(const char *path) {
    return (int)__syscall3(SYS_MKDIR, (long)path, 0755, 0);
}

int swiftos_rmdir(const char *path) {
    return (int)__syscall3(SYS_RMDIR, (long)path, 0, 0);
}

int swiftos_unlink(const char *path) {
    return (int)__syscall3(SYS_UNLINK, (long)path, 0, 0);
}

int swiftos_rename(const char *oldpath, const char *newpath) {
    return (int)__syscall3(SYS_RENAME, (long)oldpath, (long)newpath, 0);
}

int swiftos_chmod(const char *path, unsigned int mode) {
    return (int)__syscall3(SYS_CHMOD, (long)path, (long)mode, 0);
}

int swiftos_chown(const char *path, unsigned int owner) {
    return (int)__syscall3(SYS_CHOWN, (long)path, (long)owner, 0);
}

unsigned long swiftos_time(void) {
    return (unsigned long)__syscall3(SYS_TIME, 0, 0, 0);
}

void swiftos_nanosleep(unsigned long sec, unsigned long nsec) {
    __syscall3(SYS_NANOSLEEP, (long)sec, (long)nsec, 0);
}

static void put2(char *p, unsigned int v) { p[0] = '0' + (v / 10) % 10; p[1] = '0' + v % 10; }

void swiftos_fmt_time(unsigned long t, char *out) {
    unsigned long secs = t % 86400UL;
    unsigned int hh = (unsigned int)(secs / 3600);
    unsigned int mm = (unsigned int)((secs % 3600) / 60);
    unsigned int ss = (unsigned int)(secs % 60);
    // civil_from_days (Howard Hinnant): days since 1970-01-01 -> y/m/d.
    long z = (long)(t / 86400UL) + 719468;
    long era = (z >= 0 ? z : z - 146096) / 146097;
    unsigned long doe = (unsigned long)(z - era * 146097);
    unsigned long yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    long y = (long)yoe + era * 400;
    unsigned long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    unsigned long mp = (5 * doy + 2) / 153;
    unsigned int d = (unsigned int)(doy - (153 * mp + 2) / 5 + 1);
    unsigned int m = (unsigned int)(mp < 10 ? mp + 3 : mp - 9);
    if (m <= 2) y += 1;
    unsigned int yr = (unsigned int)y;
    // "YYYY-MM-DD HH:MM:SS"
    put2(out + 0, yr / 100); put2(out + 2, yr % 100); out[4] = '-';
    put2(out + 5, m); out[7] = '-';
    put2(out + 8, d); out[10] = ' ';
    put2(out + 11, hh); out[13] = ':';
    put2(out + 14, mm); out[16] = ':';
    put2(out + 17, ss); out[19] = 0;
}

int swiftos_open(const char *path, int flags) {
    return open(path, flags);
}

long swiftos_read(int fd, void *buf, unsigned long count) {
    return read(fd, buf, count);
}

int swiftos_close(int fd) {
    return close(fd);
}

int swiftos_fsync(int fd) {
    return (int)__syscall3(SYS_FSYNC, (long)fd, 0, 0);
}

long swiftos_lseek(int fd, long offset, int whence) {
    return __syscall3(SYS_LSEEK, fd, offset, whence);
}

int swiftos_ftruncate(int fd, long length) {
    return (int)__syscall3(SYS_FTRUNCATE, fd, length, 0);
}

int swiftos_openpty(int *master, int *slave) {
    return (int)__syscall3(SYS_OPENPTY, (long)master, (long)slave, 0);
}

int swiftos_pty_set_foreground(int fd, int pid) {
    return (int)__syscall3(SYS_PTY_SET_FOREGROUND, fd, pid, 0);
}

int swiftos_pipe(int fds[2]) {
    return (int)__syscall3(SYS_PIPE, (long)fds, 0, 0);
}

long swiftos_spawn_handles_raw(const char *path, void *argv, const void *handles,
                               unsigned long handle_count) {
    return __syscall4(SYS_SPAWN_HANDLES, (long)path, (long)argv, (long)handles,
                      (long)handle_count);
}

// ---- LA1: IPC / endpoint / fork / device / name-registry bridge -----------

int swiftos_endpoint_create(int ends[2]) {
    return endpoint_create(ends);
}

long swiftos_ipc_send(int fd, const void *buf, unsigned long len, int handle_fd) {
    // Grant every right held on the moved handle (the move-everything sentinel),
    // matching the pre-QW5 behavior the C demo relies on.
    return ipc_send(fd, buf, len, handle_fd, SWIFTOS_RIGHTS_ALL_INHERIT);
}

long swiftos_ipc_recv(int fd, void *buf, unsigned long cap, int *out_handle_fd) {
    return ipc_recv(fd, buf, cap, out_handle_fd);
}

int swiftos_fork(void) {
    return fork();
}

int swiftos_device_claim(const char *name, struct swiftos_device_info *info) {
    return device_claim(name, info);
}

int swiftos_device_query(int fd, struct swiftos_device_info *info) {
    return device_info(fd, info);
}

int swiftos_device_discover(int index, struct swiftos_device_info *info) {
    return device_discover(index, info);
}

long swiftos_device_mmap(int fd, unsigned long len) {
    // Raw syscall (not the device_mmap() inline) so the Swift caller sees the
    // exact base VA or negative errno instead of MAP_FAILED.
    return __syscall3(SYS_DEVICE_MMAP, fd, (long)len, 0);
}

long swiftos_virt_to_phys(unsigned long va, int handle_fd) {
    return virt_to_phys(va, handle_fd);
}

int swiftos_tty_inject(unsigned char byte) {
    return tty_inject(byte);
}

// Volatile MMIO/ring accessors (C5i). volatile guarantees the access is not
// elided or reordered by the compiler; on the Device-nGnRE register window the
// memory type also prevents hardware reordering. For the virtqueue (normal RAM)
// swiftos_dmb provides the device-visibility ordering.
unsigned int swiftos_mmio_read32(unsigned long addr) {
    return *(volatile unsigned int *)addr;
}
void swiftos_mmio_write32(unsigned long addr, unsigned int value) {
    *(volatile unsigned int *)addr = value;
}
unsigned short swiftos_mmio_read16(unsigned long addr) {
    return *(volatile unsigned short *)addr;
}
void swiftos_mmio_write16(unsigned long addr, unsigned short value) {
    *(volatile unsigned short *)addr = value;
}
void swiftos_mmio_write64(unsigned long addr, unsigned long value) {
    *(volatile unsigned long *)addr = value;
}
void swiftos_dmb(void) {
    __asm__ volatile("dsb sy" ::: "memory");
}

int swiftos_name_register(const char *name, int endpoint_fd) {
    return name_register(name, endpoint_fd);
}

int swiftos_name_lookup(const char *name) {
    return name_lookup(name);
}

long swiftos_spawn_handles_async(const char *path, void *argv, const void *handles,
                                 unsigned long handle_count) {
    return spawn_handles_async(path, (char *const *)argv,
                               (const struct swiftos_spawn_handle *)handles, handle_count);
}

long swiftos_run(const char *path, char *const *argv) {
    return spawn(path, argv);
}

long swiftos_getdents(int fd, void *buf, unsigned long count) {
    return __syscall3(SYS_GETDENTS, fd, (long)buf, (long)count);
}

// Kernel stat record (kernel/vfs/vfs.swift writeStatMode), 32 bytes.
struct swiftos_kstat {
    unsigned int mode;
    unsigned int uid;
    unsigned long size;
    unsigned int gid;
    unsigned int nlink;
    unsigned long mtime;
};

int swiftos_stat(const char *path, unsigned int *mode, unsigned int *uid,
                 unsigned int *gid, unsigned int *nlink, unsigned long *size,
                 unsigned long *mtime) {
    struct swiftos_kstat k;
    long rc = __syscall3(SYS_STAT, (long)path, (long)&k, 0);
    if (rc != 0) return (int)rc;
    if (mode)  *mode = k.mode;
    if (uid)   *uid = k.uid;
    if (gid)   *gid = k.gid;
    if (nlink) *nlink = k.nlink;
    if (size)  *size = k.size;
    if (mtime) *mtime = k.mtime;
    return 0;
}

int swiftos_login(unsigned int principal, unsigned int session, unsigned long caps) {
    return login(principal, session, caps);
}

int swiftos_update_confirm(void) {
    return update_confirm();
}

int swiftos_reboot(void) {
    return sys_reboot(SWIFTOS_POWER_RESET);
}

int swiftos_poweroff(void) {
    return sys_reboot(SWIFTOS_POWER_OFF);
}

int swiftos_update_activate(void) {
    return update_activate();
}

int swiftos_update_stage(void) {
    return update_stage();
}

int swiftos_kernel_stage(void) {
    return kernel_stage();
}

int swiftos_kernel_activate(void) {
    return kernel_activate();
}

int swiftos_kernel_confirm(void) {
    return kernel_confirm();
}

int swiftos_update_stage_begin(unsigned long version, unsigned long total) {
    return update_stage_begin(version, total);
}
int swiftos_update_stage_write(const void *buf, unsigned long count) {
    return update_stage_write(buf, count);
}
int swiftos_update_stage_commit(void) {
    return update_stage_commit();
}
int swiftos_update_stage_abort(void) {
    return update_stage_abort();
}

int swiftos_kernel_install_begin(void) {
    return kernel_install_begin();
}
int swiftos_kernel_install_write(const void *buf, unsigned long count) {
    return kernel_install_write(buf, count);
}
int swiftos_kernel_install_commit(const void *entry) {
    return kernel_install_commit(entry);
}
int swiftos_kernel_install_abort(void) {
    return kernel_install_abort();
}

int swiftos_context(unsigned int *principal, unsigned int *session, unsigned long *caps) {
    struct security_info si;
    int rc = security_info(&si);
    if (rc != 0) return rc;
    if (principal) *principal = si.principal;
    if (session) *session = si.session;
    if (caps) *caps = si.caps;
    return 0;
}

int swiftos_context_ex(unsigned int *principal, unsigned int *session, unsigned long *caps,
                       unsigned int *real_principal, unsigned int *real_session,
                       unsigned long *real_caps) {
    struct security_info_ex si;
    int rc = security_info_ex(&si);
    if (rc != 0) return rc;
    if (principal) *principal = si.principal;
    if (session) *session = si.session;
    if (caps) *caps = si.caps;
    if (real_principal) *real_principal = si.real_principal;
    if (real_session) *real_session = si.real_session;
    if (real_caps) *real_caps = si.real_caps;
    return 0;
}

int swiftos_execv(const char *path, char *const argv[]) {
    return execve(path, argv, 0);
}

long swiftos_log_read(void *buf, unsigned long cap, unsigned long max_count) {
    return log_read(buf, cap, max_count);
}

int swiftos_log_stats(unsigned long *capacity, unsigned long *available,
                      unsigned long *total_written, unsigned long *overwritten) {
    struct swiftos_log_stats stats;
    int rc = log_stats(&stats, sizeof(stats));
    if (rc != 0) return rc;
    if (capacity) *capacity = stats.capacity;
    if (available) *available = stats.available;
    if (total_written) *total_written = stats.total_written;
    if (overwritten) *overwritten = stats.overwritten;
    return 0;
}

long swiftos_random(void *buf, unsigned long count) {
    return __syscall3(SYS_RANDOM, (long)buf, (long)count, 0);
}

struct swiftos_netinfo_record {
    unsigned int flags;        // off 0
    unsigned int ipv4;         // off 4
    unsigned int gateway4;     // off 8
    unsigned int dns4;         // off 12
    unsigned int mask4;        // off 16
    unsigned char ipv6[16];    // off 20, network order
    unsigned char gateway6[16];// off 36, network order
    unsigned int prefix6;      // off 52
};

static struct swiftos_netinfo_record g_netinfo;

int swiftos_netinfo_refresh(void) {
    return (int)__syscall3(SYS_NETINFO, (long)&g_netinfo, sizeof(g_netinfo), 0);
}

unsigned int swiftos_net_flags(void) { return g_netinfo.flags; }
unsigned int swiftos_net_ipv4(void) { return g_netinfo.ipv4; }
unsigned int swiftos_net_gateway4(void) { return g_netinfo.gateway4; }
unsigned int swiftos_net_dns4(void) { return g_netinfo.dns4; }
unsigned int swiftos_net_mask4(void) { return g_netinfo.mask4; }
unsigned int swiftos_net_ipv6_prefix_len(void) { return g_netinfo.prefix6; }

unsigned char swiftos_net_ipv6_byte(unsigned int index) {
    return index < 16 ? g_netinfo.ipv6[index] : 0;
}

unsigned char swiftos_net_gateway6_byte(unsigned int index) {
    return index < 16 ? g_netinfo.gateway6[index] : 0;
}

int swiftos_pkg_install(int fd, const char *name, const char *version_revision) {
    return pkg_install(fd, name, version_revision);
}

int swiftos_pkg_info(int index, char *buf, unsigned long cap) {
    return pkg_info(index, buf, cap);
}

int swiftos_pkg_files(const char *name, char *buf, unsigned long cap) {
    return pkg_files(name, buf, cap);
}

int swiftos_pkg_remove(const char *name) {
    return pkg_remove(name);
}

int swiftos_pkg_stream_begin(const char *name, const char *version_revision,
                             unsigned long payload_size,
                             const unsigned char *payload_sha256) {
    if (!payload_sha256) return -22;
    struct swiftos_pkg_stream_begin_desc desc = {0};
    int rc = copy_cstr_bounded(desc.name, sizeof(desc.name), name);
    if (rc != 0) return rc;
    rc = copy_cstr_bounded(desc.version_revision, sizeof(desc.version_revision), version_revision);
    if (rc != 0) return rc;
    desc.payload_size = payload_size;
    for (unsigned long i = 0; i < sizeof(desc.payload_sha256); i++) {
        desc.payload_sha256[i] = payload_sha256[i];
    }
    return pkg_stream_begin(&desc);
}

int swiftos_pkg_stream_write(const void *buf, unsigned long count) {
    return pkg_stream_write(buf, count);
}

int swiftos_pkg_stream_commit(void) {
    return pkg_stream_commit();
}

int swiftos_pkg_stream_abort(void) {
    return pkg_stream_abort();
}

/* Return the basename of path (pointer into the same string, no allocation). */
static const char *shell_basename(const char *path) {
    const char *base = path;
    for (const char *p = path; *p; p++) {
        if (*p == '/') base = p + 1;
    }
    return *base ? base : path;
}

int swiftos_exec_shell(const char *path) {
    char *argv[] = { (char *)shell_basename(path), 0 };
    return execve(path, argv, 0);
}

int swiftos_pty_spawn_shell(const char *path, int slave_fd) {
    int pid = fork();
    if (pid != 0) return pid;            // parent (pid > 0) or fork error (< 0)
    // Child: wire the PTY slave to stdio, drop every inherited fd (listen/conn
    // sockets, the PTY master), then become the shell.
    dup2(slave_fd, 0);
    dup2(slave_fd, 1);
    dup2(slave_fd, 2);
    for (int fd = 3; fd < 32; fd++) close(fd);
    char *argv[] = { (char *)shell_basename(path), 0 };
    execve(path, argv, 0);
    __syscall3(SYS_EXIT, 127, 0, 0);     // exec failed
    return 0;                            // unreachable
}

int swiftos_waitpid(int pid, int *status) {
    return waitpid(pid, status, 0);
}

void swiftos_set_echo(int on) {
    // termios is four 32-bit words; c_lflag is word 3 (offset 12). ECHO = 1<<1.
    unsigned int t[4] = { 0, 0, 0, 0 };
    (void)__syscall3(SYS_TCGETATTR, 0, (long)t, 0);
    const unsigned int ECHO_BIT = 1u << 1;
    if (on) {
        t[3] |= ECHO_BIT;
    } else {
        t[3] &= ~ECHO_BIT;
    }
    (void)__syscall3(SYS_TCSETATTR, 0, 0, (long)t);
}

static unsigned int g_saved_lflag = (1u << 0) | (1u << 1) | (1u << 2); // ICANON|ECHO|ISIG

void swiftos_set_raw(int on) {
    unsigned int t[4] = { 0, 0, 0, 0 };
    (void)__syscall3(SYS_TCGETATTR, 0, (long)t, 0);
    const unsigned int ICANON_BIT = 1u << 0;
    const unsigned int ECHO_BIT = 1u << 1;
    if (on) {
        g_saved_lflag = t[3];
        t[3] &= ~(ICANON_BIT | ECHO_BIT); // keep ISIG so Ctrl-C still terminates top
    } else {
        t[3] = g_saved_lflag;
    }
    (void)__syscall3(SYS_TCSETATTR, 0, 0, (long)t);
}

// ---- /bin/top statistics (SYS_SYSINFO / SYS_PROCSTAT) ---------------------
// Kernel record layouts (must match kernel/user/process.swift).
struct top_sysinfo {
    unsigned long uptime_ticks;   // off 0
    unsigned long idle_ticks;     // off 8
    unsigned long mem_total;      // off 16
    unsigned long mem_free;       // off 24
    unsigned long kernel_image;   // off 32
    unsigned long kernel_heap;    // off 40
    unsigned int  hz;             // off 48
    unsigned int  proc_total;     // off 52
    unsigned int  proc_running;   // off 56
    unsigned int  reserved;       // off 60
    unsigned int  cpu_count;      // off 64
    unsigned int  cpu_capacity;   // off 68
    unsigned long cpu_ticks[SWIFTOS_CPU_MAX];      // off 72
    unsigned long cpu_idle_ticks[SWIFTOS_CPU_MAX]; // off 136
};

struct top_procstat {
    unsigned int  pid;            // off 0
    unsigned int  ppid;           // off 4
    unsigned int  state;          // off 8
    unsigned int  principal;      // off 12
    unsigned long cpu_ticks;      // off 16
    unsigned long start_tick;     // off 24
    unsigned long res_bytes;      // off 32
    char          name[16];       // off 40
};

static struct top_sysinfo g_sys;
static struct top_procstat g_top[SWIFTOS_TOP_MAX];
static int g_top_count;

int swiftos_sysinfo_refresh(void) {
    return (int)__syscall3(SYS_SYSINFO, (long)&g_sys, sizeof(g_sys), 0);
}
unsigned long swiftos_sys_uptime_ticks(void) { return g_sys.uptime_ticks; }
unsigned long swiftos_sys_idle_ticks(void)   { return g_sys.idle_ticks; }
unsigned long swiftos_sys_mem_total(void)    { return g_sys.mem_total; }
unsigned long swiftos_sys_mem_free(void)     { return g_sys.mem_free; }
unsigned long swiftos_sys_kernel_image(void) { return g_sys.kernel_image; }
unsigned long swiftos_sys_kernel_heap(void)  { return g_sys.kernel_heap; }
unsigned int  swiftos_sys_hz(void)           { return g_sys.hz; }
unsigned int  swiftos_sys_proc_total(void)   { return g_sys.proc_total; }
unsigned int  swiftos_sys_proc_running(void) { return g_sys.proc_running; }
unsigned int  swiftos_sys_cpu_count(void)    { return g_sys.cpu_count != 0 ? g_sys.cpu_count : 1; }
unsigned int  swiftos_sys_cpu_capacity(void) { return g_sys.cpu_capacity; }
unsigned long swiftos_sys_cpu_ticks(unsigned int cpu) {
    if (cpu < SWIFTOS_CPU_MAX && cpu < g_sys.cpu_count && cpu < g_sys.cpu_capacity) {
        return g_sys.cpu_ticks[cpu];
    }
    return cpu == 0 ? g_sys.uptime_ticks : 0;
}
unsigned long swiftos_sys_cpu_idle_ticks(unsigned int cpu) {
    if (cpu < SWIFTOS_CPU_MAX && cpu < g_sys.cpu_count && cpu < g_sys.cpu_capacity) {
        return g_sys.cpu_idle_ticks[cpu];
    }
    return cpu == 0 ? g_sys.idle_ticks : 0;
}

int swiftos_top_refresh(void) {
    g_top_count = (int)__syscall3(SYS_PROCSTAT, (long)g_top, SWIFTOS_TOP_MAX, 0);
    return g_top_count;
}

static int top_valid(int i) { return i >= 0 && i < g_top_count && i < SWIFTOS_TOP_MAX; }

unsigned int  swiftos_top_pid(int i)        { return top_valid(i) ? g_top[i].pid : 0; }
unsigned int  swiftos_top_ppid(int i)       { return top_valid(i) ? g_top[i].ppid : 0; }
unsigned int  swiftos_top_state(int i)      { return top_valid(i) ? g_top[i].state : 0; }
unsigned int  swiftos_top_principal(int i)  { return top_valid(i) ? g_top[i].principal : 0; }
unsigned long swiftos_top_cpu_ticks(int i)  { return top_valid(i) ? g_top[i].cpu_ticks : 0; }
unsigned long swiftos_top_start_tick(int i) { return top_valid(i) ? g_top[i].start_tick : 0; }
unsigned long swiftos_top_res_bytes(int i)  { return top_valid(i) ? g_top[i].res_bytes : 0; }
const char   *swiftos_top_name(int i)       { return top_valid(i) ? g_top[i].name : "?"; }

void *memset(void *dst, int value, size_t count) {
    unsigned char *p = (unsigned char *)dst;
    for (size_t i = 0; i < count; i += 1) {
        p[i] = (unsigned char)value;
    }
    return dst;
}

void *memcpy(void *dst, const void *src, size_t count) {
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    for (size_t i = 0; i < count; i += 1) {
        d[i] = s[i];
    }
    return dst;
}

void *memmove(void *dst, const void *src, size_t count) {
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    if (d == s || count == 0) {
        return dst;
    }
    if (d < s) {
        for (size_t i = 0; i < count; i += 1) {
            d[i] = s[i];
        }
    } else {
        for (size_t i = count; i > 0; i -= 1) {
            d[i - 1] = s[i - 1];
        }
    }
    return dst;
}

int memcmp(const void *a, const void *b, size_t count) {
    const unsigned char *pa = (const unsigned char *)a;
    const unsigned char *pb = (const unsigned char *)b;
    for (size_t i = 0; i < count; i += 1) {
        if (pa[i] != pb[i]) {
            return (int)pa[i] - (int)pb[i];
        }
    }
    return 0;
}

// ---- Heap allocator --------------------------------------------------------
//
// A real, free-capable allocator (classic K&R storage manager) over the kernel
// `sbrk` syscall. The previous bridge only bumped `sbrk` and never freed, so any
// program that churns heap objects (ARC class/Array/String/Dictionary traffic in
// a loop) grew the break monotonically until `sbrk` failed. This implementation
// recycles freed blocks and coalesces adjacent ones, so the break stays bounded
// under steady-state churn — the primitive the Swift runtime (and, later, Node /
// the JVM) needs. It is the deliberate "extend the minimal bridge" choice over
// pulling in newlib for a pure-Swift userland; see docs/NOTES.md.
//
// Blocks are managed in 16-byte units, so every returned payload is 16-aligned —
// exactly Embedded Swift's default heap alignment for classes/arrays/strings.

typedef union header Header;
union header {
    struct {
        Header *next;        // next free block
        unsigned long size;  // size of this block, in Header units (incl. header)
    } s;
    long _align[2];          // force sizeof(Header) == 16 and 16-byte alignment
};

static Header freebase;          // zero-sized list head sentinel
static Header *freep = 0;        // last-allocated free block (rover)

#define NALLOC 4096              // grow the heap in 64 KiB chunks (4096 * 16)

static void heap_free(void *ap); // forward

// Grow the arena by at least `nu` units via sbrk and add it to the free list.
static Header *morecore(unsigned long nu) {
    if (nu < NALLOC) {
        nu = NALLOC;
    }
    void *cp = sbrk((long)(nu * sizeof(Header)));
    if (cp == (void *)-1) {
        return 0;
    }
    Header *up = (Header *)cp;
    up->s.size = nu;
    heap_free((void *)(up + 1)); // splice the new region into the free list
    return freep;
}

void *malloc(unsigned long nbytes) {
    if (nbytes == 0) {
        nbytes = 1;
    }
    // Units needed: payload rounded up, plus one for the header.
    unsigned long nunits = (nbytes + sizeof(Header) - 1) / sizeof(Header) + 1;

    Header *prevp = freep;
    if (prevp == 0) { // first call: build a degenerate one-element list
        freebase.s.next = freep = prevp = &freebase;
        freebase.s.size = 0;
    }

    for (Header *p = prevp->s.next; ; prevp = p, p = p->s.next) {
        if (p->s.size >= nunits) {        // big enough
            if (p->s.size == nunits) {    // exact fit: unlink
                prevp->s.next = p->s.next;
            } else {                      // split: carve the tail
                p->s.size -= nunits;
                p += p->s.size;
                p->s.size = nunits;
            }
            freep = prevp;
            return (void *)(p + 1);
        }
        if (p == freep) {                 // wrapped the list: ask for more
            if ((p = morecore(nunits)) == 0) {
                return 0;                 // out of memory
            }
        }
    }
}

// Return a block to the free list, coalescing with adjacent free neighbours.
static void heap_free(void *ap) {
    Header *bp = (Header *)ap - 1; // block header
    Header *p;
    for (p = freep; !(bp > p && bp < p->s.next); p = p->s.next) {
        if (p >= p->s.next && (bp > p || bp < p->s.next)) {
            break; // freed block at the start or end of the arena
        }
    }
    if (bp + bp->s.size == p->s.next) { // join to upper neighbour
        bp->s.size += p->s.next->s.size;
        bp->s.next = p->s.next->s.next;
    } else {
        bp->s.next = p->s.next;
    }
    if (p + p->s.size == bp) {          // join to lower neighbour
        p->s.size += bp->s.size;
        p->s.next = bp->s.next;
    } else {
        p->s.next = bp;
    }
    freep = p;
}

void free(void *ptr) {
    if (ptr) {
        heap_free(ptr);
    }
}

void *calloc(size_t n, size_t size) {
    unsigned long total = (unsigned long)n * (unsigned long)size;
    void *p = malloc(total);
    if (p) {
        memset(p, 0, total);
    }
    return p;
}

void *realloc(void *ptr, size_t size) {
    if (ptr == 0) {
        return malloc(size);
    }
    if (size == 0) {
        free(ptr);
        return 0;
    }
    Header *bp = (Header *)ptr - 1;
    unsigned long oldbytes = (bp->s.size - 1) * sizeof(Header);
    if (oldbytes >= size) {
        return ptr; // current block already large enough
    }
    void *np = malloc(size);
    if (np) {
        memcpy(np, ptr, oldbytes);
        free(ptr);
    }
    return np;
}

// Swift runtime allocation hooks route through the allocator above. Payloads are
// 16-aligned; for the rare over-aligned request we over-allocate and stash the
// real base in the word before the returned pointer (recovered on dealloc, which
// is always given the same align mask).
void *swift_slowAlloc(unsigned long byte_count, unsigned long align_mask) {
    unsigned long alignment = align_mask == ~0UL ? 16 : align_mask + 1;
    if (alignment <= 16) {
        return malloc(byte_count);
    }
    void *raw = malloc(byte_count + alignment + sizeof(void *));
    if (!raw) {
        return 0;
    }
    unsigned long a = align_up((unsigned long)raw + sizeof(void *), alignment);
    ((void **)a)[-1] = raw;
    return (void *)a;
}

void swift_slowDealloc(void *ptr, unsigned long byte_count, unsigned long align_mask) {
    (void)byte_count;
    if (!ptr) {
        return;
    }
    unsigned long alignment = align_mask == ~0UL ? 16 : align_mask + 1;
    if (alignment <= 16) {
        free(ptr);
    } else {
        free(((void **)ptr)[-1]);
    }
}

int posix_memalign(void **memptr, size_t alignment, size_t size) {
    unsigned long mask = alignment == 0 ? 15 : (unsigned long)alignment - 1;
    void *ptr = swift_slowAlloc((unsigned long)size, mask);
    *memptr = ptr;
    return ptr ? 0 : 12; // ENOMEM
}

// Current program break — lets a tool report bounded heap growth (calc's `:mem`).
unsigned long swiftos_heap_break(void) {
    return (unsigned long)sbrk(0);
}

// ---- misc runtime shims ----------------------------------------------------

// Embedded Swift's print()/String output lowers to putchar.
int putchar(int c) {
    unsigned char b = (unsigned char)c;
    (void)write(1, &b, 1);
    return c;
}

// Dictionary/Set seed their hashers from arc4random_buf. Prefer runtime entropy
// when the kernel has a source, but keep the previous deterministic fallback so
// non-rng test profiles stay reproducible and bootable.
void arc4random_buf(void *buf, size_t n) {
    unsigned char *p = (unsigned char *)buf;
    size_t off = 0;
    while (off < n) {
        long r = swiftos_random(p + off, (unsigned long)(n - off));
        if (r <= 0) {
            break;
        }
        off += (size_t)r;
    }
    unsigned long x = 0x9E3779B97F4A7C15UL ^ (unsigned long)n ^ (unsigned long)off;
    for (size_t i = off; i < n; i += 1) {
        x = x * 6364136223846793005UL + 1442695040888963407UL;
        p[i] = (unsigned char)(x >> 56);
    }
}

void __stack_chk_fail(void) {
    for (;;) {
    }
}

int swift_stdlib_isStackAllocationSafe(unsigned long byte_count, unsigned long alignment) {
    (void)byte_count;
    (void)alignment;
    return 1;
}

// ---- UDP sockets (net-b) --------------------------------------------------
// sendto/recvfrom pass their extra arguments in this struct (the kernel reads
// the first 18 bytes for v4); the 3-arg syscall ABI carries only (fd, &msg).
// v4 form is 18 bytes effective.
struct swiftos_udp_msg {
    unsigned long buf;    // user VA of the payload buffer
    unsigned int len;     // send: length; recv in: capacity, out: received length
    unsigned int ip;      // host-order IPv4 (send: dst; recv out: src)
    unsigned short port;  // send: dst port; recv out: src port
    unsigned short pad;
};

// Extended v6 form (34 bytes, matches kernel udpMsgSizeV6 and LE offsets in vfsSendto/Recvfrom):
// buf@0(u64), len@8(u32), ip6[16]@12, port@28(u16), scope_id@30(u32).
struct __attribute__((packed)) swiftos_udp_msg_v6 {
    unsigned long buf;
    unsigned int len;
    unsigned char ip6[16];
    unsigned short port;
    unsigned int scope;
};

int swiftos_socket(void) {
    return (int)__syscall3(SYS_SOCKET, 2, 2, 0);   // AF_INET, SOCK_DGRAM
}

int swiftos_socket_ipv6(void) {
    return (int)__syscall3(SYS_SOCKET, 10, 2, 0);  // AF_INET6, SOCK_DGRAM
}

int swiftos_bind(int fd, unsigned short port) {
    return (int)__syscall3(SYS_BIND, fd, (long)port, 0);
}

long swiftos_sendto(int fd, const void *buf, unsigned long len,
                    unsigned int ip, unsigned short port) {
    struct swiftos_udp_msg m;
    m.buf = (unsigned long)buf;
    m.len = (unsigned int)len;
    m.ip = ip;
    m.port = port;
    m.pad = 0;
    return __syscall3(SYS_SENDTO, fd, (long)&m, 0);
}

long swiftos_recvfrom(int fd, void *buf, unsigned long cap,
                      unsigned int *ip, unsigned short *port) {
    struct swiftos_udp_msg m;
    m.buf = (unsigned long)buf;
    m.len = (unsigned int)cap;
    m.ip = 0;
    m.port = 0;
    m.pad = 0;
    long n = __syscall3(SYS_RECVFROM, fd, (long)&m, 0);
    if (n >= 0) {
        if (ip) *ip = m.ip;
        if (port) *port = m.port;
    }
    return n;
}

// IPv6 send/recv: caller supplies 16-byte network-order IPv6 (or receives it).
long swiftos_sendto_ipv6(int fd, const void *buf, unsigned long len,
                         const unsigned char *ip6, unsigned short port) {
    struct swiftos_udp_msg_v6 m;
    m.buf = (unsigned long)buf;
    m.len = (unsigned int)len;
    for (int i = 0; i < 16; i++) { m.ip6[i] = ip6 ? ip6[i] : 0; }
    m.port = port;
    m.scope = 0;
    return __syscall3(SYS_SENDTO, fd, (long)&m, 0);
}

long swiftos_recvfrom_ipv6(int fd, void *buf, unsigned long cap,
                           unsigned char *ip6, unsigned short *port) {
    struct swiftos_udp_msg_v6 m;
    m.buf = (unsigned long)buf;
    m.len = (unsigned int)cap;
    for (int i = 0; i < 16; i++) { m.ip6[i] = 0; }
    m.port = 0;
    m.scope = 0;
    long n = __syscall3(SYS_RECVFROM, fd, (long)&m, 0);
    if (n >= 0) {
        if (ip6) { for (int i = 0; i < 16; i++) { ip6[i] = m.ip6[i]; } }
        if (port) *port = m.port;
    }
    return n;
}

// ---- TCP sockets (net-c2) -------------------------------------------------
int swiftos_socket_stream(void) {
    return (int)__syscall3(SYS_SOCKET, 2, 1, 0);   // AF_INET, SOCK_STREAM
}

int swiftos_socket_stream_ipv6(void) {
    return (int)__syscall3(SYS_SOCKET, 10, 1, 0);  // AF_INET6, SOCK_STREAM
}

int swiftos_listen(int fd, int backlog) {
    return (int)__syscall3(SYS_LISTEN, fd, backlog, 0);
}

int swiftos_accept(int fd) {
    return (int)__syscall3(SYS_ACCEPT, fd, 0, 0);
}

int swiftos_connect(int fd, unsigned int ip, unsigned short port) {
    return (int)__syscall3(SYS_CONNECT, fd, (long)ip, (long)port);
}

long swiftos_poll(void *fds, unsigned long nfds, long timeout_ms) {
    return __syscall3(SYS_POLL, (long)fds, (long)nfds, timeout_ms);
}

unsigned int swiftos_resolve(const char *name, unsigned int server_ip, unsigned short server_port) {
    return (unsigned int)__syscall3(SYS_RESOLVE, (long)name, (long)server_ip, (long)server_port);
}

// ---- Threads + futex (rt-a) ------------------------------------------------
int swiftos_thread_create(unsigned long entry, unsigned long arg, unsigned long stack_top) {
    return (int)__syscall3(SYS_THREAD_CREATE, (long)entry, (long)arg, (long)stack_top);
}

int swiftos_futex(unsigned int *uaddr, int op, unsigned int val) {
    return (int)__syscall3(SYS_FUTEX, (long)uaddr, op, (long)val);
}

long swiftos_getpid(void) {
    return __syscall3(SYS_GETPID, 0, 0, 0);
}

void swiftos_thread_exit(void) {
    __syscall3(SYS_EXIT, 0, 0, 0);
    for (;;) {
    }
}

// ---- Anonymous mmap / munmap / mprotect (Track B) -------------------------
// Thin wrappers over the mmap/munmap/mprotect inlines in syscall.h. swiftos_mmap
// returns the base address, or 0 on failure. PROT_NONE reserves VA without
// resident frames; mprotect commits/decommits pages later. Swift has no errno,
// so a 0 sentinel is simplest, and a valid mapping is never at VA 0.
unsigned long swiftos_mmap(unsigned long len, int prot) {
    void *p = mmap(0, len, prot, MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
    return (p == MAP_FAILED) ? 0 : (unsigned long)p;
}

// File-backed read-only mmap (I2a): SYS_MMAP_FILE(fd, len, prot) returns a base
// VA or a small negative errno; 0 sentinel on failure (Swift has no errno).
unsigned long swiftos_mmap_file(int fd, unsigned long len, int prot) {
    long r = __syscall3(SYS_MMAP_FILE, (long)fd, (long)len, (long)prot);
    if (r < 0 && r >= -4095) return 0;
    return (unsigned long)r;
}

int swiftos_munmap(unsigned long addr, unsigned long len) {
    return munmap((void *)addr, len);
}

int swiftos_mprotect(unsigned long addr, unsigned long len, int prot) {
    return mprotect((void *)addr, len, prot);
}

// Atomic CAS via the AArch64 LL/SC loop. Returns the prior value of *p; the
// store happened iff that equals `expected`. __ATOMIC_SEQ_CST gives the barriers
// the futex protocol relies on (the lock word orders the protected counter).
unsigned int swiftos_atomic_cas(unsigned int *p, unsigned int expected, unsigned int desired) {
    __atomic_compare_exchange_n(p, &expected, desired, 0,
                                __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    return expected; // updated to the actual prior value on failure
}

unsigned int swiftos_atomic_swap(unsigned int *p, unsigned int desired) {
    return __atomic_exchange_n(p, desired, __ATOMIC_SEQ_CST);
}

unsigned int swiftos_atomic_load(unsigned int *p) {
    return __atomic_load_n(p, __ATOMIC_SEQ_CST);
}

void swiftos_atomic_store(unsigned int *p, unsigned int v) {
    __atomic_store_n(p, v, __ATOMIC_SEQ_CST);
}

unsigned int swiftos_atomic_add(unsigned int *p, unsigned int delta) {
    return __atomic_fetch_add(p, delta, __ATOMIC_SEQ_CST);
}

// LA3 shared-memory ring bridges (thin forwards to the C-only syscall wrappers).
long swiftos_shmring_create(unsigned long pages) { return shmring_create(pages); }
long swiftos_shmring_map(int id) { return shmring_map(id); }
int  swiftos_shmring_close(int id) { return shmring_close(id); }
