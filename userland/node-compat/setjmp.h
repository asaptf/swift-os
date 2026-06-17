// SPDX-License-Identifier: Apache-2.0
// setjmp.h - add the sig*jmp family (newlib lacks it) for the masquerade.
// OpenSSL's armcap.c uses sigsetjmp/siglongjmp to recover from SIGILL while
// probing optional CPU instructions. SwiftOS does not save/restore the signal
// mask across jumps, so these map to plain setjmp/longjmp — the SIGILL recovery
// still works; only the (unused-here) mask save/restore is dropped.
#ifndef _SWOS_NODE_COMPAT_SETJMP_H
#define _SWOS_NODE_COMPAT_SETJMP_H

#include_next <setjmp.h>

#ifndef sigsetjmp
typedef jmp_buf sigjmp_buf;
#define sigsetjmp(env, savemask) setjmp(env)
#define siglongjmp(env, val)     longjmp((env), (val))
#endif

#endif /* _SWOS_NODE_COMPAT_SETJMP_H */
