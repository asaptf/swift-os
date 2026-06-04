// argvdemo.c — M8a(2) argv demo: print argc/argv received from the kernel.
//
// Proves the SysV entry stack (argc/argv) the kernel builds is read correctly
// by crt0 and passed to main. Exits with argc as the status.

#include "lib/syscall.h"

int puts_raw(const char *s);

int main(int argc, char **argv) {
    for (int i = 0; i < argc; i += 1) {
        char idx = (char)('0' + i);
        puts_raw("argv[");
        write(1, &idx, 1);
        puts_raw("]=");
        puts_raw(argv[i]);
        puts_raw("\n");
    }
    return argc;
}
