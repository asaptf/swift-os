/* time.h — POSIX time declarations missing from bare-metal newlib defaults. */
#ifndef _SWIFTOS_COMPAT_TIME_H
#define _SWIFTOS_COMPAT_TIME_H

#include_next <time.h>

extern long _timezone;
extern int _daylight;

#ifndef timezone
#define timezone _timezone
#endif

#ifndef daylight
#define daylight _daylight
#endif

#ifndef CLOCK_REALTIME_COARSE
#define CLOCK_REALTIME_COARSE 0
#endif
#ifndef CLOCK_REALTIME
#define CLOCK_REALTIME 1
#endif
#ifndef CLOCK_PROCESS_CPUTIME_ID
#define CLOCK_PROCESS_CPUTIME_ID 2
#endif
#ifndef CLOCK_THREAD_CPUTIME_ID
#define CLOCK_THREAD_CPUTIME_ID 3
#endif
#ifndef CLOCK_MONOTONIC
#define CLOCK_MONOTONIC 4
#endif
#ifndef CLOCK_MONOTONIC_RAW
#define CLOCK_MONOTONIC_RAW 5
#endif
#ifndef CLOCK_MONOTONIC_COARSE
#define CLOCK_MONOTONIC_COARSE 6
#endif
#ifndef CLOCK_BOOTTIME
#define CLOCK_BOOTTIME 7
#endif
#ifndef CLOCK_REALTIME_ALARM
#define CLOCK_REALTIME_ALARM 8
#endif
#ifndef CLOCK_BOOTTIME_ALARM
#define CLOCK_BOOTTIME_ALARM 9
#endif

int clock_gettime(clockid_t clock_id, struct timespec *tp);
int clock_getres(clockid_t clock_id, struct timespec *res);
int nanosleep(const struct timespec *req, struct timespec *rem);

#endif
