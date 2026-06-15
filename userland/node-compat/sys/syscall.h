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

long syscall(long number, ...);

#endif /* _SWOS_NODE_COMPAT_SYS_SYSCALL_H */
