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

/* Linux/OpenSSL/libuv compile once-controls as a single word (PTHREAD_ONCE_INIT=0).
 * newlib's 8-byte {is_initialized, init_executed} made pthread_once touch the neighbour
 * word on 4-byte CRYPTO_ONCE objects and double-ran OpenSSL init (SIGSEGV in
 * OPENSSL_LH_insert during npm config/install). Runtime uses only the first word. */
#undef PTHREAD_ONCE_INIT
#define PTHREAD_ONCE_INIT {0}

#ifndef PTHREAD_STACK_MIN
#define PTHREAD_STACK_MIN 16384
#endif
#ifndef PTHREAD_PROCESS_PRIVATE
#define PTHREAD_PROCESS_PRIVATE 0
#endif

int pthread_atfork(void (*prepare)(void), void (*parent)(void), void (*child)(void));
int pthread_getname_np(pthread_t thread, char *name, size_t size);
int pthread_setname_np(pthread_t thread, const char *name);

#endif
