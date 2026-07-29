// SPDX-License-Identifier: Apache-2.0
// sys/resource.h — rlimit + rusage for freestanding newlib ports.
//
// newlib's <sys/resource.h> has getrusage/struct rusage (timeval fields) but
// no rlimit/getrlimit/setrlimit. This header supersedes it via -isystem so
// ports get both: POSIX rlimit constants/types and a timeval-based rusage
// (bash, zsh, libuv expect ru_utime.tv_sec — long[2] was a silent trap).
// getrusage is a weak zeroing stub in stubs.c until the kernel exposes counters.
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
    struct timeval ru_utime; /* user CPU time used */
    struct timeval ru_stime; /* system CPU time used */
    long ru_maxrss;
    long ru_ixrss;
    long ru_idrss;
    long ru_isrss;
    long ru_minflt;
    long ru_majflt;
    long ru_nswap;
    long ru_inblock;
    long ru_oublock;
    long ru_msgsnd;
    long ru_msgrcv;
    long ru_nsignals;
    long ru_nvcsw;
    long ru_nivcsw;
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
