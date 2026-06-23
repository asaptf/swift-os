/* SPDX-License-Identifier: Apache-2.0 */
/* arpa/nameser.h — minimal BIND DNS message constants for swift-os.
 *
 * newlib ships no resolver headers. GLib's gio resolver (and other ports)
 * probe for these classic constants/macros at configure time. swift-os has no
 * in-tree resolver, so this provides the legacy definitions directly (so
 * arpa/nameser_compat.h is "not needed"); they are values only and pull in no
 * implementation. */
#ifndef _SWIFTOS_ARPA_NAMESER_H
#define _SWIFTOS_ARPA_NAMESER_H

#include <sys/types.h>
#include <stdint.h>

/* Message sizes */
#define NS_PACKETSZ   512
#define NS_MAXDNAME   1025
#define NS_MAXLABEL   63
#define NS_HFIXEDSZ   12
#define NS_QFIXEDSZ   4
#define NS_RRFIXEDSZ  10
#define NS_INT16SZ    2
#define NS_INT32SZ    4

/* Classes */
typedef enum __ns_class {
    ns_c_invalid = 0,
    ns_c_in      = 1,
    ns_c_chaos   = 3,
    ns_c_hs      = 4,
    ns_c_none    = 254,
    ns_c_any     = 255
} ns_class;

/* Types */
typedef enum __ns_type {
    ns_t_invalid = 0,
    ns_t_a       = 1,
    ns_t_ns      = 2,
    ns_t_cname   = 5,
    ns_t_soa     = 6,
    ns_t_ptr     = 12,
    ns_t_mx      = 15,
    ns_t_txt     = 16,
    ns_t_aaaa    = 28,
    ns_t_srv     = 33,
    ns_t_any     = 255
} ns_type;

/* Legacy (nameser_compat) aliases */
#define C_IN    ns_c_in
#define C_CHAOS ns_c_chaos
#define C_HS    ns_c_hs
#define C_ANY   ns_c_any

#define T_A     ns_t_a
#define T_NS    ns_t_ns
#define T_CNAME ns_t_cname
#define T_SOA   ns_t_soa
#define T_PTR   ns_t_ptr
#define T_MX    ns_t_mx
#define T_TXT   ns_t_txt
#define T_AAAA  ns_t_aaaa
#define T_SRV   ns_t_srv
#define T_ANY   ns_t_any

#define PACKETSZ  NS_PACKETSZ
#define MAXDNAME  NS_MAXDNAME
#define HFIXEDSZ  NS_HFIXEDSZ
#define QFIXEDSZ  NS_QFIXEDSZ
#define RRFIXEDSZ NS_RRFIXEDSZ
#define INT16SZ   NS_INT16SZ
#define INT32SZ   NS_INT32SZ

/* Big-endian extraction/insertion macros */
#define NS_GET16(s, cp) do { \
    const unsigned char *t_cp = (const unsigned char *)(cp); \
    (s) = (uint16_t)(((uint16_t)t_cp[0] << 8) | ((uint16_t)t_cp[1])); \
    (cp) += NS_INT16SZ; } while (0)
#define NS_GET32(l, cp) do { \
    const unsigned char *t_cp = (const unsigned char *)(cp); \
    (l) = (uint32_t)(((uint32_t)t_cp[0] << 24) | ((uint32_t)t_cp[1] << 16) | \
                     ((uint32_t)t_cp[2] << 8)  | ((uint32_t)t_cp[3])); \
    (cp) += NS_INT32SZ; } while (0)
#define GETSHORT NS_GET16
#define GETLONG  NS_GET32

#endif /* _SWIFTOS_ARPA_NAMESER_H */
