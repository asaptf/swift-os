// SPDX-License-Identifier: Apache-2.0
// signal.h - add SA_RESETHAND for the libuv masquerade, atop compat's signal.h.
#ifndef _SWOS_NODE_COMPAT_SIGNAL_H
#define _SWOS_NODE_COMPAT_SIGNAL_H

#include_next <signal.h>

#ifndef SA_RESETHAND
#define SA_RESETHAND 0x80000000
#endif
#ifndef SA_ONSTACK
#define SA_ONSTACK 0x08000000
#endif
#ifndef SA_NODEFER
#define SA_NODEFER 0x40000000
#endif
#ifndef SA_RESTART
#define SA_RESTART 0x10000000
#endif

#endif /* _SWOS_NODE_COMPAT_SIGNAL_H */
