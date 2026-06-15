// SPDX-License-Identifier: Apache-2.0
// sys/mman.h - add MAP_POPULATE (a prefault hint) atop the real <sys/mman.h>.
// SwiftOS's mmap ignores the hint, so defining it to 0 is safe.
#ifndef _SWOS_NODE_COMPAT_SYS_MMAN_H
#define _SWOS_NODE_COMPAT_SYS_MMAN_H

#include_next <sys/mman.h>

#ifndef MAP_POPULATE
#define MAP_POPULATE 0
#endif

/* madvise hints V8 uses to release/return memory. SwiftOS does not page these,
 * so the companion madvise() is a no-op; the constants only need to compile. */
#ifndef MADV_NORMAL
#define MADV_NORMAL   0
#endif
#ifndef MADV_DONTNEED
#define MADV_DONTNEED 4
#endif
#ifndef MADV_FREE
#define MADV_FREE     8
#endif
int madvise(void *addr, size_t length, int advice);

#endif /* _SWOS_NODE_COMPAT_SYS_MMAN_H */
