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

int swiftos_open(const char *path, int flags) {
    return open(path, flags);
}

long swiftos_read(int fd, void *buf, unsigned long count) {
    return read(fd, buf, count);
}

int swiftos_close(int fd) {
    return close(fd);
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

void *swift_slowAlloc(unsigned long byte_count, unsigned long align_mask) {
    unsigned long alignment = align_mask == ~0UL ? 16 : align_mask + 1;
    void *cur = sbrk(0);
    unsigned long start = align_up((unsigned long)cur, alignment);
    unsigned long end = start + byte_count;
    if ((long)sbrk((long)(end - (unsigned long)cur)) == -1) {
        for (;;) {
        }
    }
    return (void *)start;
}

void swift_slowDealloc(void *ptr, unsigned long byte_count, unsigned long align_mask) {
    (void)ptr;
    (void)byte_count;
    (void)align_mask;
}

int posix_memalign(void **memptr, size_t alignment, size_t size) {
    unsigned long mask = alignment == 0 ? 15 : (unsigned long)alignment - 1;
    void *ptr = swift_slowAlloc((unsigned long)size, mask);
    *memptr = ptr;
    return 0;
}

void free(void *ptr) {
    (void)ptr;
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
