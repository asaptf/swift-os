// hello.c — the M6 acceptance program: a static C binary that prints via our
// libc/syscalls and exits. Cross-built against the swift-os sysroot, loaded by
// the kernel's ELF64 loader, and run at EL0 in its own address space.

#include "lib/syscall.h"

int puts_raw(const char *s);

int main(void) {
    puts_raw("hello from ELF userland\n");
    return 7; // distinctive exit code the kernel prints back
}
