// boot.S — aarch64 boot stub for QEMU `virt`.
//
// QEMU loads us via `-kernel` and enters here at EL1 with the MMU off and
// caches in an undefined state. We do the absolute minimum needed to run
// Swift: park secondary cores, set up a stack, zero BSS, then hand off to
// the Swift entry point `kernel_main`. S1 also exposes `smp_secondary_entry`,
// the PSCI/mailbox target used after CPU0 has built the kernel translation
// regime and provisioned per-CPU stacks.

.section ".text.boot", "ax"
.global _start
.global smp_secondary_entry

_start:
    // Firmware/bootloaders may hand us a pointer to the flattened device tree
    // in x0. Preserve it in a callee-saved register before we clobber x0; the
    // direct QEMU ELF path may leave it zero, in which case platformInit uses
    // its direct-boot fallback. x1-x3 carry the loader's framebuffer handoff
    // (base / width:height / stride:format), zero on the QEMU -kernel path.
    mov     x19, x0
    mov     x20, x1
    mov     x21, x2
    mov     x22, x3

    // Single-core bring-up: park every CPU whose affinity != 0.
    mrs     x0, mpidr_el1
    and     x0, x0, #0xFF
    cbnz    x0, .Lsecondary_park

    // Install the initial stack pointer (top-of-stack, 16-byte aligned).
    ldr     x0, =__stack_top
    mov     sp, x0

    // Normalize CPU state for the early MMU-off bring-up path. We may be entered
    // with the MMU and caches ON (a UEFI loader hands off that way) or OFF (QEMU
    // `-kernel`). Force MMU/caches off and clear alignment checks so both paths
    // converge: Swift codegen can emit unaligned vector accesses for value
    // copies, so alignment/SP-alignment checks stay off until we set a policy.
    mrs     x0, sctlr_el1
    bic     x0, x0, #(1 << 0)   // M:  MMU off
    bic     x0, x0, #(1 << 1)   // A:  alignment check off
    bic     x0, x0, #(1 << 2)   // C:  data cache off
    bic     x0, x0, #(1 << 3)   // SA: SP alignment check off
    bic     x0, x0, #(1 << 4)   // SA0
    bic     x0, x0, #(1 << 12)  // I:  instruction cache off
    msr     sctlr_el1, x0
    isb
    // Drop any TLB/I-cache state inherited from the firmware's translation
    // regime before we run with translation disabled.
    tlbi    vmalle1
    ic      iallu
    dsb     sy
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
    // fall through into the parking loop. x0 = dtb, x1-x3 = framebuffer handoff.
    mov     x0, x19
    mov     x1, x20
    mov     x2, x21
    mov     x3, x22
    bl      kernel_main

.Lhang:
    wfe
    b       .Lhang

.Lsecondary_park:
    // S1: secondary CPUs that start eagerly before CPU0 is ready stay below
    // Swift/allocator/scheduler code. The mailbox lives in .data (not .bss),
    // so it is safe to poll before CPU0 clears .bss. CPU0 later publishes a
    // stack and entry point, release-stores the flag, and sends SEV.
    cmp     x0, #8
    b.hs    .Lhang
    ldr     x1, =smp_secondary_mailboxes
    lsl     x5, x0, #6
    add     x1, x1, x5
    sevl
.Lsecondary_wait:
    ldar    x3, [x1]
    cbnz    x3, .Lsecondary_release_seen
    wfe
    b       .Lsecondary_wait
.Lsecondary_release_seen:
    ldr     x4, [x1, #8]   // entry
    cbz     x4, .Lsecondary_wait
    ldr     x6, [x1, #16]  // stack_top
    cbz     x6, .Lsecondary_wait
    ldr     x0, [x1, #24]  // argument/context id
    mov     sp, x6
    br      x4

smp_secondary_entry:
    // PSCI CPU_ON lands here with MMU/caches off. The eager-start mailbox path
    // also branches here after loading a stack. In both cases derive the actual
    // CPU id from MPIDR and use the mailbox stack CPU0 published for that slot.
    mrs     x9, mpidr_el1
    and     x9, x9, #0xFF
    cmp     x9, #8
    b.hs    .Lhang
    ldr     x10, =smp_secondary_mailboxes
    lsl     x11, x9, #6
    add     x10, x10, x11
    ldr     x12, [x10, #16]
    cbz     x12, .Lhang
    mov     sp, x12

    // Match the primary CPU's EL1 execution policy before entering Swift.
    mrs     x0, sctlr_el1
    bic     x0, x0, #(1 << 0)   // M:  MMU off while programming registers
    bic     x0, x0, #(1 << 1)   // A:  alignment check off
    bic     x0, x0, #(1 << 2)   // C:  data cache off
    bic     x0, x0, #(1 << 3)   // SA: SP alignment check off
    bic     x0, x0, #(1 << 4)   // SA0
    bic     x0, x0, #(1 << 12)  // I:  instruction cache off
    msr     sctlr_el1, x0
    isb
    tlbi    vmalle1
    ic      iallu
    dsb     sy
    isb

    mrs     x0, cpacr_el1
    mov     x1, #(3 << 20)
    orr     x0, x0, x1
    msr     cpacr_el1, x0
    isb

    ldr     x0, =el1_vector_table
    msr     vbar_el1, x0
    isb

    bl      mmu_configure_translation
    bl      mmu_enable_sctlr

    mov     x0, x9
    bl      smp_secondary_main
    b       .Lhang
