// el0.c — tiny EL0 entry helpers for M4.

#include <stdint.h>

void user_program_install(void *dst) {
    uint32_t *code = (uint32_t *)dst;

    code[0] = 0xd2800540; // mov x0, #42
    code[1] = 0xd4000001; // svc #0
    code[2] = 0xd503207f; // wfi
    code[3] = 0x17ffffff; // b .-4

    __asm__ volatile("dsb sy; ic iallu; dsb sy; isb" ::: "memory");
}

void enter_el0(uintptr_t entry, uintptr_t stack_top) {
    __asm__ volatile(
        "msr sp_el0, %1\n"
        "msr elr_el1, %0\n"
        "mov x9, #0\n"       // SPSR: return to EL0t, interrupts unmasked.
        "msr spsr_el1, x9\n"
        "isb\n"
        "eret\n"
        :
        : "r"(entry), "r"(stack_top)
        : "x9", "memory");
}
