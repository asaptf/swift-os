// SPDX-License-Identifier: Apache-2.0
// ifaddrs.h - getifaddrs surface for the Node.js/libuv linux masquerade.
//
// libuv enumerates interface addresses via getifaddrs(). The companion
// implementation builds the list from the SwiftOS network stack (or returns an
// empty list as a first-pass fallback). Only the fields libuv reads are
// declared: ifa_next, ifa_name, ifa_flags, ifa_addr, ifa_netmask.
#ifndef _SWOS_NODE_COMPAT_IFADDRS_H
#define _SWOS_NODE_COMPAT_IFADDRS_H

#include <sys/socket.h>

struct ifaddrs {
    struct ifaddrs  *ifa_next;
    char            *ifa_name;
    unsigned int     ifa_flags;
    struct sockaddr *ifa_addr;
    struct sockaddr *ifa_netmask;
    union {
        struct sockaddr *ifu_broadaddr;
        struct sockaddr *ifu_dstaddr;
    } ifa_ifu;
    void            *ifa_data;
};

int  getifaddrs(struct ifaddrs **ifap);
void freeifaddrs(struct ifaddrs *ifa);

#endif /* _SWOS_NODE_COMPAT_IFADDRS_H */
