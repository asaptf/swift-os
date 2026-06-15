// SPDX-License-Identifier: Apache-2.0
// linux/auxvec.h - auxiliary-vector keys for the masquerade. V8's cpu.cc reads
// AT_HWCAP via getauxval to probe optional CPU features.
#ifndef _SWOS_NODE_COMPAT_LINUX_AUXVEC_H
#define _SWOS_NODE_COMPAT_LINUX_AUXVEC_H

#ifndef AT_HWCAP
#define AT_HWCAP  16
#endif
#ifndef AT_HWCAP2
#define AT_HWCAP2 26
#endif

#endif /* _SWOS_NODE_COMPAT_LINUX_AUXVEC_H */
