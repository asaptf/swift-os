// SPDX-License-Identifier: Apache-2.0
// linux/unistd.h - __NR_* syscall numbers for the masquerade. Abseil/V8 call
// syscall(__NR_*, ...) directly for a few fast paths. The companion syscall()
// routes mmap/munmap/write to the real functions and returns -ENOSYS for the
// rest, so callers fall back. Values are the Linux aarch64 numbers (they only
// need to agree between this header and node_compat.c's syscall()).
#ifndef _SWOS_NODE_COMPAT_LINUX_UNISTD_H
#define _SWOS_NODE_COMPAT_LINUX_UNISTD_H

#ifndef __NR_write
#define __NR_write 64
#endif
#ifndef __NR_munmap
#define __NR_munmap 215
#endif
#ifndef __NR_mmap
#define __NR_mmap 222
#endif
#ifndef __NR_mmap2          /* not native on aarch64; alias mmap so code compiles */
#define __NR_mmap2 222
#endif
#ifndef __NR_futex
#define __NR_futex 98
#endif
#ifndef __NR_getcpu
#define __NR_getcpu 168
#endif
#ifndef __NR_rt_sigprocmask
#define __NR_rt_sigprocmask 135
#endif
#ifndef __NR_gettid
#define __NR_gettid 178
#endif

#endif /* _SWOS_NODE_COMPAT_LINUX_UNISTD_H */
