#ifndef _SWIFTOS_SYS_RESOURCE_H
#define _SWIFTOS_SYS_RESOURCE_H
#include <sys/types.h>
typedef unsigned long rlim_t;
struct rlimit { rlim_t rlim_cur, rlim_max; };
#define RLIM_INFINITY (~0UL)
#define RLIMIT_CPU    0
#define RLIMIT_FSIZE  1
#define RLIMIT_DATA   2
#define RLIMIT_STACK  3
#define RLIMIT_CORE   4
#define RLIMIT_RSS    5
#define RLIMIT_NPROC  6
#define RLIMIT_NOFILE 7
#define RLIMIT_MEMLOCK 8
#define RLIMIT_AS     9
#define RLIM_NLIMITS  16
struct rusage { long ru_utime[2]; long ru_stime[2]; long ru_maxrss; long ru_pad[14]; };
#define RUSAGE_SELF 0
#define RUSAGE_CHILDREN (-1)
int getrlimit(int resource, struct rlimit *rlim);
int setrlimit(int resource, const struct rlimit *rlim);
int getrusage(int who, struct rusage *usage);
int getpriority(int which, id_t who);
int setpriority(int which, id_t who, int prio);
#endif
