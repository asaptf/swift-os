// crt0.S — C runtime startup for swift-os userland (EL0).
//
// The kernel enters us at `_start` with SP_EL0 already set to the top of a
// mapped user stack. We have no argc/argv yet (added when busybox needs them),
// so we just call main() and feed its return value to the exit syscall.

#include "syscall.h"

.section ".text._start", "ax"
.global _start
_start:
    bl      main             // x0 = main()'s return value
    mov     x8, #SYS_EXIT    // exit(x0); x8 = syscall number
    svc     #0
.Lspin:                       // exit never returns
    wfe
    b       .Lspin
