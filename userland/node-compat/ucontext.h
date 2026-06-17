// SPDX-License-Identifier: Apache-2.0
// ucontext.h - pull in the AArch64 ucontext types (sys/ucontext.h) for the
// masquerade. getcontext/swapcontext are not supported (no makecontext-based
// coroutines on SwiftOS); declared so any references compile and link to the
// ENOSYS stubs in node_compat.c.
#ifndef _SWOS_NODE_COMPAT_UCONTEXT_H
#define _SWOS_NODE_COMPAT_UCONTEXT_H

#include <sys/ucontext.h>

int  getcontext(ucontext_t *ucp);
int  setcontext(const ucontext_t *ucp);
void makecontext(ucontext_t *ucp, void (*func)(void), int argc, ...);
int  swapcontext(ucontext_t *oucp, const ucontext_t *ucp);

#endif /* _SWOS_NODE_COMPAT_UCONTEXT_H */
