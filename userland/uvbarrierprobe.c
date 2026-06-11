// uvbarrierprobe.c - C/newlib pthread barrier proof for libuv's native path.

#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>

static pthread_barrier_t barrier;
static int phase1_pre;
static int phase1_post;
static int phase2_pre;
static int phase2_post;
static int serial_count;
static int worker_errors;

static void fail(const char *label, int detail) {
    printf("uvbarrierprobe: FAIL: %s detail=%d errno=%d\n", label, detail, errno);
}

static int wait_phase(const char *label, int *pre, int *post) {
    int arrived = __atomic_add_fetch(pre, 1, __ATOMIC_SEQ_CST);
    int r = pthread_barrier_wait(&barrier);
    if (r == PTHREAD_BARRIER_SERIAL_THREAD) {
        __atomic_add_fetch(&serial_count, 1, __ATOMIC_SEQ_CST);
    } else if (r != 0) {
        fail(label, r);
        __atomic_add_fetch(&worker_errors, 1, __ATOMIC_SEQ_CST);
        return 0;
    }
    if (__atomic_load_n(pre, __ATOMIC_SEQ_CST) != 3 || arrived < 1 || arrived > 3) {
        fail(label, arrived);
        __atomic_add_fetch(&worker_errors, 1, __ATOMIC_SEQ_CST);
        return 0;
    }
    __atomic_add_fetch(post, 1, __ATOMIC_SEQ_CST);
    return 1;
}

static void *worker_main(void *arg) {
    (void)arg;
    if (!wait_phase("phase1", &phase1_pre, &phase1_post)) {
        return (void *)(intptr_t)1;
    }
    if (!wait_phase("phase2", &phase2_pre, &phase2_post)) {
        return (void *)(intptr_t)2;
    }
    return 0;
}

int main(void) {
#ifndef PTHREAD_BARRIER_SERIAL_THREAD
    printf("uvbarrierprobe: missing PTHREAD_BARRIER_SERIAL_THREAD\n");
    return 1;
#endif

    pthread_barrierattr_t attr;
    if (pthread_barrierattr_init(&attr) != 0) {
        fail("barrierattr_init", 0);
        return 1;
    }
    int pshared = -1;
    if (pthread_barrierattr_getpshared(&attr, &pshared) != 0 || pshared != 0 ||
        pthread_barrierattr_setpshared(&attr, 0) != 0) {
        fail("barrierattr pshared", pshared);
        return 1;
    }
    pthread_barrier_t invalid_barrier;
    int r = pthread_barrier_init(&invalid_barrier, &attr, 0);
    if (r != EINVAL) {
        fail("zero-count barrier", r);
        return 1;
    }
    if (pthread_barrier_init(&barrier, &attr, 3) != 0 ||
        pthread_barrierattr_destroy(&attr) != 0) {
        fail("barrier init", 0);
        return 1;
    }
    printf("uvbarrierprobe: attr/native barrier shape OK\n");

    pthread_t workers[2];
    if (pthread_create(&workers[0], 0, worker_main, 0) != 0 ||
        pthread_create(&workers[1], 0, worker_main, 0) != 0) {
        fail("pthread_create", 0);
        return 1;
    }

    if (!wait_phase("main phase1", &phase1_pre, &phase1_post) ||
        !wait_phase("main phase2", &phase2_pre, &phase2_post)) {
        return 1;
    }

    void *ret0 = 0;
    void *ret1 = 0;
    if (pthread_join(workers[0], &ret0) != 0 || pthread_join(workers[1], &ret1) != 0) {
        fail("pthread_join", 0);
        return 1;
    }
    if (ret0 != 0 || ret1 != 0 || __atomic_load_n(&worker_errors, __ATOMIC_SEQ_CST) != 0) {
        fail("worker result", (int)(intptr_t)ret0 + (int)(intptr_t)ret1);
        return 1;
    }
    if (phase1_pre != 3 || phase1_post != 3 || phase2_pre != 3 || phase2_post != 3 ||
        serial_count != 2) {
        printf("uvbarrierprobe: counts p1=%d/%d p2=%d/%d serial=%d\n",
               phase1_pre, phase1_post, phase2_pre, phase2_post, serial_count);
        return 1;
    }
    if (pthread_barrier_destroy(&barrier) != 0) {
        fail("barrier_destroy", 0);
        return 1;
    }

    printf("uvbarrierprobe: reusable barrier phases OK\n");
    printf("UVBARRIERPROBE-OK\n");
    return 0;
}
