// SPDX-License-Identifier: Apache-2.0
// sys/socket.h - add the AF_PACKET/PF_PACKET family atop the real header.
//
// libuv identifies the link-layer ifaddr entry by PF_PACKET. SwiftOS does not
// implement packet sockets; the value only needs to match what the companion
// getifaddrs() stamps on link-layer entries, so it is internally consistent.
#ifndef _SWOS_NODE_COMPAT_SYS_SOCKET_H
#define _SWOS_NODE_COMPAT_SYS_SOCKET_H

#include_next <sys/socket.h>

#ifndef AF_PACKET
#define AF_PACKET 17
#endif
#ifndef PF_PACKET
#define PF_PACKET AF_PACKET
#endif

#endif /* _SWOS_NODE_COMPAT_SYS_SOCKET_H */
