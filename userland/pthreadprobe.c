// pthreadprobe.c - C/newlib pthread compatibility proof.

#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
static pthread_once_t once = PTHREAD_ONCE_INIT;
static pthread_key_t worker_key;
static int once_count;
static int done_count;
static int counter;

static void init_once(void) {
    once_count++;
}

static void *worker(void *arg) {
    intptr_t id = (intptr_t)arg;
    if (pthread_once(&once, init_once) != 0) {
        return (void *)(intptr_t)-10;
    }
    if (pthread_setspecific(worker_key, arg) != 0) {
        return (void *)(intptr_t)-11;
    }
    for (int i = 0; i < 1000; i++) {
        int r = pthread_mutex_lock(&lock);
        if (r != 0) { return (void *)(intptr_t)-20; }
        counter++;
        r = pthread_mutex_unlock(&lock);
        if (r != 0) { return (void *)(intptr_t)-21; }
    }
    int r = pthread_mutex_lock(&lock);
    if (r != 0) { return (void *)(intptr_t)-30; }
    done_count++;
    r = pthread_cond_signal(&cond);
    if (r != 0) { return (void *)(intptr_t)-31; }
    r = pthread_mutex_unlock(&lock);
    if (r != 0) { return (void *)(intptr_t)-32; }
    void *specific = pthread_getspecific(worker_key);
    return specific == arg ? (void *)(id + 100) : (void *)(intptr_t)-40;
}

int main(void) {
    pthread_attr_t attr;
    pthread_t t0, t1;
    void *r0 = 0;
    void *r1 = 0;

    if (pthread_key_create(&worker_key, 0) != 0) {
        printf("pthreadprobe: key create failed\n");
        return 1;
    }
    if (pthread_attr_init(&attr) != 0 ||
        pthread_attr_setstacksize(&attr, 32768) != 0 ||
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_JOINABLE) != 0) {
        printf("pthreadprobe: attr setup failed\n");
        return 1;
    }

    if (pthread_mutex_lock(&lock) != 0) {
        printf("pthreadprobe: initial lock failed\n");
        return 1;
    }
    int busy = pthread_mutex_trylock(&lock);
    if (busy != EBUSY) {
        printf("pthreadprobe: trylock expected EBUSY got %d\n", busy);
        return 1;
    }
    if (pthread_mutex_unlock(&lock) != 0) {
        printf("pthreadprobe: initial unlock failed\n");
        return 1;
    }
    printf("pthreadprobe: trylock busy OK\n");

    if (pthread_create(&t0, &attr, worker, (void *)(intptr_t)1) != 0 ||
        pthread_create(&t1, &attr, worker, (void *)(intptr_t)2) != 0) {
        printf("pthreadprobe: create failed\n");
        return 1;
    }
    if (pthread_equal(t0, t1) || pthread_equal(pthread_self(), t0)) {
        printf("pthreadprobe: pthread_equal/self failed\n");
        return 1;
    }

    if (pthread_mutex_lock(&lock) != 0) {
        printf("pthreadprobe: wait lock failed\n");
        return 1;
    }
    while (done_count < 2) {
        int r = pthread_cond_wait(&cond, &lock);
        if (r != 0) {
            printf("pthreadprobe: cond wait failed %d\n", r);
            return 1;
        }
    }
    if (pthread_mutex_unlock(&lock) != 0) {
        printf("pthreadprobe: wait unlock failed\n");
        return 1;
    }

    if (pthread_join(t0, &r0) != 0 || pthread_join(t1, &r1) != 0) {
        printf("pthreadprobe: join failed\n");
        return 1;
    }
    if ((intptr_t)r0 != 101 || (intptr_t)r1 != 102) {
        printf("pthreadprobe: return mismatch r0=%ld r1=%ld\n", (long)(intptr_t)r0, (long)(intptr_t)r1);
        return 1;
    }
    if (counter != 2000 || done_count != 2 || once_count != 1) {
        printf("pthreadprobe: counters bad counter=%d done=%d once=%d\n", counter, done_count, once_count);
        return 1;
    }
    if (pthread_key_delete(worker_key) != 0 ||
        pthread_attr_destroy(&attr) != 0 ||
        pthread_cond_destroy(&cond) != 0 ||
        pthread_mutex_destroy(&lock) != 0) {
        printf("pthreadprobe: cleanup failed\n");
        return 1;
    }

    printf("pthreadprobe: once=%d\n", once_count);
    printf("pthreadprobe: worker returns=%ld,%ld\n", (long)(intptr_t)r0, (long)(intptr_t)r1);
    printf("pthreadprobe: counter=%d\n", counter);
    printf("PTHREADPROBE-OK\n");
    return 0;
}
