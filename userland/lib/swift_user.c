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

int swiftos_context(unsigned int *principal, unsigned int *session, unsigned long *caps) {
    struct security_info si;
    int rc = security_info(&si);
    if (rc != 0) return rc;
    if (principal) *principal = si.principal;
    if (session) *session = si.session;
    if (caps) *caps = si.caps;
    return 0;
}

int swiftos_exec_shell(const char *path) {
    char arg0[] = "sh";
    char *argv[] = { arg0, 0 };
    return execve(path, argv, 0);
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

// Dictionary/Set seed their hashers from arc4random_buf. We have no entropy
// source and want reproducible behaviour, so fill deterministically — fine for a
// single-user REPL (the seed only randomises hash-table iteration order).
void arc4random_buf(void *buf, size_t n) {
    unsigned char *p = (unsigned char *)buf;
    unsigned long x = 0x9E3779B97F4A7C15UL; // splitmix64-ish constant
    for (size_t i = 0; i < n; i += 1) {
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
// the first 18 bytes); the 3-arg syscall ABI carries only (fd, &msg).
struct swiftos_udp_msg {
    unsigned long buf;    // user VA of the payload buffer
    unsigned int len;     // send: length; recv in: capacity, out: received length
    unsigned int ip;      // host-order IPv4 (send: dst; recv out: src)
    unsigned short port;  // send: dst port; recv out: src port
    unsigned short pad;
};

int swiftos_socket(void) {
    return (int)__syscall3(SYS_SOCKET, 2, 2, 0);   // AF_INET, SOCK_DGRAM
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

// ---- TCP sockets (net-c2) -------------------------------------------------
int swiftos_socket_stream(void) {
    return (int)__syscall3(SYS_SOCKET, 2, 1, 0);   // AF_INET, SOCK_STREAM
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
