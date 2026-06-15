// SPDX-License-Identifier: Apache-2.0
// asm/hwcap.h - AArch64 HWCAP_* bits for the masquerade. Abseil's CRC CPU
// detection (and other feature probes) test getauxval(AT_HWCAP) against these.
// Our getauxval() returns 0, so nothing is detected and portable code paths run;
// the bit values only need to match the Linux AArch64 ABI for correctness if
// auxv is ever wired up.
#ifndef _SWOS_NODE_COMPAT_ASM_HWCAP_H
#define _SWOS_NODE_COMPAT_ASM_HWCAP_H

#define HWCAP_FP       (1 << 0)
#define HWCAP_ASIMD    (1 << 1)
#define HWCAP_EVTSTRM  (1 << 2)
#define HWCAP_AES      (1 << 3)
#define HWCAP_PMULL    (1 << 4)
#define HWCAP_SHA1     (1 << 5)
#define HWCAP_SHA2     (1 << 6)
#define HWCAP_CRC32    (1 << 7)
#define HWCAP_ATOMICS  (1 << 8)
#define HWCAP_FPHP     (1 << 9)
#define HWCAP_ASIMDHP  (1 << 10)
#define HWCAP_CPUID    (1 << 11)
#define HWCAP_ASIMDRDM (1 << 12)

#endif /* _SWOS_NODE_COMPAT_ASM_HWCAP_H */
