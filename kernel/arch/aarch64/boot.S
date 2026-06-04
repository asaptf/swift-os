// boot.S — aarch64 boot stub for QEMU `virt`.
//
// QEMU loads us via `-kernel` and enters here at EL1 with the MMU off and
// caches in an undefined state. We do the absolute minimum needed to run
// Swift: park secondary cores, set up a stack, zero BSS, then hand off to
// the Swift entry point `kernel_main`.

.section ".text.boot", "ax"
.global _start

_start:
    // Single-core bring-up: park every CPU whose affinity != 0.
    mrs     x0, mpidr_el1
    and     x0, x0, #0xFF
    cbnz    x0, .Lhang

    // Install the initial stack pointer (top-of-stack, 16-byte aligned).
    ldr     x0, =__stack_top
    mov     sp, x0

    // Zero the BSS: [__bss_start, __bss_end), 8 bytes at a time.
    ldr     x0, =__bss_start
    ldr     x1, =__bss_end
.Lbss_loop:
    cmp     x0, x1
    b.hs    .Lbss_done
    str     xzr, [x0], #8
    b       .Lbss_loop
.Lbss_done:

    // Enter Swift. kernel_main is `@_cdecl` and must not return; if it does,
    // fall through into the parking loop.
    bl      kernel_main

.Lhang:
    wfe
    b       .Lhang
