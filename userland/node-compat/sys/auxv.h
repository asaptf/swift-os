// SPDX-License-Identifier: Apache-2.0
// sys/auxv.h - getauxval for the masquerade. SwiftOS exposes no ELF auxiliary
// vector, so the companion getauxval() returns 0 (no optional CPU-feature bits),
// and V8 falls back to the AArch64 baseline.
#ifndef _SWOS_NODE_COMPAT_SYS_AUXV_H
#define _SWOS_NODE_COMPAT_SYS_AUXV_H

#include <linux/auxvec.h>

#ifdef __cplusplus
extern "C"
#endif
unsigned long getauxval(unsigned long type);

#endif /* _SWOS_NODE_COMPAT_SYS_AUXV_H */
