// SPDX-License-Identifier: Apache-2.0
// netdb.h - add getservbyport_r for the masquerade, atop compat/newlib netdb.h.
// c-ares uses it for reverse service lookups; the companion implementation
// reports no result so c-ares falls back to the numeric port.
#ifndef _SWOS_NODE_COMPAT_NETDB_H
#define _SWOS_NODE_COMPAT_NETDB_H

#include_next <netdb.h>

int getservbyport_r(int port, const char *proto, struct servent *result_buf,
                    char *buf, size_t buflen, struct servent **result);

#endif /* _SWOS_NODE_COMPAT_NETDB_H */
