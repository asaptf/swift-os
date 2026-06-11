// threadsyncprobe.c - C/newlib thread synchronization probe for SwiftOS.

#include <errno.h>
#include <pthread.h>
#include <semaphore.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>

static pthread_rwlock_t rwlock = PTHREAD_RWLOCK_INITIALIZER;
static sem_t gate_sem;
static sem_t inside_sem;
static sem_t release_sem;
static sem_t done_sem;
static int active_readers;
static int reader_peak;
static int reader_errors;
static int shared_value;

static void fail(const char *msg, int err) {
    printf("threadsyncprobe: FAIL: %s err=%d errno=%d\n", msg, err, errno);
}

static void update_peak(int value) {
    for (;;) {
        int old = __atomic_load_n(&reader_peak, __ATOMIC_SEQ_CST);
        if (value <= old) { return; }
        if (__atomic_compare_exchange_n(&reader_peak, &old, value, 0,
                                        __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)) {
            return;
        }
    }
}

static void *reader_worker(void *arg) {
    (void)arg;
    if (sem_wait(&gate_sem) != 0) { return (void *)(intptr_t)-1; }
    int r = pthread_rwlock_rdlock(&rwlock);
    if (r != 0) { return (void *)(intptr_t)-10; }
    int active = __atomic_add_fetch(&active_readers, 1, __ATOMIC_SEQ_CST);
    update_peak(active);
    if (shared_value != 7) {
        __atomic_add_fetch(&reader_errors, 1, __ATOMIC_SEQ_CST);
    }
    if (sem_post(&inside_sem) != 0) {
        __atomic_add_fetch(&reader_errors, 1, __ATOMIC_SEQ_CST);
    }
    if (sem_wait(&release_sem) != 0) {
        __atomic_add_fetch(&reader_errors, 1, __ATOMIC_SEQ_CST);
    }
    __atomic_sub_fetch(&active_readers, 1, __ATOMIC_SEQ_CST);
    r = pthread_rwlock_unlock(&rwlock);
    if (r != 0) { return (void *)(intptr_t)-11; }
    if (sem_post(&done_sem) != 0) { return (void *)(intptr_t)-12; }
    return 0;
}

int main(void) {
    if (sem_init(&gate_sem, 0, 0) != 0 ||
        sem_init(&inside_sem, 0, 0) != 0 ||
        sem_init(&release_sem, 0, 0) != 0 ||
        sem_init(&done_sem, 0, 0) != 0) {
        fail("sem_init", 0);
        return 1;
    }

    errno = 0;
    if (sem_trywait(&gate_sem) != -1 || errno != EAGAIN) {
        fail("sem_trywait empty", 0);
        return 1;
    }
    if (sem_post(&gate_sem) != 0 || sem_wait(&gate_sem) != 0) {
        fail("sem post/wait", 0);
        return 1;
    }
    struct timespec now;
    if (clock_gettime(CLOCK_REALTIME, &now) != 0) {
        fail("clock_gettime", 0);
        return 1;
    }
    errno = 0;
    if (sem_timedwait(&gate_sem, &now) != -1 || errno != ETIMEDOUT) {
        fail("sem_timedwait timeout", 0);
        return 1;
    }
    printf("threadsyncprobe: semaphore gate OK\n");

    pthread_rwlockattr_t rwattr;
    if (pthread_rwlockattr_init(&rwattr) != 0 ||
        pthread_rwlockattr_setpshared(&rwattr, 0) != 0 ||
        pthread_rwlockattr_destroy(&rwattr) != 0) {
        fail("rwlock attr", 0);
        return 1;
    }

    int r = pthread_rwlock_wrlock(&rwlock);
    if (r != 0) { fail("wrlock", r); return 1; }
    shared_value = 7;
    r = pthread_rwlock_tryrdlock(&rwlock);
    if (r != EBUSY) { fail("tryrdlock while writer", r); return 1; }
    r = pthread_rwlock_trywrlock(&rwlock);
    if (r != EBUSY) { fail("trywrlock while writer", r); return 1; }
    r = pthread_rwlock_unlock(&rwlock);
    if (r != 0) { fail("writer unlock", r); return 1; }
    printf("threadsyncprobe: rwlock writer exclusion OK\n");

    pthread_t readers[2];
    if (pthread_create(&readers[0], 0, reader_worker, 0) != 0 ||
        pthread_create(&readers[1], 0, reader_worker, 0) != 0) {
        fail("pthread_create readers", 0);
        return 1;
    }
    if (sem_post(&gate_sem) != 0 || sem_post(&gate_sem) != 0) {
        fail("reader gate post", 0);
        return 1;
    }
    if (sem_wait(&inside_sem) != 0 || sem_wait(&inside_sem) != 0) {
        fail("reader inside wait", 0);
        return 1;
    }
    if (__atomic_load_n(&reader_peak, __ATOMIC_SEQ_CST) != 2 ||
        __atomic_load_n(&active_readers, __ATOMIC_SEQ_CST) != 2) {
        fail("reader concurrency", 0);
        return 1;
    }
    if (sem_post(&release_sem) != 0 || sem_post(&release_sem) != 0) {
        fail("reader release", 0);
        return 1;
    }
    if (sem_wait(&done_sem) != 0 || sem_wait(&done_sem) != 0) {
        fail("reader done", 0);
        return 1;
    }
    void *ret0 = 0;
    void *ret1 = 0;
    if (pthread_join(readers[0], &ret0) != 0 || pthread_join(readers[1], &ret1) != 0) {
        fail("reader join", 0);
        return 1;
    }
    if (ret0 != 0 || ret1 != 0 || __atomic_load_n(&reader_errors, __ATOMIC_SEQ_CST) != 0) {
        fail("reader result", 0);
        return 1;
    }
    printf("threadsyncprobe: rwlock readers OK\n");

    int sem_value = -1;
    if (sem_getvalue(&gate_sem, &sem_value) != 0 || sem_value != 0) {
        fail("sem_getvalue", 0);
        return 1;
    }
    if (pthread_rwlock_destroy(&rwlock) != 0 ||
        sem_destroy(&gate_sem) != 0 ||
        sem_destroy(&inside_sem) != 0 ||
        sem_destroy(&release_sem) != 0 ||
        sem_destroy(&done_sem) != 0) {
        fail("cleanup", 0);
        return 1;
    }

    printf("THREADSYNCPROBE-OK\n");
    return 0;
}
