// SPDX-License-Identifier: Apache-2.0
// limits.h - add SSIZE_MAX for the libuv masquerade, atop the real <limits.h>.
#ifndef _SWOS_NODE_COMPAT_LIMITS_H
#define _SWOS_NODE_COMPAT_LIMITS_H

#include_next <limits.h>

#ifndef SSIZE_MAX
#define SSIZE_MAX __LONG_MAX__
#endif

#endif /* _SWOS_NODE_COMPAT_LIMITS_H */
