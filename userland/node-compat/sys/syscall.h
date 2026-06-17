// SPDX-License-Identifier: Apache-2.0
// sys/syscall.h - raw syscall surface for the libuv linux masquerade.
//
// libuv's linux backend calls syscall(__NR_*, ...) for optional fast paths
// (io_uring, statx, copy_file_range, getrandom) and supplies its own __NR_*
// fallback defines. SwiftOS has none of those Linux syscalls, so the companion
// syscall() implementation returns -1/ENOSYS and libuv falls back to its
// portable paths (io_uring stays disabled, statx -> fstat, etc.).
#ifndef _SWOS_NODE_COMPAT_SYS_SYSCALL_H
#define _SWOS_NODE_COMPAT_SYS_SYSCALL_H

#ifdef __cplusplus
extern "C"
#endif
long syscall(long number, ...);

#include <linux/unistd.h>   /* __NR_* numbers (routed by node_compat.c syscall) */

/* SYS_* aliases of the __NR_* numbers libuv / V8 / Abseil reference directly.
 * node_compat.c's syscall() routes mmap/munmap/write to the real functions and
 * returns -ENOSYS for the rest, so callers fall back. */
#ifndef SYS_close
#define SYS_close 57
#endif
#ifndef SYS_write
#define SYS_write __NR_write
#endif
#ifndef SYS_mmap
#define SYS_mmap __NR_mmap
#endif
#ifndef SYS_mmap2
#define SYS_mmap2 __NR_mmap2
#endif
#ifndef SYS_munmap
#define SYS_munmap __NR_munmap
#endif
#ifndef SYS_futex
#define SYS_futex __NR_futex
#endif
#ifndef SYS_getcpu
#define SYS_getcpu __NR_getcpu
#endif
#ifndef SYS_rt_sigprocmask
#define SYS_rt_sigprocmask __NR_rt_sigprocmask
#endif
#ifndef SYS_gettid
#define SYS_gettid __NR_gettid
#endif
/* node_credentials.cc probes capabilities via syscall(SYS_capget,...); SwiftOS
 * has no capability model, so the router returns -ENOSYS and Node treats the
 * process as holding no capabilities (the safe default). Values are the aarch64
 * ABI numbers but are immaterial -- only the -ENOSYS fallback path is taken. */
#ifndef SYS_capget
#define SYS_capget 90
#endif
#ifndef SYS_capset
#define SYS_capset 91
#endif

#endif /* _SWOS_NODE_COMPAT_SYS_SYSCALL_H */
