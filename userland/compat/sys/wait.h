/* sys/wait.h — add wait status helpers busybox expects. */
#ifndef _SWIFTOS_COMPAT_SYS_WAIT_H
#define _SWIFTOS_COMPAT_SYS_WAIT_H

#include_next <sys/wait.h>

#ifndef WCOREDUMP
#define WCOREDUMP(status) (0)
#endif

#endif
