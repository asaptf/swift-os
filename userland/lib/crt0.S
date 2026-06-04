// crt0.S — C runtime startup for swift-os userland (EL0).
//
// The kernel enters us at `_start` with SP_EL0 already set to the top of a
// mapped user stack. We have no argc/argv yet (added when busybox needs them),
// so we just call main() and feed its return value to the exit syscall.

#include "syscall.h"

.section ".text._start", "ax"
.global _start
_start:
    // The kernel hands us a SysV-style stack: [sp] = argc, sp+8 = argv[].
    ldr     x0, [sp]              // argc
    add     x1, sp, #8            // argv
    add     x2, x1, x0, lsl #3    // envp = argv + (argc+1)*8
    add     x2, x2, #8
    bl      main                  // x0 = main(argc, argv, envp)
    mov     x8, #SYS_EXIT         // exit(x0); x8 = syscall number
    svc     #0
.Lspin:                           // exit never returns
    wfe
    b       .Lspin
