// SPDX-License-Identifier: Apache-2.0
// linux/capability.h - Linux capability ABI shim for node_credentials.cc.
//
// Node probes process capabilities (specifically CAP_NET_BIND_SERVICE, to decide
// whether an unprivileged process may bind low ports) via syscall(SYS_capget).
// SwiftOS has no Linux capability model: node_compat.c's syscall() router returns
// -ENOSYS for SYS_capget, so HasOnly() sees the call fail and reports "no
// capability" -- the safe default. We only need the structs, macros, and the
// CAP_* constant Node references so the translation unit compiles.
#ifndef _SWOS_NODE_COMPAT_LINUX_CAPABILITY_H
#define _SWOS_NODE_COMPAT_LINUX_CAPABILITY_H

#include <stdint.h>

/* Capability set versions (value matches Linux; only V3 is used by Node). */
#define _LINUX_CAPABILITY_VERSION_1 0x19980330
#define _LINUX_CAPABILITY_VERSION_2 0x20071026
#define _LINUX_CAPABILITY_VERSION_3 0x20080522
#define _LINUX_CAPABILITY_U32S_1    1
#define _LINUX_CAPABILITY_U32S_2    2
#define _LINUX_CAPABILITY_U32S_3    2

typedef struct __user_cap_header_struct {
    uint32_t version;
    int      pid;
} *cap_user_header_t;

typedef struct __user_cap_data_struct {
    uint32_t effective;
    uint32_t permitted;
    uint32_t inheritable;
} *cap_user_data_t;

/* Capability constants Node references. CAP_NET_BIND_SERVICE is the only one it
 * actually checks; CAP_LAST_CAP bounds cap_valid(). Values match the Linux ABI. */
#define CAP_NET_BIND_SERVICE 10
#define CAP_LAST_CAP         40

#define CAP_TO_INDEX(x) ((x) >> 5)         /* word index in the bitmask array */
#define CAP_TO_MASK(x)  (1u << ((x) & 31)) /* bit within that word */
#define cap_valid(x)    ((x) >= 0 && (x) <= CAP_LAST_CAP)

#endif /* _SWOS_NODE_COMPAT_LINUX_CAPABILITY_H */
