// crt0_newlib.S — C runtime startup for newlib-linked swift-os programs.
//
// Same SysV entry contract as our minimal crt0 (kernel sets SP to argc/argv),
// but ends by calling newlib's exit() so stdio buffers are flushed and atexit
// handlers run. BSS is zeroed by the kernel ELF loader (fresh pages are zeroed
// and memsz>filesz is zero-filled), so we don't clear it here.

.section ".text._start", "ax"
.extern environ
.global _start
_start:
    ldr     x0, [sp]              // argc
    add     x1, sp, #8            // argv
    add     x2, x1, x0, lsl #3    // envp = argv + (argc+1)*8
    add     x2, x2, #8
    adrp    x3, environ
    add     x3, x3, :lo12:environ
    str     x2, [x3]
    bl      main
    bl      exit                  // newlib exit(): flush stdio, then _exit()
.Lspin:
    wfe
    b       .Lspin
