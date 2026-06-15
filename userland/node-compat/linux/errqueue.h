// SPDX-License-Identifier: Apache-2.0
// linux/errqueue.h - extended socket error surface for the libuv masquerade.
//
// libuv's udp.c compiles a MSG_ERRQUEUE recv path. SwiftOS never sets
// MSG_ERRQUEUE, so that path is dead at runtime, but the types/macros must
// exist to compile.
#ifndef _SWOS_NODE_COMPAT_LINUX_ERRQUEUE_H
#define _SWOS_NODE_COMPAT_LINUX_ERRQUEUE_H

#include <stdint.h>

struct sock_extended_err {
    uint32_t ee_errno;
    uint8_t  ee_origin;
    uint8_t  ee_type;
    uint8_t  ee_code;
    uint8_t  ee_pad;
    uint32_t ee_info;
    uint32_t ee_data;
};

/* Offending address follows the error structure. */
#define SO_EE_OFFENDER(ee) ((struct sockaddr *)((ee) + 1))

#ifndef SOL_IP
#define SOL_IP 0
#endif
#ifndef SOL_IPV6
#define SOL_IPV6 41
#endif
#ifndef IP_RECVERR
#define IP_RECVERR 11
#endif
#ifndef IPV6_RECVERR
#define IPV6_RECVERR 25
#endif

#endif /* _SWOS_NODE_COMPAT_LINUX_ERRQUEUE_H */
