// SPDX-License-Identifier: Apache-2.0
// netpacket/packet.h - AF_PACKET sockaddr_ll for the libuv linux masquerade.
//
// libuv casts an AF_PACKET ifaddr to struct sockaddr_ll only to read the
// hardware (MAC) address (sll_addr). Minimal layout sufficient for that read.
#ifndef _SWOS_NODE_COMPAT_NETPACKET_PACKET_H
#define _SWOS_NODE_COMPAT_NETPACKET_PACKET_H

#include <stdint.h>
#include <sys/socket.h>

struct sockaddr_ll {
    unsigned short sll_family;
    uint16_t       sll_protocol;
    int            sll_ifindex;
    unsigned short sll_hatype;
    unsigned char  sll_pkttype;
    unsigned char  sll_halen;
    unsigned char  sll_addr[8];
};

#endif /* _SWOS_NODE_COMPAT_NETPACKET_PACKET_H */
