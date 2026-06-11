// uvcondprobe.c - C/newlib timed condition-variable proof for libuv.

#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>

static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cond;
static int ready;
static int worker_error;

static void fail(const char *label, int detail) {
    printf("uvcondprobe: FAIL: %s detail=%d errno=%d\n", label, detail, errno);
}

static int deadline_after_ms(clockid_t clock_id, long ms, struct timespec *out) {
    if (clock_gettime(clock_id, out) != 0) { return -1; }
    out->tv_sec += ms / 1000;
    out->tv_nsec += (ms % 1000) * 1000000L;
    while (out->tv_nsec >= 1000000000L) {
        out->tv_sec++;
        out->tv_nsec -= 1000000000L;
    }
    return 0;
}

static void *signal_worker(void *arg) {
    (void)arg;
    struct timespec pause = { 0, 25000000L };
    (void)nanosleep(&pause, 0);
    int r = pthread_mutex_lock(&mutex);
    if (r != 0) { worker_error = r; return (void *)(intptr_t)1; }
    ready = 1;
    r = pthread_cond_signal(&cond);
    if (r != 0) { worker_error = r; }
    r = pthread_mutex_unlock(&mutex);
    if (r != 0 && worker_error == 0) { worker_error = r; }
    return worker_error ? (void *)(intptr_t)1 : 0;
}

int main(void) {
    pthread_condattr_t attr;
    if (pthread_condattr_init(&attr) != 0 ||
        pthread_condattr_setclock(&attr, CLOCK_MONOTONIC) != 0 ||
        pthread_cond_init(&cond, &attr) != 0 ||
        pthread_condattr_destroy(&attr) != 0) {
        fail("monotonic cond init", 0);
        return 1;
    }

    if (pthread_mutex_lock(&mutex) != 0) {
        fail("timeout lock", 0);
        return 1;
    }
    struct timespec deadline;
    if (deadline_after_ms(CLOCK_MONOTONIC, 20, &deadline) != 0) {
        fail("monotonic deadline", 0);
        return 1;
    }
    int r = pthread_cond_timedwait(&cond, &mutex, &deadline);
    if (r != ETIMEDOUT) {
        fail("monotonic timedwait timeout", r);
        return 1;
    }
    if (pthread_mutex_unlock(&mutex) != 0) {
        fail("timeout unlock", 0);
        return 1;
    }
    printf("uvcondprobe: monotonic timeout OK\n");

    if (pthread_cond_destroy(&cond) != 0 ||
        pthread_condattr_init(&attr) != 0 ||
        pthread_condattr_setclock(&attr, CLOCK_MONOTONIC) != 0 ||
        pthread_cond_init(&cond, &attr) != 0 ||
        pthread_condattr_destroy(&attr) != 0) {
        fail("signal cond init", 0);
        return 1;
    }

    ready = 0;
    worker_error = 0;
    pthread_t worker;
    if (pthread_create(&worker, 0, signal_worker, 0) != 0) {
        fail("pthread_create", 0);
        return 1;
    }
    if (pthread_mutex_lock(&mutex) != 0) {
        fail("signal lock", 0);
        return 1;
    }
    if (deadline_after_ms(CLOCK_MONOTONIC, 2000, &deadline) != 0) {
        fail("signal deadline", 0);
        return 1;
    }
    while (!ready) {
        r = pthread_cond_timedwait(&cond, &mutex, &deadline);
        if (r != 0) {
            fail("signal timedwait", r);
            return 1;
        }
    }
    if (pthread_mutex_unlock(&mutex) != 0) {
        fail("signal unlock", 0);
        return 1;
    }
    void *ret = 0;
    if (pthread_join(worker, &ret) != 0 || ret != 0 || worker_error != 0) {
        fail("worker join", worker_error);
        return 1;
    }
    printf("uvcondprobe: signal wake OK\n");

    if (pthread_cond_destroy(&cond) != 0) {
        fail("cond destroy", 0);
        return 1;
    }

    printf("UVCONDPROBE-OK\n");
    return 0;
}
