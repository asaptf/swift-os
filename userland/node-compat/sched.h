// SPDX-License-Identifier: Apache-2.0
// sched.h - cpu_set_t + CPU_* macros for the libuv linux masquerade, atop the
// real <sched.h> (which already declares sched_get/setaffinity).
#ifndef _SWOS_NODE_COMPAT_SCHED_H
#define _SWOS_NODE_COMPAT_SCHED_H

#include_next <sched.h>
#include <string.h>

#define CPU_SETSIZE 1024
#define __NCPUBITS (8 * sizeof(unsigned long))

typedef struct {
    unsigned long __bits[CPU_SETSIZE / __NCPUBITS];
} cpu_set_t;

static inline void CPU_ZERO(cpu_set_t *s) { memset(s, 0, sizeof(*s)); }
static inline void CPU_SET(int c, cpu_set_t *s) {
    if ((unsigned)c < CPU_SETSIZE) s->__bits[c / __NCPUBITS] |= 1UL << (c % __NCPUBITS);
}
static inline void CPU_CLR(int c, cpu_set_t *s) {
    if ((unsigned)c < CPU_SETSIZE) s->__bits[c / __NCPUBITS] &= ~(1UL << (c % __NCPUBITS));
}
static inline int CPU_ISSET(int c, const cpu_set_t *s) {
    if ((unsigned)c >= CPU_SETSIZE) return 0;
    return (s->__bits[c / __NCPUBITS] >> (c % __NCPUBITS)) & 1UL;
}
static inline int CPU_COUNT(const cpu_set_t *s) {
    int n = 0;
    for (unsigned i = 0; i < CPU_SETSIZE / __NCPUBITS; i++)
        n += __builtin_popcountl(s->__bits[i]);
    return n;
}

int sched_get_priority_max(int policy);
int sched_get_priority_min(int policy);

#endif /* _SWOS_NODE_COMPAT_SCHED_H */
