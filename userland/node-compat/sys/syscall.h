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

/* libuv references a few SYS_* numbers directly (e.g. syscall(SYS_gettid)).
 * The values are placeholders: the companion syscall() returns -ENOSYS for all
 * of them, so libuv takes its portable fallback (e.g. uv_os_gettid -> error). */
#ifndef SYS_close
#define SYS_close 57
#endif
#ifndef SYS_gettid
#define SYS_gettid 178
#endif
/* V8 calls syscall(__NR_gettid); our syscall() returns -ENOSYS so V8's gettid
 * falls back. The value only needs to exist. */
#ifndef __NR_gettid
#define __NR_gettid SYS_gettid
#endif

#endif /* _SWOS_NODE_COMPAT_SYS_SYSCALL_H */
