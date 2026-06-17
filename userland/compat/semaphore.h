/* semaphore.h - POSIX semaphore declarations for SwiftOS newlib compat. */
#ifndef _SWIFTOS_COMPAT_SEMAPHORE_H
#define _SWIFTOS_COMPAT_SEMAPHORE_H

#include <limits.h>
#include <time.h>

#ifndef _POSIX_SEMAPHORES
#define _POSIX_SEMAPHORES 1
#endif

#ifndef SEM_VALUE_MAX
#define SEM_VALUE_MAX INT_MAX
#endif

typedef struct {
    unsigned int value;
} sem_t;

#ifdef __cplusplus
extern "C" {
#endif
int sem_init(sem_t *sem, int pshared, unsigned int value);
int sem_destroy(sem_t *sem);
int sem_wait(sem_t *sem);
int sem_trywait(sem_t *sem);
int sem_timedwait(sem_t *sem, const struct timespec *abstime);
int sem_post(sem_t *sem);
int sem_getvalue(sem_t *sem, int *sval);
#ifdef __cplusplus
}
#endif

#endif
