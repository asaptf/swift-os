// SPDX-License-Identifier: Apache-2.0
// sys/resource.h - full rusage for the Node.js/libuv masquerade.
//
// userland/compat's rusage is minimal (ru_utime as long[2], no named fields),
// but libuv's uv_getrusage reads ru_utime.tv_sec and the full BSD field set.
// This node-compat header reuses compat's include guard so it fully supersedes
// compat's definition for the Node build only; other ports keep the minimal one.
#ifndef _SWIFTOS_SYS_RESOURCE_H
#define _SWIFTOS_SYS_RESOURCE_H

#include <sys/types.h>
#include <sys/time.h>

typedef unsigned long rlim_t;
struct rlimit { rlim_t rlim_cur, rlim_max; };
#define RLIM_INFINITY (~0UL)
#define RLIMIT_CPU     0
#define RLIMIT_FSIZE   1
#define RLIMIT_DATA    2
#define RLIMIT_STACK   3
#define RLIMIT_CORE    4
#define RLIMIT_RSS     5
#define RLIMIT_NPROC   6
#define RLIMIT_NOFILE  7
#define RLIMIT_MEMLOCK 8
#define RLIMIT_AS      9
#define RLIM_NLIMITS   16

struct rusage {
    struct timeval ru_utime;   /* user CPU time used */
    struct timeval ru_stime;   /* system CPU time used */
    long ru_maxrss;            /* maximum resident set size */
    long ru_ixrss;             /* integral shared memory size */
    long ru_idrss;             /* integral unshared data size */
    long ru_isrss;             /* integral unshared stack size */
    long ru_minflt;            /* page reclaims (soft page faults) */
    long ru_majflt;            /* page faults (hard page faults) */
    long ru_nswap;             /* swaps */
    long ru_inblock;           /* block input operations */
    long ru_oublock;           /* block output operations */
    long ru_msgsnd;            /* IPC messages sent */
    long ru_msgrcv;            /* IPC messages received */
    long ru_nsignals;          /* signals received */
    long ru_nvcsw;             /* voluntary context switches */
    long ru_nivcsw;            /* involuntary context switches */
};

#define RUSAGE_SELF      0
#define RUSAGE_CHILDREN (-1)
#define PRIO_PROCESS 0
#define PRIO_PGRP    1
#define PRIO_USER    2

#ifdef __cplusplus
extern "C" {
#endif
int getrlimit(int resource, struct rlimit *rlim);
int setrlimit(int resource, const struct rlimit *rlim);
int getrusage(int who, struct rusage *usage);
int getpriority(int which, id_t who);
int setpriority(int which, id_t who, int prio);
#ifdef __cplusplus
}
#endif

#endif /* _SWIFTOS_SYS_RESOURCE_H */
