// exceptions.S — EL1 exception vector table + entry trampolines.
//
// Each lower-EL entry saves a FULL trap frame — x0..x30, the EL0 return state
// SP_EL0/ELR_EL1/SPSR_EL1, and the EL0 FP/SIMD state q0..q31 + FPCR/FPSR — and
// restores it before `eret`. Saving the return state is what makes exceptions
// nestable; saving FP/SIMD is what makes preempted Float-heavy EL0 code (for
// example /bin/llmd) deterministic while other EL0 services run.
//
// Trap frame layout (816 bytes, 16-aligned), offsets:
//   0..240  x0..x30 (x0 at 0, x8 at 64, x30 at 240)
//   248     SP_EL0
//   256     ELR_EL1
//   264     SPSR_EL1
//   288..799 q0..q31 (16 bytes each)
//   800     FPCR
//   808     FPSR

.set FRAME_SIZE, 816

.macro save_frame
    sub     sp, sp, #FRAME_SIZE
    stp     x0,  x1,  [sp, #0]
    stp     x2,  x3,  [sp, #16]
    stp     x4,  x5,  [sp, #32]
    stp     x6,  x7,  [sp, #48]
    stp     x8,  x9,  [sp, #64]
    stp     x10, x11, [sp, #80]
    stp     x12, x13, [sp, #96]
    stp     x14, x15, [sp, #112]
    stp     x16, x17, [sp, #128]
    stp     x18, x19, [sp, #144]
    stp     x20, x21, [sp, #160]
    stp     x22, x23, [sp, #176]
    stp     x24, x25, [sp, #192]
    stp     x26, x27, [sp, #208]
    stp     x28, x29, [sp, #224]
    str     x30,      [sp, #240]
    mrs     x9, sp_el0
    str     x9,       [sp, #248]
    mrs     x9, elr_el1
    str     x9,       [sp, #256]
    mrs     x9, spsr_el1
    str     x9,       [sp, #264]
    stp     q0,  q1,  [sp, #288]
    stp     q2,  q3,  [sp, #320]
    stp     q4,  q5,  [sp, #352]
    stp     q6,  q7,  [sp, #384]
    stp     q8,  q9,  [sp, #416]
    stp     q10, q11, [sp, #448]
    stp     q12, q13, [sp, #480]
    stp     q14, q15, [sp, #512]
    stp     q16, q17, [sp, #544]
    stp     q18, q19, [sp, #576]
    stp     q20, q21, [sp, #608]
    stp     q22, q23, [sp, #640]
    stp     q24, q25, [sp, #672]
    stp     q26, q27, [sp, #704]
    stp     q28, q29, [sp, #736]
    stp     q30, q31, [sp, #768]
    mrs     x9, fpcr
    str     x9,       [sp, #800]
    mrs     x9, fpsr
    str     x9,       [sp, #808]
.endm

.macro restore_frame
    ldp     q0,  q1,  [sp, #288]
    ldp     q2,  q3,  [sp, #320]
    ldp     q4,  q5,  [sp, #352]
    ldp     q6,  q7,  [sp, #384]
    ldp     q8,  q9,  [sp, #416]
    ldp     q10, q11, [sp, #448]
    ldp     q12, q13, [sp, #480]
    ldp     q14, q15, [sp, #512]
    ldp     q16, q17, [sp, #544]
    ldp     q18, q19, [sp, #576]
    ldp     q20, q21, [sp, #608]
    ldp     q22, q23, [sp, #640]
    ldp     q24, q25, [sp, #672]
    ldp     q26, q27, [sp, #704]
    ldp     q28, q29, [sp, #736]
    ldp     q30, q31, [sp, #768]
    ldr     x9,       [sp, #800]
    msr     fpcr, x9
    ldr     x9,       [sp, #808]
    msr     fpsr, x9
    ldr     x9,       [sp, #248]
    msr     sp_el0, x9
    ldr     x9,       [sp, #256]
    msr     elr_el1, x9
    ldr     x9,       [sp, #264]
    msr     spsr_el1, x9
    ldp     x0,  x1,  [sp, #0]
    ldp     x2,  x3,  [sp, #16]
    ldp     x4,  x5,  [sp, #32]
    ldp     x6,  x7,  [sp, #48]
    ldp     x8,  x9,  [sp, #64]
    ldp     x10, x11, [sp, #80]
    ldp     x12, x13, [sp, #96]
    ldp     x14, x15, [sp, #112]
    ldp     x16, x17, [sp, #128]
    ldp     x18, x19, [sp, #144]
    ldp     x20, x21, [sp, #160]
    ldp     x22, x23, [sp, #176]
    ldp     x24, x25, [sp, #192]
    ldp     x26, x27, [sp, #208]
    ldp     x28, x29, [sp, #224]
    ldr     x30,      [sp, #240]
    add     sp, sp, #FRAME_SIZE
    eret
.endm

.section ".text.exceptions", "ax"
.align 11
.global el1_vector_table

.macro ventry handler
    b       \handler
    .space 128 - 4
.endm

el1_vector_table:
    // Current EL, SP0.
    ventry exception_entry
    ventry irq_entry
    ventry exception_entry
    ventry exception_entry

    // Current EL, SPx.
    ventry exception_entry
    ventry irq_entry
    ventry exception_entry
    ventry exception_entry

    // Lower EL, AArch64.
    ventry sync_lower_el_aarch64_entry
    ventry irq_entry
    ventry exception_entry
    ventry exception_entry

    // Lower EL, AArch32.
    ventry exception_entry
    ventry irq_entry
    ventry exception_entry
    ventry exception_entry

// Current-EL faults are kernel bugs: report and halt (handler reads sysregs).
.global exception_entry
exception_entry:
    bl      exception_handler
1:
    wfe
    b       1b

// Synchronous exception from EL0 (syscalls + EL0 faults).
.global sync_lower_el_aarch64_entry
sync_lower_el_aarch64_entry:
    save_frame
    mov     x0, sp
    bl      sync_lower_el_aarch64_handler
    b       trap_return

// IRQ (from EL0 or EL1).
.global irq_entry
irq_entry:
    save_frame
    bl      irq_handler
    b       trap_return

// Shared trap return: restore the frame at SP and eret. fork() crafts a child
// kernel context whose first scheduling lands here with SP pointing at a copy
// of the parent's frame (x0=0), so the child "returns from the syscall" into EL0.
.global trap_return
trap_return:
    restore_frame

// uintptr_t trap_return_addr(void)
.global trap_return_addr
trap_return_addr:
    adrp    x0, trap_return
    add     x0, x0, :lo12:trap_return
    ret
