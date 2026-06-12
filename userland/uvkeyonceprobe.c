// uvkeyonceprobe.c - C/newlib libuv key/once/thread identity proof.

#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef pthread_key_t uv_key_t;
typedef pthread_once_t uv_once_t;
typedef pthread_t uv_thread_t;
typedef void (*uv_thread_cb)(void *arg);

#define UV_ONCE_INIT PTHREAD_ONCE_INIT

static uv_once_t once = UV_ONCE_INIT;
static uv_key_t key;
static uv_thread_t main_thread;
static pthread_mutex_t detached_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t detached_cond = PTHREAD_COND_INITIALIZER;
static int once_count;
static int worker_ok[2];
static int worker_value[2] = { 41, 42 };
static int detached_done;
static int detached_ok;

static void fail(const char *label, int detail) {
    printf("uvkeyonceprobe: FAIL: %s detail=%d errno=%d\n", label, detail, errno);
}

static void uv_once(uv_once_t *guard, void (*callback)(void)) {
    if (pthread_once(guard, callback) != 0) {
        abort();
    }
}

static int uv_key_create(uv_key_t *out_key) {
    return pthread_key_create(out_key, 0);
}

static void uv_key_delete(uv_key_t *delete_key) {
    if (pthread_key_delete(*delete_key) != 0) {
        abort();
    }
}

static void *uv_key_get(uv_key_t *get_key) {
    return pthread_getspecific(*get_key);
}

static void uv_key_set(uv_key_t *set_key, void *value) {
    if (pthread_setspecific(*set_key, value) != 0) {
        abort();
    }
}

static uv_thread_t uv_thread_self(void) {
    return pthread_self();
}

static int uv_thread_equal(const uv_thread_t *a, const uv_thread_t *b) {
    return pthread_equal(*a, *b);
}

static int uv_thread_create(uv_thread_t *tid, uv_thread_cb entry, void *arg) {
    union {
        void (*in)(void *);
        void *(*out)(void *);
    } f;
    f.in = entry;
    return pthread_create(tid, 0, f.out, arg);
}

static int uv_thread_join(uv_thread_t *tid) {
    return pthread_join(*tid, 0);
}

static int uv_thread_detach(uv_thread_t *tid) {
    return pthread_detach(*tid);
}

static void init_once(void) {
    once_count++;
}

static void joined_worker(void *arg) {
    int id = (int)(intptr_t)arg;
    uv_once(&once, init_once);
    uv_once(&once, init_once);

    if (uv_key_get(&key) != 0) {
        worker_ok[id] = -1;
        return;
    }
    uv_key_set(&key, &worker_value[id]);
    if (uv_key_get(&key) != &worker_value[id]) {
        worker_ok[id] = -2;
        return;
    }

    uv_thread_t self = uv_thread_self();
    if (uv_thread_equal(&self, &main_thread)) {
        worker_ok[id] = -3;
        return;
    }
    worker_ok[id] = 1;
}

static void detached_worker(void *arg) {
    (void)arg;
    uv_thread_t self = uv_thread_self();
    int ok = !uv_thread_equal(&self, &main_thread);

    pthread_mutex_lock(&detached_lock);
    detached_ok = ok;
    detached_done = 1;
    pthread_cond_signal(&detached_cond);
    pthread_mutex_unlock(&detached_lock);
}

static int run_joined_threads(void) {
    uv_thread_t t0;
    uv_thread_t t1;

    uv_once(&once, init_once);
    if (uv_thread_create(&t0, joined_worker, (void *)(intptr_t)0) != 0 ||
        uv_thread_create(&t1, joined_worker, (void *)(intptr_t)1) != 0) {
        fail("uv_thread_create", 0);
        return 1;
    }
    if (uv_thread_join(&t0) != 0 || uv_thread_join(&t1) != 0) {
        fail("uv_thread_join", 0);
        return 1;
    }

    if (once_count != 1) {
        fail("uv_once", once_count);
        return 1;
    }
    printf("uvkeyonceprobe: once guard OK\n");

    if (worker_ok[0] != 1 || worker_ok[1] != 1) {
        fail("uv_key worker isolation", worker_ok[0] * 10 + worker_ok[1]);
        return 1;
    }
    int main_value = 99;
    uv_key_set(&key, &main_value);
    if (uv_key_get(&key) != &main_value) {
        fail("uv_key main value", 0);
        return 1;
    }
    printf("uvkeyonceprobe: key isolation OK\n");

    if (uv_thread_equal(&t0, &t1) || uv_thread_equal(&main_thread, &t0)) {
        fail("uv_thread_equal", 0);
        return 1;
    }
    printf("uvkeyonceprobe: thread identity and join OK\n");
    return 0;
}

static int run_detached_thread(void) {
    uv_thread_t tid;
    if (uv_thread_create(&tid, detached_worker, 0) != 0) {
        fail("uv_thread_create detached", 0);
        return 1;
    }
    if (uv_thread_detach(&tid) != 0) {
        fail("uv_thread_detach", 0);
        return 1;
    }

    pthread_mutex_lock(&detached_lock);
    while (!detached_done) {
        pthread_cond_wait(&detached_cond, &detached_lock);
    }
    pthread_mutex_unlock(&detached_lock);

    if (!detached_ok) {
        fail("detached worker identity", 0);
        return 1;
    }
    printf("uvkeyonceprobe: detach completion OK\n");
    return 0;
}

int main(void) {
    main_thread = uv_thread_self();
    if (uv_key_create(&key) != 0) {
        fail("uv_key_create", 0);
        return 1;
    }

    if (run_joined_threads() != 0) {
        return 1;
    }
    if (run_detached_thread() != 0) {
        return 1;
    }

    uv_key_delete(&key);
    printf("uvkeyonceprobe: key lifecycle OK\n");
    printf("UVKEYONCEPROBE-OK\n");
    return 0;
}
