// uvmutexprobe.c - C/newlib pthread mutex type proof for libuv.

#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>

static pthread_mutex_t owned_mutex;

static void fail(const char *label, int detail) {
    printf("uvmutexprobe: FAIL: %s detail=%d errno=%d\n", label, detail, errno);
}

static void *unlock_worker(void *arg) {
    pthread_mutex_t *mutex = (pthread_mutex_t *)arg;
    int r = pthread_mutex_unlock(mutex);
    return (void *)(intptr_t)r;
}

static void *lock_worker(void *arg) {
    pthread_mutex_t *mutex = (pthread_mutex_t *)arg;
    int r = pthread_mutex_lock(mutex);
    if (r != 0) { return (void *)(intptr_t)r; }
    r = pthread_mutex_unlock(mutex);
    return (void *)(intptr_t)r;
}

static int check_errorcheck_mutex(void) {
    pthread_mutexattr_t attr;
    int type = -1;
    if (pthread_mutexattr_init(&attr) != 0 ||
        pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_ERRORCHECK) != 0 ||
        pthread_mutexattr_gettype(&attr, &type) != 0 ||
        type != PTHREAD_MUTEX_ERRORCHECK) {
        fail("errorcheck attr", type);
        return 1;
    }

    if (pthread_mutex_init(&owned_mutex, &attr) != 0 ||
        pthread_mutexattr_destroy(&attr) != 0) {
        fail("errorcheck init", 0);
        return 1;
    }

    int r = pthread_mutex_lock(&owned_mutex);
    if (r != 0) {
        fail("errorcheck first lock", r);
        return 1;
    }
    r = pthread_mutex_lock(&owned_mutex);
    if (r != EDEADLK) {
        fail("errorcheck relock", r);
        return 1;
    }
    r = pthread_mutex_trylock(&owned_mutex);
    if (r != EBUSY) {
        fail("errorcheck trylock", r);
        return 1;
    }

    pthread_t worker;
    void *worker_ret = 0;
    if (pthread_create(&worker, 0, unlock_worker, &owned_mutex) != 0 ||
        pthread_join(worker, &worker_ret) != 0 ||
        (intptr_t)worker_ret != EPERM) {
        fail("errorcheck foreign unlock", (int)(intptr_t)worker_ret);
        return 1;
    }

    if (pthread_mutex_unlock(&owned_mutex) != 0 ||
        pthread_mutex_destroy(&owned_mutex) != 0) {
        fail("errorcheck cleanup", 0);
        return 1;
    }

    printf("uvmutexprobe: errorcheck attr/lock OK\n");
    printf("uvmutexprobe: cross-thread ownership OK\n");
    return 0;
}

static int check_recursive_mutex(void) {
    pthread_mutexattr_t attr;
    pthread_mutex_t mutex;
    int type = -1;
    if (pthread_mutexattr_init(&attr) != 0 ||
        pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE) != 0 ||
        pthread_mutexattr_gettype(&attr, &type) != 0 ||
        type != PTHREAD_MUTEX_RECURSIVE) {
        fail("recursive attr", type);
        return 1;
    }

    if (pthread_mutex_init(&mutex, &attr) != 0 ||
        pthread_mutexattr_destroy(&attr) != 0) {
        fail("recursive init", 0);
        return 1;
    }

    int r = pthread_mutex_lock(&mutex);
    if (r != 0) {
        fail("recursive first lock", r);
        return 1;
    }
    r = pthread_mutex_lock(&mutex);
    if (r != 0) {
        fail("recursive second lock", r);
        return 1;
    }
    r = pthread_mutex_trylock(&mutex);
    if (r != 0) {
        fail("recursive trylock", r);
        return 1;
    }
    for (int i = 0; i < 3; i++) {
        r = pthread_mutex_unlock(&mutex);
        if (r != 0) {
            fail("recursive unlock depth", r);
            return 1;
        }
    }
    r = pthread_mutex_unlock(&mutex);
    if (r != EPERM) {
        fail("recursive extra unlock", r);
        return 1;
    }

    pthread_t worker;
    void *worker_ret = 0;
    if (pthread_create(&worker, 0, lock_worker, &mutex) != 0 ||
        pthread_join(worker, &worker_ret) != 0 ||
        (intptr_t)worker_ret != 0) {
        fail("recursive worker lock", (int)(intptr_t)worker_ret);
        return 1;
    }

    if (pthread_mutex_destroy(&mutex) != 0) {
        fail("recursive destroy", 0);
        return 1;
    }
    printf("uvmutexprobe: recursive lock depth OK\n");
    return 0;
}

int main(void) {
    pthread_mutexattr_t attr;
    if (pthread_mutexattr_init(&attr) != 0) {
        fail("attr init", 0);
        return 1;
    }
    int r = pthread_mutexattr_settype(&attr, 99);
    if (r != EINVAL) {
        fail("invalid attr type", r);
        return 1;
    }
    if (pthread_mutexattr_destroy(&attr) != 0) {
        fail("attr destroy", 0);
        return 1;
    }

    if (check_errorcheck_mutex() != 0) { return 1; }
    if (check_recursive_mutex() != 0) { return 1; }

    printf("UVMUTEXPROBE-OK\n");
    return 0;
}
