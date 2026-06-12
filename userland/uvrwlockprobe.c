// uvrwlockprobe.c - C/newlib pthread rwlock proof for libuv's uv_rwlock_* wrappers.

#include <errno.h>
#include <pthread.h>
#include <semaphore.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>

static pthread_rwlock_t rwlock;
static pthread_rwlock_t static_rwlock = PTHREAD_RWLOCK_INITIALIZER;
static sem_t inside_sem;
static sem_t release_sem;
static sem_t writer_started_sem;
static int active_readers;
static int reader_errors;
static int writer_entered;
static int writer_error;

static void fail(const char *label, int detail) {
    printf("uvrwlockprobe: FAIL: %s detail=%d errno=%d\n", label, detail, errno);
}

static void short_pause(void) {
    struct timespec pause = { 0, 25000000L };
    (void)nanosleep(&pause, 0);
}

static void *reader_worker(void *arg) {
    (void)arg;
    int r = pthread_rwlock_rdlock(&rwlock);
    if (r != 0) {
        __atomic_store_n(&reader_errors, r, __ATOMIC_SEQ_CST);
        (void)sem_post(&inside_sem);
        return (void *)(intptr_t)1;
    }
    __atomic_add_fetch(&active_readers, 1, __ATOMIC_SEQ_CST);
    if (sem_post(&inside_sem) != 0) {
        __atomic_store_n(&reader_errors, errno, __ATOMIC_SEQ_CST);
    }
    if (sem_wait(&release_sem) != 0) {
        __atomic_store_n(&reader_errors, errno, __ATOMIC_SEQ_CST);
    }
    __atomic_sub_fetch(&active_readers, 1, __ATOMIC_SEQ_CST);
    r = pthread_rwlock_unlock(&rwlock);
    if (r != 0) {
        __atomic_store_n(&reader_errors, r, __ATOMIC_SEQ_CST);
        return (void *)(intptr_t)1;
    }
    return 0;
}

static void *writer_worker(void *arg) {
    (void)arg;
    if (sem_post(&writer_started_sem) != 0) {
        writer_error = errno;
        return (void *)(intptr_t)1;
    }
    int r = pthread_rwlock_wrlock(&rwlock);
    if (r != 0) {
        writer_error = r;
        return (void *)(intptr_t)1;
    }
    __atomic_store_n(&writer_entered, 1, __ATOMIC_SEQ_CST);
    r = pthread_rwlock_unlock(&rwlock);
    if (r != 0) {
        writer_error = r;
        return (void *)(intptr_t)1;
    }
    return 0;
}

int main(void) {
    if (sem_init(&inside_sem, 0, 0) != 0 ||
        sem_init(&release_sem, 0, 0) != 0 ||
        sem_init(&writer_started_sem, 0, 0) != 0) {
        fail("sem_init", 0);
        return 1;
    }

    if (pthread_rwlock_rdlock(&static_rwlock) != 0 ||
        pthread_rwlock_unlock(&static_rwlock) != 0 ||
        pthread_rwlock_destroy(&static_rwlock) != 0) {
        fail("static initializer", 0);
        return 1;
    }

    pthread_rwlockattr_t attr;
    int pshared = -1;
    if (pthread_rwlockattr_init(&attr) != 0 ||
        pthread_rwlockattr_getpshared(&attr, &pshared) != 0 ||
        pshared != 0 ||
        pthread_rwlockattr_setpshared(&attr, 0) != 0 ||
        pthread_rwlock_init(&rwlock, &attr) != 0 ||
        pthread_rwlockattr_destroy(&attr) != 0) {
        fail("attr/init path", pshared);
        return 1;
    }
    printf("uvrwlockprobe: attr/init path OK\n");

    int r = pthread_rwlock_wrlock(&rwlock);
    if (r != 0) {
        fail("wrlock", r);
        return 1;
    }
    r = pthread_rwlock_tryrdlock(&rwlock);
    if (r != EBUSY) {
        fail("tryrdlock while writer", r);
        return 1;
    }
    r = pthread_rwlock_trywrlock(&rwlock);
    if (r != EBUSY) {
        fail("trywrlock while writer", r);
        return 1;
    }
    r = pthread_rwlock_unlock(&rwlock);
    if (r != 0) {
        fail("writer unlock", r);
        return 1;
    }
    printf("uvrwlockprobe: writer exclusion OK\n");

    pthread_t readers[2];
    active_readers = 0;
    reader_errors = 0;
    if (pthread_create(&readers[0], 0, reader_worker, 0) != 0 ||
        pthread_create(&readers[1], 0, reader_worker, 0) != 0) {
        fail("reader create", 0);
        return 1;
    }
    if (sem_wait(&inside_sem) != 0 || sem_wait(&inside_sem) != 0) {
        fail("reader inside wait", 0);
        return 1;
    }
    if (__atomic_load_n(&reader_errors, __ATOMIC_SEQ_CST) != 0 ||
        __atomic_load_n(&active_readers, __ATOMIC_SEQ_CST) != 2) {
        fail("reader concurrency", active_readers);
        return 1;
    }
    r = pthread_rwlock_trywrlock(&rwlock);
    if (r != EBUSY) {
        fail("trywrlock while readers", r);
        return 1;
    }
    if (sem_post(&release_sem) != 0 || sem_post(&release_sem) != 0) {
        fail("reader release", 0);
        return 1;
    }
    void *ret0 = 0;
    void *ret1 = 0;
    if (pthread_join(readers[0], &ret0) != 0 ||
        pthread_join(readers[1], &ret1) != 0 ||
        ret0 != 0 || ret1 != 0 ||
        __atomic_load_n(&reader_errors, __ATOMIC_SEQ_CST) != 0) {
        fail("reader join", reader_errors);
        return 1;
    }
    printf("uvrwlockprobe: concurrent readers OK\n");

    writer_entered = 0;
    writer_error = 0;
    if (pthread_rwlock_rdlock(&rwlock) != 0) {
        fail("reader hold for writer", 0);
        return 1;
    }
    pthread_t writer;
    if (pthread_create(&writer, 0, writer_worker, 0) != 0) {
        fail("writer create", 0);
        return 1;
    }
    if (sem_wait(&writer_started_sem) != 0) {
        fail("writer start wait", 0);
        return 1;
    }
    short_pause();
    if (__atomic_load_n(&writer_entered, __ATOMIC_SEQ_CST) != 0) {
        fail("writer entered too early", writer_entered);
        return 1;
    }
    if (pthread_rwlock_unlock(&rwlock) != 0) {
        fail("release reader hold", 0);
        return 1;
    }
    void *writer_ret = 0;
    if (pthread_join(writer, &writer_ret) != 0 ||
        writer_ret != 0 ||
        writer_error != 0 ||
        __atomic_load_n(&writer_entered, __ATOMIC_SEQ_CST) != 1) {
        fail("writer wake", writer_error);
        return 1;
    }
    printf("uvrwlockprobe: writer wait/release OK\n");

    if (pthread_rwlock_destroy(&rwlock) != 0 ||
        sem_destroy(&inside_sem) != 0 ||
        sem_destroy(&release_sem) != 0 ||
        sem_destroy(&writer_started_sem) != 0) {
        fail("cleanup", 0);
        return 1;
    }

    printf("UVRWLOCKPROBE-OK\n");
    return 0;
}
