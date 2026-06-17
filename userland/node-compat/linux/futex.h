// SPDX-License-Identifier: Apache-2.0
// linux/futex.h - FUTEX_* op constants for the masquerade. Abseil's spinlock and
// V8's Atomics futex emulation reference these. node_compat.c's syscall() returns
// -ENOSYS for SYS_futex for now, so Abseil's spinlock degrades to spinning
// (correct, just busier) and V8 Atomics.wait/notify is unsupported — a deferred
// refinement, not a blocker for normal execution.
#ifndef _SWOS_NODE_COMPAT_LINUX_FUTEX_H
#define _SWOS_NODE_COMPAT_LINUX_FUTEX_H

#ifndef FUTEX_WAIT
#define FUTEX_WAIT 0
#endif
#ifndef FUTEX_WAKE
#define FUTEX_WAKE 1
#endif
#ifndef FUTEX_PRIVATE_FLAG
#define FUTEX_PRIVATE_FLAG 128
#endif
#ifndef FUTEX_WAIT_BITSET
#define FUTEX_WAIT_BITSET 9
#endif
#ifndef FUTEX_WAKE_BITSET
#define FUTEX_WAKE_BITSET 10
#endif
/* Defining FUTEX_CLOCK_REALTIME makes Abseil select its futex-based waiter (over
 * the std::mutex-based stdcpp waiter, which our threadless libstdc++ lacks). */
#ifndef FUTEX_CLOCK_REALTIME
#define FUTEX_CLOCK_REALTIME 256
#endif
#ifndef FUTEX_BITSET_MATCH_ANY
#define FUTEX_BITSET_MATCH_ANY 0xFFFFFFFF
#endif

#endif /* _SWOS_NODE_COMPAT_LINUX_FUTEX_H */
