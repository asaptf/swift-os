// SPDX-License-Identifier: Apache-2.0
// netinet/ip.h - minimal IPv4 header shim for tcp_wrap.cc (linux masquerade).
//
// newlib has no <netinet/ip.h>. tcp_wrap.cc includes it only to reach the
// IPPROTO_IP / IP_TOS socket-option constants when setting the IPv4 TOS/DSCP
// byte; it does not use struct iphdr. Pull those constants from <netinet/in.h>
// and supply IP_TOS (Linux value) if the platform header lacks it.
#ifndef _SWOS_NODE_COMPAT_NETINET_IP_H
#define _SWOS_NODE_COMPAT_NETINET_IP_H

#include <netinet/in.h>

#ifndef IPPROTO_IP
#define IPPROTO_IP 0
#endif
#ifndef IP_TOS
#define IP_TOS 1
#endif

#endif /* _SWOS_NODE_COMPAT_NETINET_IP_H */
