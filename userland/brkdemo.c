// brkdemo.c — M8c(1) heap demo: exercise the sbrk syscall.
//
// Validates that the kernel grows the process heap on demand (mapping pages
// from the PMM), including across a page boundary. This is the foundation
// newlib's malloc/_sbrk will sit on.

#include "lib/syscall.h"

int puts_raw(const char *s);

int main(void) {
    unsigned char *p = (unsigned char *)sbrk(100);
    if ((long)p < 0) {
        puts_raw("M8c brk: sbrk failed\n");
        return 1;
    }

    for (int i = 0; i < 100; i += 1) {
        p[i] = (unsigned char)i;
    }
    int ok = 1;
    for (int i = 0; i < 100; i += 1) {
        if (p[i] != (unsigned char)i) { ok = 0; }
    }

    // Grow well past a page boundary and touch every byte.
    unsigned char *q = (unsigned char *)sbrk(8192);
    if ((long)q < 0) {
        puts_raw("M8c brk: second sbrk failed\n");
        return 1;
    }
    for (int i = 0; i < 8192; i += 1) {
        q[i] = 0x5A;
    }
    if (q[0] != 0x5A || q[8191] != 0x5A) { ok = 0; }

    puts_raw(ok ? "M8c brk: heap read/write OK\n" : "M8c brk: FAIL\n");
    return ok ? 0 : 1;
}
