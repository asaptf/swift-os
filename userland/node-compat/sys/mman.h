// SPDX-License-Identifier: Apache-2.0
// sys/mman.h - add MAP_POPULATE (a prefault hint) atop the real <sys/mman.h>.
// SwiftOS's mmap ignores the hint, so defining it to 0 is safe.
#ifndef _SWOS_NODE_COMPAT_SYS_MMAN_H
#define _SWOS_NODE_COMPAT_SYS_MMAN_H

#include_next <sys/mman.h>

#ifndef MAP_POPULATE
#define MAP_POPULATE 0
#endif

#endif /* _SWOS_NODE_COMPAT_SYS_MMAN_H */
