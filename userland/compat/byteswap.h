/* byteswap.h — compat shim for newlib (busybox expects the glibc header). */
#ifndef _SWIFTOS_BYTESWAP_H
#define _SWIFTOS_BYTESWAP_H
#define bswap_16(x) __builtin_bswap16(x)
#define bswap_32(x) __builtin_bswap32(x)
#define bswap_64(x) __builtin_bswap64(x)
#endif
