// SPDX-License-Identifier: Apache-2.0
// pthread.h - add CPU-affinity prototypes for the libuv linux masquerade, atop
// userland/compat's pthread.h (which exposes the newlib pthread surface).
#ifndef _SWOS_NODE_COMPAT_PTHREAD_H
#define _SWOS_NODE_COMPAT_PTHREAD_H

#include_next <pthread.h>
#include <sched.h>

int pthread_getaffinity_np(pthread_t thread, size_t cpusetsize, cpu_set_t *cpuset);
int pthread_setaffinity_np(pthread_t thread, size_t cpusetsize, const cpu_set_t *cpuset);
int pthread_getschedparam(pthread_t thread, int *policy, struct sched_param *param);
int pthread_setschedparam(pthread_t thread, int policy, const struct sched_param *param);
/* V8 uses pthread_getattr_np to discover a thread's stack base/size. */
int pthread_getattr_np(pthread_t thread, pthread_attr_t *attr);

#endif /* _SWOS_NODE_COMPAT_PTHREAD_H */
