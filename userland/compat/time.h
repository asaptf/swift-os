/* time.h — add POSIX sleep prototype missing from bare-metal newlib. */
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

int nanosleep(const struct timespec *req, struct timespec *rem);

#endif
