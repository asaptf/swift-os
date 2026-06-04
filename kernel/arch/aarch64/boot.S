// boot.S — aarch64 boot stub for QEMU `virt`.
//
// QEMU loads us via `-kernel` and enters here at EL1 with the MMU off and
// caches in an undefined state. We do the absolute minimum needed to run
// Swift: park secondary cores, set up a stack, zero BSS, then hand off to
// the Swift entry point `kernel_main`.

.section ".text.boot", "ax"
.global _start

_start:
    // Firmware/bootloaders may hand us a pointer to the flattened device tree
    // in x0. Preserve it in a callee-saved register before we clobber x0; the
    // direct QEMU ELF path may leave it zero, in which case platformInit uses
    // its direct-boot fallback.
    mov     x19, x0

    // Single-core bring-up: park every CPU whose affinity != 0.
    mrs     x0, mpidr_el1
    and     x0, x0, #0xFF
    cbnz    x0, .Lhang

    // Install the initial stack pointer (top-of-stack, 16-byte aligned).
    ldr     x0, =__stack_top
    mov     sp, x0

    // QEMU may enter with strict alignment checks enabled. Swift codegen can
    // use unaligned vector accesses for value copies, so leave alignment and
    // SP-alignment checks off until we define our own trap policy.
    mrs     x0, sctlr_el1
    bic     x0, x0, #(1 << 1)
    bic     x0, x0, #(1 << 3)
    bic     x0, x0, #(1 << 4)
    msr     sctlr_el1, x0
    isb

    // Allow FP/SIMD instructions at EL1. Swift codegen may use vector loads
    // for ordinary value manipulation even before we have a scheduler.
    mrs     x0, cpacr_el1
    mov     x1, #(3 << 20)
    orr     x0, x0, x1
    msr     cpacr_el1, x0
    isb

    // Install a minimal EL1 vector table before entering Swift.
    ldr     x0, =el1_vector_table
    msr     vbar_el1, x0
    isb

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
    // fall through into the parking loop. x0 = saved device-tree pointer.
    mov     x0, x19
    bl      kernel_main

.Lhang:
    wfe
    b       .Lhang
