// user_entry.S — first-run trampoline that drops a thread into EL0.
//
// Reached via cpu_switch_context (switch.S) with a crafted context:
//   x19 = entry virtual address
//   x20 = user stack top (SP_EL0)
//   x21 = TTBR0 of the process address space
// Runs at EL1 on the process's kernel stack, installs the address space and EL0
// state, then `eret`s into the program. On a syscall/IRQ from EL0 the CPU traps
// back to EL1 on this same kernel stack (SP_EL1 is unchanged across the eret).

.section ".text", "ax"

.global user_thread_launch
user_thread_launch:
    msr     ttbr0_el1, x21
    dsb     sy
    isb
    tlbi    vmalle1
    dsb     sy
    isb

    msr     sp_el0, x20
    msr     elr_el1, x19
    mov     x0, #0             // SPSR_EL1 = 0: return to EL0t, DAIF clear (IRQ on)
    msr     spsr_el1, x0
    msr     tpidr_el0, xzr    // crt0 / pthread_trampoline installs per-thread TLS
    isb
    eret

// uintptr_t user_thread_launch_addr(void)
.global user_thread_launch_addr
user_thread_launch_addr:
    adrp    x0, user_thread_launch
    add     x0, x0, :lo12:user_thread_launch
    ret

// rt-a: first-run trampoline for a userland thread (thread_create). Same as
// user_thread_launch, but the new EL0 thread starts at entry(arg): the crafted
// context additionally carries the argument in x22, which we place in x0 (the
// AAPCS64 first argument) before eret'ing to the entry point.
//   x19 = entry virtual address
//   x20 = user stack top (SP_EL0)
//   x21 = TTBR0 of the (shared) process address space
//   x22 = argument (delivered to entry in x0)
.global user_thread_launch_arg
user_thread_launch_arg:
    msr     ttbr0_el1, x21
    dsb     sy
    isb
    tlbi    vmalle1
    dsb     sy
    isb

    msr     sp_el0, x20
    msr     elr_el1, x19
    mov     x0, #0             // SPSR_EL1 = 0: return to EL0t, DAIF clear (IRQ on)
    msr     spsr_el1, x0
    msr     tpidr_el0, xzr    // pthread_trampoline installs TLS before user entry
    mov     x0, x22            // deliver the thread argument as entry(arg)
    isb
    eret

// uintptr_t user_thread_launch_arg_addr(void)
.global user_thread_launch_arg_addr
user_thread_launch_arg_addr:
    adrp    x0, user_thread_launch_arg
    add     x0, x0, :lo12:user_thread_launch_arg
    ret
