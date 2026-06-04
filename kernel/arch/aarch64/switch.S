// switch.S — kernel thread context switch primitive.
//
// cpu_switch_context saves the AAPCS64 callee-saved state (x19..x28, fp, lr,
// sp) of the current thread into *prev and loads it from *next, then returns
// into the next thread. Caller-saved registers are, by definition, dead across
// the call, so they need not be saved. This is the classic cooperative-switch
// core (cf. xv6 `swtch`); preemption is layered on top by calling it from the
// timer IRQ handler.
//
// CPUContext layout (matches kernel/sched/scheduler.swift), 13 x u64:
//   0:x19 8:x20 16:x21 24:x22 32:x23 40:x24 48:x25 56:x26
//   64:x27 72:x28 80:fp(x29) 88:lr(x30) 96:sp

.section ".text", "ax"

.global cpu_switch_context
// void cpu_switch_context(void *prev, void *next)
cpu_switch_context:
    stp     x19, x20, [x0, #0]
    stp     x21, x22, [x0, #16]
    stp     x23, x24, [x0, #32]
    stp     x25, x26, [x0, #48]
    stp     x27, x28, [x0, #64]
    stp     x29, x30, [x0, #80]
    mov     x9, sp
    str     x9, [x0, #96]

    ldp     x19, x20, [x1, #0]
    ldp     x21, x22, [x1, #16]
    ldp     x23, x24, [x1, #32]
    ldp     x25, x26, [x1, #48]
    ldp     x27, x28, [x1, #64]
    ldp     x29, x30, [x1, #80]
    ldr     x9, [x1, #96]
    mov     sp, x9
    ret

// First-run entry for a freshly created thread. The crafted context arranges
// for `ret` in cpu_switch_context to land here with:
//   x19 = entry function (C ABI, takes a single uintptr_t argument)
//   x20 = argument
.global thread_trampoline
thread_trampoline:
    msr     daifclr, #2        // unmask IRQ for this thread
    mov     x0, x20
    blr     x19
    bl      thread_exit        // entry returned: terminate (never returns)
.Lhalt:
    wfe
    b       .Lhalt

// uintptr_t thread_trampoline_addr(void)
.global thread_trampoline_addr
thread_trampoline_addr:
    adrp    x0, thread_trampoline
    add     x0, x0, :lo12:thread_trampoline
    ret
