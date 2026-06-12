// uvthreadnameprobe.c - C/newlib pthread thread-name proof for libuv.

#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static pthread_mutex_t gate_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gate_cond = PTHREAD_COND_INITIALIZER;
static int worker_go;

static void fail(const char *label, int detail) {
    printf("uvthreadnameprobe: FAIL: %s detail=%d errno=%d\n", label, detail, errno);
}

static int expect_name(pthread_t thread, const char *want) {
    char name[16];
    int r = pthread_getname_np(thread, name, sizeof(name));
    if (r != 0) { return r; }
    return strcmp(name, want) == 0 ? 0 : EINVAL;
}

static void *worker(void *arg) {
    (void)arg;
    int r = pthread_mutex_lock(&gate_mutex);
    if (r != 0) { return (void *)(intptr_t)r; }
    while (!worker_go) {
        r = pthread_cond_wait(&gate_cond, &gate_mutex);
        if (r != 0) { return (void *)(intptr_t)r; }
    }
    r = pthread_mutex_unlock(&gate_mutex);
    if (r != 0) { return (void *)(intptr_t)r; }

    r = expect_name(pthread_self(), "main-set");
    if (r != 0) { return (void *)(intptr_t)r; }
    r = pthread_setname_np(pthread_self(), "worker-set");
    if (r != 0) { return (void *)(intptr_t)r; }
    r = expect_name(pthread_self(), "worker-set");
    return (void *)(intptr_t)r;
}

static int check_main_thread_name(void) {
    char name[16];
    int r = pthread_getname_np(pthread_self(), name, sizeof(name));
    if (r != 0 || name[0] != '\0') {
        fail("main default name", r);
        return 1;
    }
    r = pthread_setname_np(pthread_self(), "main-loop");
    if (r != 0) {
        fail("main setname", r);
        return 1;
    }
    r = expect_name(pthread_self(), "main-loop");
    if (r != 0) {
        fail("main getname", r);
        return 1;
    }
    printf("uvthreadnameprobe: main thread name OK\n");
    return 0;
}

static int check_name_bounds(void) {
    char small[4];
    int r = pthread_getname_np(pthread_self(), small, sizeof(small));
    if (r != ERANGE) {
        fail("small get buffer", r);
        return 1;
    }
    r = pthread_setname_np(pthread_self(), "0123456789abcde");
    if (r != 0) {
        fail("max setname", r);
        return 1;
    }
    r = pthread_setname_np(pthread_self(), "0123456789abcdef");
    if (r != ERANGE) {
        fail("too long setname", r);
        return 1;
    }
    r = pthread_getname_np((pthread_t)9999, small, sizeof(small));
    if (r != ESRCH) {
        fail("missing thread getname", r);
        return 1;
    }
    r = pthread_setname_np((pthread_t)9999, "missing");
    if (r != ESRCH) {
        fail("missing thread setname", r);
        return 1;
    }
    printf("uvthreadnameprobe: name bounds/errors OK\n");
    return 0;
}

static int check_worker_thread_name(void) {
    pthread_t thread;
    void *ret = 0;
    int r = pthread_create(&thread, 0, worker, 0);
    if (r != 0) {
        fail("create worker", r);
        return 1;
    }

    r = pthread_setname_np(thread, "main-set");
    if (r != 0) {
        fail("parent set worker name", r);
        return 1;
    }
    r = expect_name(thread, "main-set");
    if (r != 0) {
        fail("parent get worker name", r);
        return 1;
    }

    r = pthread_mutex_lock(&gate_mutex);
    if (r != 0) {
        fail("gate lock", r);
        return 1;
    }
    worker_go = 1;
    r = pthread_cond_signal(&gate_cond);
    if (r != 0) {
        fail("gate signal", r);
        return 1;
    }
    r = pthread_mutex_unlock(&gate_mutex);
    if (r != 0) {
        fail("gate unlock", r);
        return 1;
    }

    r = pthread_join(thread, &ret);
    if (r != 0 || (intptr_t)ret != 0) {
        fail("join worker", r != 0 ? r : (int)(intptr_t)ret);
        return 1;
    }
    char name[16];
    r = pthread_getname_np(thread, name, sizeof(name));
    if (r != ESRCH) {
        fail("joined thread name", r);
        return 1;
    }
    printf("uvthreadnameprobe: worker name exchange OK\n");
    return 0;
}

int main(void) {
    if (check_main_thread_name() != 0) { return 1; }
    if (check_name_bounds() != 0) { return 1; }
    if (check_worker_thread_name() != 0) { return 1; }

    printf("UVTHREADNAMEPROBE-OK\n");
    return 0;
}
