// uvsemprobe.c - C/newlib semaphore proof for libuv's uv_sem_* wrappers.

#include <errno.h>
#include <pthread.h>
#include <semaphore.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>

static sem_t sem;
static int worker_value;
static int worker_error;

static void fail(const char *label, int detail) {
    printf("uvsemprobe: FAIL: %s detail=%d errno=%d\n", label, detail, errno);
}

static int deadline_after_ms(long ms, struct timespec *out) {
    if (clock_gettime(CLOCK_REALTIME, out) != 0) { return -1; }
    out->tv_sec += ms / 1000;
    out->tv_nsec += (ms % 1000) * 1000000L;
    while (out->tv_nsec >= 1000000000L) {
        out->tv_sec++;
        out->tv_nsec -= 1000000000L;
    }
    return 0;
}

static void *post_worker(void *arg) {
    (void)arg;
    struct timespec pause = { 0, 25000000L };
    (void)nanosleep(&pause, 0);
    __atomic_store_n(&worker_value, 41, __ATOMIC_SEQ_CST);
    if (sem_post(&sem) != 0) {
        worker_error = errno;
        return (void *)(intptr_t)1;
    }
    return 0;
}

int main(void) {
    errno = 0;
    if (sem_init(&sem, 1, 0) != -1 || errno != EINVAL) {
        fail("process-shared rejected", errno);
        return 1;
    }

    if (sem_init(&sem, 0, 1) != 0) {
        fail("sem_init one", 0);
        return 1;
    }
    int value = -1;
    if (sem_getvalue(&sem, &value) != 0 || value != 1) {
        fail("initial getvalue", value);
        return 1;
    }
    if (sem_wait(&sem) != 0) {
        fail("immediate wait", 0);
        return 1;
    }
    if (sem_getvalue(&sem, &value) != 0 || value != 0) {
        fail("post-wait getvalue", value);
        return 1;
    }
    errno = 0;
    if (sem_trywait(&sem) != -1 || errno != EAGAIN) {
        fail("empty trywait", errno);
        return 1;
    }
    if (sem_destroy(&sem) != 0) {
        fail("destroy first", 0);
        return 1;
    }
    printf("uvsemprobe: init/trywait value path OK\n");

    if (sem_init(&sem, 0, 0) != 0) {
        fail("sem_init timeout", 0);
        return 1;
    }
    struct timespec deadline;
    if (deadline_after_ms(20, &deadline) != 0) {
        fail("deadline", 0);
        return 1;
    }
    errno = 0;
    if (sem_timedwait(&sem, &deadline) != -1 || errno != ETIMEDOUT) {
        fail("timedwait timeout", errno);
        return 1;
    }
    if (sem_destroy(&sem) != 0) {
        fail("destroy timeout", 0);
        return 1;
    }
    printf("uvsemprobe: timed wait timeout OK\n");

    if (sem_init(&sem, 0, 0) != 0) {
        fail("sem_init wake", 0);
        return 1;
    }
    pthread_t worker;
    worker_value = 0;
    worker_error = 0;
    if (pthread_create(&worker, 0, post_worker, 0) != 0) {
        fail("pthread_create", 0);
        return 1;
    }
    if (sem_wait(&sem) != 0) {
        fail("cross-thread wait", 0);
        return 1;
    }
    void *ret = 0;
    if (pthread_join(worker, &ret) != 0 || ret != 0 || worker_error != 0) {
        fail("worker join", worker_error);
        return 1;
    }
    if (__atomic_load_n(&worker_value, __ATOMIC_SEQ_CST) != 41) {
        fail("worker value", worker_value);
        return 1;
    }
    if (sem_destroy(&sem) != 0) {
        fail("destroy wake", 0);
        return 1;
    }
    printf("uvsemprobe: cross-thread post wake OK\n");

    if (sem_init(&sem, 0, 0) != 0 ||
        sem_post(&sem) != 0 ||
        sem_post(&sem) != 0 ||
        sem_getvalue(&sem, &value) != 0 || value != 2 ||
        sem_wait(&sem) != 0 ||
        sem_wait(&sem) != 0) {
        fail("counting post/wait", value);
        return 1;
    }
    errno = 0;
    if (sem_trywait(&sem) != -1 || errno != EAGAIN) {
        fail("counting drained", errno);
        return 1;
    }
    if (sem_destroy(&sem) != 0) {
        fail("destroy counting", 0);
        return 1;
    }
    printf("uvsemprobe: counting post/wait OK\n");

    if (sem_init(&sem, 0, SEM_VALUE_MAX) != 0) {
        fail("sem_init max", 0);
        return 1;
    }
    errno = 0;
    if (sem_post(&sem) != -1 || errno != EOVERFLOW) {
        fail("overflow post", errno);
        return 1;
    }
    if (sem_destroy(&sem) != 0) {
        fail("destroy max", 0);
        return 1;
    }
    printf("uvsemprobe: overflow guard OK\n");

    printf("UVSEMPROBE-OK\n");
    return 0;
}
