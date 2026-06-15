// SPDX-License-Identifier: Apache-2.0
// netinet/in.h - add IPv4/IPv6 multicast + membership constants for the libuv
// masquerade, atop compat's <netinet/in.h>. SwiftOS may not honor all options;
// libuv reports setsockopt errors where unsupported.
#ifndef _SWOS_NODE_COMPAT_NETINET_IN_H
#define _SWOS_NODE_COMPAT_NETINET_IN_H

#include_next <netinet/in.h>
#include <stdint.h>
#include <sys/socket.h>

#ifndef IPPROTO_IPV6
#define IPPROTO_IPV6 41
#endif

/* Multicast group membership structures libuv populates for setsockopt. */
struct ip_mreq {
    struct in_addr imr_multiaddr;
    struct in_addr imr_interface;
};
struct ip_mreq_source {
    struct in_addr imr_multiaddr;
    struct in_addr imr_interface;
    struct in_addr imr_sourceaddr;
};
struct ipv6_mreq {
    struct in6_addr ipv6mr_multiaddr;
    unsigned int    ipv6mr_interface;
};

/* Source-specific multicast group requests (MCAST_*_SOURCE_GROUP). */
struct group_source_req {
    uint32_t                gsr_interface;
    struct sockaddr_storage gsr_group;
    struct sockaddr_storage gsr_source;
};

/* IPv4 multicast / membership */
#ifndef IP_MULTICAST_IF
#define IP_MULTICAST_IF 32
#endif
#ifndef IP_MULTICAST_TTL
#define IP_MULTICAST_TTL 33
#endif
#ifndef IP_MULTICAST_LOOP
#define IP_MULTICAST_LOOP 34
#endif
#ifndef IP_ADD_MEMBERSHIP
#define IP_ADD_MEMBERSHIP 35
#endif
#ifndef IP_DROP_MEMBERSHIP
#define IP_DROP_MEMBERSHIP 36
#endif

/* IPv6 multicast / membership */
#ifndef IPV6_MULTICAST_IF
#define IPV6_MULTICAST_IF 17
#endif
#ifndef IPV6_MULTICAST_HOPS
#define IPV6_MULTICAST_HOPS 18
#endif
#ifndef IPV6_MULTICAST_LOOP
#define IPV6_MULTICAST_LOOP 19
#endif
#ifndef IPV6_ADD_MEMBERSHIP
#define IPV6_ADD_MEMBERSHIP 20
#endif
#ifndef IPV6_DROP_MEMBERSHIP
#define IPV6_DROP_MEMBERSHIP 21
#endif
#ifndef IPV6_UNICAST_HOPS
#define IPV6_UNICAST_HOPS 16
#endif

#ifndef IP_TTL
#define IP_TTL 2
#endif
#ifndef IP_ADD_SOURCE_MEMBERSHIP
#define IP_ADD_SOURCE_MEMBERSHIP 39
#endif
#ifndef IP_DROP_SOURCE_MEMBERSHIP
#define IP_DROP_SOURCE_MEMBERSHIP 40
#endif
#ifndef MCAST_JOIN_SOURCE_GROUP
#define MCAST_JOIN_SOURCE_GROUP 46
#endif
#ifndef MCAST_LEAVE_SOURCE_GROUP
#define MCAST_LEAVE_SOURCE_GROUP 47
#endif

/* Global any-address (provided by the companion implementation at link). */
extern const struct in6_addr in6addr_any;

#endif /* _SWOS_NODE_COMPAT_NETINET_IN_H */
