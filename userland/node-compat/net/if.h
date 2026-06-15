// SPDX-License-Identifier: Apache-2.0
// net/if.h - add Linux interface flags libuv reads, atop the real <net/if.h>.
#ifndef _SWOS_NODE_COMPAT_NET_IF_H
#define _SWOS_NODE_COMPAT_NET_IF_H

#include_next <net/if.h>

#ifndef IFF_UP
#define IFF_UP       0x1
#endif
#ifndef IFF_LOOPBACK
#define IFF_LOOPBACK 0x8
#endif
#ifndef IFF_RUNNING
#define IFF_RUNNING  0x40
#endif

#endif /* _SWOS_NODE_COMPAT_NET_IF_H */
