// argvdemo.c — M8a(2) argv demo: print argc/argv received from the kernel.
//
// Proves the SysV entry stack (argc/argv) the kernel builds is read correctly
// by crt0 and passed to main. Exits with argc as the status.

#include "lib/syscall.h"
#include "lib/fs.h"

int puts_raw(const char *s);

static int streq(const char *a, const char *b) {
    while (*a && *a == *b) { a += 1; b += 1; }
    return *a == *b;
}

int main(int argc, char **argv) {
    for (int i = 0; i < argc; i += 1) {
        char idx = (char)('0' + i);
        puts_raw("argv[");
        write(1, &idx, 1);
        puts_raw("]=");
        puts_raw(argv[i]);
        puts_raw("\n");
    }
    // C2 spawn-isolation check: when spawned by spawndemo (arg "isocheck"), the
    // parent holds fd 3 open. legacy spawn() must not inherit it, so probing fd 3
    // must fail (EBADF). A direct launch passes other args and skips this.
    if (argc >= 2 && streq(argv[1], "isocheck")) {
        char b;
        long r = read(3, &b, 1);
        if (r < 0) {
            puts_raw("SPAWN-ISO-OK\n");
        } else {
            puts_raw("SPAWN-ISO-LEAK\n");
            return 1;
        }
    }
    if (argc >= 2 && streq(argv[1], "inheritcheck")) {
        char b;
        long r = read(3, &b, 1);
        if (r == 1) {
            puts_raw("SPAWN-EXPLICIT-OK\n");
        } else {
            puts_raw("SPAWN-EXPLICIT-FAIL\n");
            return 1;
        }
        struct stat st;
        if (fstat(3, &st) == 0) {
            puts_raw("C3-FSTAT-ALLOW-OK\n");
        } else {
            puts_raw("C3-FSTAT-ALLOW-FAIL\n");
            return 1;
        }
        if (write(3, "x", 1) < 0) {
            puts_raw("C3-WRITE-DENY-OK\n");
        } else {
            puts_raw("C3-WRITE-DENY-LEAK\n");
            return 1;
        }
        int d = dup(3);
        if (d < 0) {
            puts_raw("C3-DUP-DENY-OK\n");
        } else {
            puts_raw("C3-DUP-DENY-LEAK\n");
            close(d);
            return 1;
        }
        char dbuf[96];
        if (getdents(4, dbuf, sizeof(dbuf)) < 0) {
            puts_raw("C3-GETDENTS-DENY-OK\n");
        } else {
            puts_raw("C3-GETDENTS-DENY-LEAK\n");
            return 1;
        }
        if (fstat(5, &st) < 0) {
            puts_raw("C3-FSTAT-DENY-OK\n");
        } else {
            puts_raw("C3-FSTAT-DENY-LEAK\n");
            return 1;
        }
    }
    return argc;
}
