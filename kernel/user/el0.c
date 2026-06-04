// el0.c — tiny EL0 entry helpers.

#include <stdint.h>

void user_program_install(void *code_dst, void *data_dst) {
    uint32_t *code = (uint32_t *)code_dst;
    char *data = (char *)data_dst;

    code[0] = 0xd2820000; // mov x0, #0x1000
    code[1] = 0xf2b00200; // movk x0, #0x8010, lsl #16
    code[2] = 0xd2800001; // mov x1, #0
    code[3] = 0xd2800028; // mov x8, #1 (open)
    code[4] = 0xd4000001; // svc #0
    code[5] = 0xaa0003f3; // mov x19, x0
    code[6] = 0xaa1303e0; // mov x0, x19
    code[7] = 0xd2822001; // mov x1, #0x1100
    code[8] = 0xf2b00201; // movk x1, #0x8010, lsl #16
    code[9] = 0xd2800802; // mov x2, #64
    code[10] = 0xd2800048; // mov x8, #2 (read)
    code[11] = 0xd4000001; // svc #0
    code[12] = 0xaa0003f4; // mov x20, x0
    code[13] = 0xd2800020; // mov x0, #1
    code[14] = 0xd2822001; // mov x1, #0x1100
    code[15] = 0xf2b00201; // movk x1, #0x8010, lsl #16
    code[16] = 0xaa1403e2; // mov x2, x20
    code[17] = 0xd2800068; // mov x8, #3 (write)
    code[18] = 0xd4000001; // svc #0
    code[19] = 0xaa1303e0; // mov x0, x19
    code[20] = 0xd2800088; // mov x8, #4 (close)
    code[21] = 0xd4000001; // svc #0
    code[22] = 0xd2800000; // mov x0, #0
    code[23] = 0xd28000a8; // mov x8, #5 (exit)
    code[24] = 0xd4000001; // svc #0
    code[25] = 0xd503207f; // wfi
    code[26] = 0x17ffffff; // b .-4

    const char path[] = "/hello.txt";
    for (unsigned i = 0; i < sizeof(path); i += 1) {
        data[i] = path[i];
    }

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
