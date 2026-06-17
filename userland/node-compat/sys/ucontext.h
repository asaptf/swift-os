// SPDX-License-Identifier: Apache-2.0
// sys/ucontext.h - AArch64 ucontext for the masquerade (glibc-compatible layout).
// Abseil's stack-trace / signal-handler code reads uc_mcontext.{pc,sp,regs} from
// the ucontext a signal handler receives. SwiftOS does not deliver rich signal
// contexts yet, so this is mainly for compilation; the layout matches the Linux
// AArch64 ABI in case contexts are wired up later.
#ifndef _SWOS_NODE_COMPAT_SYS_UCONTEXT_H
#define _SWOS_NODE_COMPAT_SYS_UCONTEXT_H

#include <signal.h>
#include <stddef.h>

typedef struct sigcontext {
    unsigned long long fault_address;
    unsigned long long regs[31];
    unsigned long long sp;
    unsigned long long pc;
    unsigned long long pstate;
    /* reserved for FP/SIMD context, etc. */
    unsigned char      __reserved[4096] __attribute__((__aligned__(16)));
} mcontext_t;

typedef struct ucontext_t {
    unsigned long          uc_flags;
    struct ucontext_t     *uc_link;
    stack_t                uc_stack;
    mcontext_t             uc_mcontext;
    sigset_t               uc_sigmask;
} ucontext_t;

#endif /* _SWOS_NODE_COMPAT_SYS_UCONTEXT_H */
