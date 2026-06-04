#ifndef _SWIFTOS_COMPAT_SCHED_H
#define _SWIFTOS_COMPAT_SCHED_H
#include_next <sched.h>
int sched_getaffinity(int pid, unsigned long cpusetsize, void *mask);
int sched_setaffinity(int pid, unsigned long cpusetsize, const void *mask);
#endif
