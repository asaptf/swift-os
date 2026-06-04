// libc.c — the minimal libc subset swift-os userland needs today.
//
// Hand-written rather than a full newlib port (see docs/NOTES.md): just enough
// string/stdio on top of the syscall wrappers in syscall.h to build and run a
// static C program. Grows toward busybox's needs over later milestones.

#include "syscall.h"

size_t strlen(const char *s) {
    size_t n = 0;
    while (s[n] != '\0') {
        n += 1;
    }
    return n;
}

// Write a NUL-terminated string to stdout. Returns bytes written.
int puts_raw(const char *s) {
    return (int)write(1, s, strlen(s));
}
