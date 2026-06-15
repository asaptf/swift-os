// SPDX-License-Identifier: Apache-2.0
// sys/stat.h - add UTIME_NOW/UTIME_OMIT for the libuv masquerade, atop compat's.
#ifndef _SWOS_NODE_COMPAT_SYS_STAT_H
#define _SWOS_NODE_COMPAT_SYS_STAT_H

#include_next <sys/stat.h>

#ifndef UTIME_NOW
#define UTIME_NOW  ((1l << 30) - 1l)
#endif
#ifndef UTIME_OMIT
#define UTIME_OMIT ((1l << 30) - 2l)
#endif

#endif /* _SWOS_NODE_COMPAT_SYS_STAT_H */
