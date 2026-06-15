// SPDX-License-Identifier: Apache-2.0
// sys/prctl.h - prctl surface for the libuv linux masquerade.
//
// libuv guards prctl(PR_SET_NAME, ...) behind `#if defined(PR_SET_NAME)`. We
// intentionally do NOT define PR_SET_NAME so that block compiles out; thread
// naming goes through pthread_setname_np (already in userland/compat). The
// prototype is declared for any unconditional reference.
#ifndef _SWOS_NODE_COMPAT_SYS_PRCTL_H
#define _SWOS_NODE_COMPAT_SYS_PRCTL_H

int prctl(int option, ...);

#endif /* _SWOS_NODE_COMPAT_SYS_PRCTL_H */
