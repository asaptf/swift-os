/* pthread.h - expose the SwiftOS newlib pthread compatibility surface. */
#ifndef _SWIFTOS_COMPAT_PTHREAD_H
#define _SWIFTOS_COMPAT_PTHREAD_H

#ifndef _POSIX_THREADS
#define _POSIX_THREADS 1
#endif

#ifndef _UNIX98_THREAD_MUTEX_ATTRIBUTES
#define _UNIX98_THREAD_MUTEX_ATTRIBUTES 1
#endif
#ifndef _POSIX_READER_WRITER_LOCKS
#define _POSIX_READER_WRITER_LOCKS 1
#endif
#ifndef _POSIX_BARRIERS
#define _POSIX_BARRIERS 1
#endif

#include_next <pthread.h>

#ifndef PTHREAD_STACK_MIN
#define PTHREAD_STACK_MIN 16384
#endif
#ifndef PTHREAD_PROCESS_PRIVATE
#define PTHREAD_PROCESS_PRIVATE 0
#endif

#endif
