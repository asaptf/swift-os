// argvdemo.c — M8a(2) argv demo: print argc/argv received from the kernel.
//
// Proves the SysV entry stack (argc/argv) the kernel builds is read correctly
// by crt0 and passed to main. Exits with argc as the status.

#include "lib/syscall.h"

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
    // parent holds fd 3 open. spawn-with-handles must not inherit it, so probing
    // fd 3 must fail (EBADF). A direct launch passes other args and skips this.
    if (argc >= 2 && streq(argv[1], "isocheck")) {
        char b;
        long r = read(3, &b, 1);
        puts_raw(r < 0 ? "SPAWN-ISO-OK\n" : "SPAWN-ISO-LEAK\n");
    }
    return argc;
}
