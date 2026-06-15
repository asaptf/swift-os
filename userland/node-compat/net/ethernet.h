// SPDX-License-Identifier: Apache-2.0
// net/ethernet.h - placeholder for the libuv linux masquerade.
//
// Pulled in transitively by the linux interface-address path but no symbols
// from it are actually referenced by the libuv subset we build. Provide the
// common ethernet address length for completeness.
#ifndef _SWOS_NODE_COMPAT_NET_ETHERNET_H
#define _SWOS_NODE_COMPAT_NET_ETHERNET_H

#ifndef ETHER_ADDR_LEN
#define ETHER_ADDR_LEN 6
#endif
#ifndef ETH_ALEN
#define ETH_ALEN 6
#endif

#endif /* _SWOS_NODE_COMPAT_NET_ETHERNET_H */
