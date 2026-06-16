// SPDX-License-Identifier: Apache-2.0
// netinet/ip6.h - minimal IPv6 header shim for tcp_wrap.cc (linux masquerade).
//
// newlib has no <netinet/ip6.h>. tcp_wrap.cc includes it only to reach the
// IPPROTO_IPV6 socket-option constant (for the IPv6 traffic-class byte); it does
// not use struct ip6_hdr. <netinet/in.h> supplies IPPROTO_IPV6.
#ifndef _SWOS_NODE_COMPAT_NETINET_IP6_H
#define _SWOS_NODE_COMPAT_NETINET_IP6_H

#include <netinet/in.h>

#endif /* _SWOS_NODE_COMPAT_NETINET_IP6_H */
