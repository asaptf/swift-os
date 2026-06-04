// ustack.c — build the initial EL0 stack (argc/argv/envp/auxv).
//
// Lays out the SysV AArch64 process-entry stack at the top of a process's
// mapped user stack, in the process's own address space. Arguments arrive
// packed as NUL-separated strings ("a\0b\0c\0"); we copy them to the stack top,
// then build the pointer block the C runtime expects:
//
//   sp -> [ argc ][ argv[0..argc-1] ][ NULL ][ envp NULL ][ auxv AT_NULL x2 ]
//         [ ... strings ... ]
//
// crt0 reads argc from [sp] and argv from sp+8. Pointers stored are user VAs.

#include "../arch/aarch64/io.h"

#define MAX_ARGS 32

static void write_u64_user(uintptr_t ttbr0, uintptr_t va, uint64_t value) {
    uintptr_t pa = address_space_translate(ttbr0, va);
    if (pa != 0) {
        *(volatile uint64_t *)pa = value;
    }
}

static void copy_bytes_user(uintptr_t ttbr0, uintptr_t va, const char *src, unsigned long len) {
    for (unsigned long i = 0; i < len; i += 1) {
        uintptr_t pa = address_space_translate(ttbr0, va + i);
        if (pa != 0) {
            *(volatile unsigned char *)pa = (unsigned char)src[i];
        }
    }
}

// Returns the user SP (VA), 16-byte aligned, or 0 on error.
uintptr_t user_stack_build(uintptr_t ttbr0, uintptr_t stack_top,
                           const char *packed, unsigned long packed_len, int argc) {
    if (argc < 0 || argc > MAX_ARGS) {
        return 0;
    }

    // Copy the packed strings to the top of the stack.
    uintptr_t str_base = (stack_top - packed_len) & ~(uintptr_t)15;
    copy_bytes_user(ttbr0, str_base, packed, packed_len);

    // Resolve each argument's user VA by scanning NUL boundaries.
    uintptr_t argv_va[MAX_ARGS];
    unsigned long off = 0;
    for (int i = 0; i < argc; i += 1) {
        argv_va[i] = str_base + off;
        while (off < packed_len && packed[off] != '\0') {
            off += 1;
        }
        off += 1; // skip the NUL
    }

    // Pointer block: argc + argv[argc] + NULL + envp NULL + auxv(AT_NULL pair).
    unsigned long slots = 1 + (unsigned long)(argc + 1) + 1 + 2;
    uintptr_t sp = (str_base - slots * 8) & ~(uintptr_t)15;

    uintptr_t cur = sp;
    write_u64_user(ttbr0, cur, (uint64_t)argc); cur += 8;
    for (int i = 0; i < argc; i += 1) {
        write_u64_user(ttbr0, cur, (uint64_t)argv_va[i]); cur += 8;
    }
    write_u64_user(ttbr0, cur, 0); cur += 8; // argv terminator
    write_u64_user(ttbr0, cur, 0); cur += 8; // envp terminator
    write_u64_user(ttbr0, cur, 0); cur += 8; // auxv type AT_NULL
    write_u64_user(ttbr0, cur, 0); cur += 8; // auxv value

    return sp;
}
