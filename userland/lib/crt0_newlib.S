// crt0_newlib.S — C runtime startup for newlib-linked swift-os programs.
//
// Same SysV entry contract as our minimal crt0 (kernel sets SP to argc/argv),
// but ends by calling newlib's exit() so stdio buffers are flushed and atexit
// handlers run. BSS is zeroed by the kernel ELF loader (fresh pages are zeroed
// and memsz>filesz is zero-filled), so we don't clear it here.
//
// We also run the C++ static constructors ourselves. The kernel ELF loader does
// not run .init_array, and we link -nostartfiles (so newlib's crti.o _init /
// __libc_init_array are absent). C programs have an empty/near-empty array, but
// C++ programs — notably Node.js/V8, with ~150 global constructors — depend on
// these running before main, or their global objects stay zeroed (null derefs).
// We iterate the linker-provided .preinit_array and .init_array directly,
// avoiding the crti _init() dependency.

.section ".text._start", "ax"
.extern environ
.extern __preinit_array_start
.extern __preinit_array_end
.extern __init_array_start
.extern __init_array_end
.extern __swos_init_tls
.extern __swos_bind_main_reent
.global _start
_start:
    // Set up native thread-local storage (tpidr_el0) for the main thread before
    // anything — C++ constructors and V8 access __thread/thread_local vars.
    bl      __swos_init_tls
    bl      __swos_bind_main_reent

    // envp -> environ first, so any getenv() in a constructor sees it.
    ldr     x0, [sp]              // argc
    add     x1, sp, #8            // argv
    add     x2, x1, x0, lsl #3    // envp = argv + (argc+1)*8
    add     x2, x2, #8
    adrp    x3, environ
    add     x3, x3, :lo12:environ
    str     x2, [x3]

    // Run .preinit_array[] then .init_array[]. x19/x20 are callee-saved, so the
    // constructors preserve them across the blr; the array bounds come from the
    // linker script's PROVIDE() symbols.
    adrp    x19, __preinit_array_start
    add     x19, x19, :lo12:__preinit_array_start
    adrp    x20, __preinit_array_end
    add     x20, x20, :lo12:__preinit_array_end
1:  cmp     x19, x20
    b.hs    2f
    ldr     x3, [x19], #8
    blr     x3
    b       1b
2:
    adrp    x19, __init_array_start
    add     x19, x19, :lo12:__init_array_start
    adrp    x20, __init_array_end
    add     x20, x20, :lo12:__init_array_end
3:  cmp     x19, x20
    b.hs    4f
    ldr     x3, [x19], #8
    blr     x3
    b       3b
4:
    // argc/argv for main (recompute from SP; constructors restored it).
    ldr     x0, [sp]              // argc
    add     x1, sp, #8            // argv
    bl      main
    bl      exit                  // newlib exit(): flush stdio, then _exit()
.Lspin:
    wfe
    b       .Lspin
