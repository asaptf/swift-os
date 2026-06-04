/* time.h — add POSIX sleep prototype missing from bare-metal newlib. */
#ifndef _SWIFTOS_COMPAT_TIME_H
#define _SWIFTOS_COMPAT_TIME_H

#include_next <time.h>

int nanosleep(const struct timespec *req, struct timespec *rem);

#endif
