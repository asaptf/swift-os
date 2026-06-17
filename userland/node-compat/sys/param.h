// SPDX-License-Identifier: Apache-2.0
// sys/param.h - add the BSD roundup()/rounddown() macros atop newlib's
// <sys/param.h>. deps/postject (Node's Single Executable Application support)
// uses roundup() to walk ELF note padding; newlib's <sys/param.h> omits it.
#ifndef _SWOS_NODE_COMPAT_SYS_PARAM_H
#define _SWOS_NODE_COMPAT_SYS_PARAM_H

#include_next <sys/param.h>

#ifndef roundup
#define roundup(x, y)   ((((x) + ((y) - 1)) / (y)) * (y))
#endif
#ifndef rounddown
#define rounddown(x, y) (((x) / (y)) * (y))
#endif

#endif /* _SWOS_NODE_COMPAT_SYS_PARAM_H */
