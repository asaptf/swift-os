// uvthreadstackprobe.c - C/newlib thread stack sizing proof for libuv.

#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/resource.h>
#include <unistd.h>

static const size_t libuv_min_stack = 8192;

static void fail(const char *label, long detail) {
    printf("uvthreadstackprobe: FAIL: %s detail=%ld errno=%d\n", label, detail, errno);
}

static size_t max_size(size_t a, size_t b) {
    return a > b ? a : b;
}

static size_t align_up(size_t value, size_t alignment) {
    return (value + alignment - 1) & ~(alignment - 1);
}

static size_t libuv_effective_min_stack(void) {
    size_t min = libuv_min_stack;
#ifdef PTHREAD_STACK_MIN
    min = max_size(min, (size_t)PTHREAD_STACK_MIN);
#endif
    return min;
}

static void *stack_worker(void *arg) {
    volatile uintptr_t scratch[64];
    uintptr_t seed = (uintptr_t)arg;
    for (size_t i = 0; i < sizeof(scratch) / sizeof(scratch[0]); i++) {
        scratch[i] = seed + i;
    }
    return (void *)(intptr_t)(scratch[3] - 3);
}

static int run_thread_with_stack(size_t stack_size, intptr_t token) {
    pthread_attr_t attr;
    pthread_t thread;
    void *ret = 0;
    size_t actual = 0;

    int r = pthread_attr_init(&attr);
    if (r != 0) {
        fail("pthread_attr_init", r);
        return 1;
    }

    r = pthread_attr_setstacksize(&attr, stack_size);
    if (r != 0) {
        fail("pthread_attr_setstacksize", r);
        return 1;
    }

    r = pthread_attr_getstacksize(&attr, &actual);
    if (r != 0 || actual != stack_size) {
        fail("pthread_attr_getstacksize", r != 0 ? r : (long)actual);
        return 1;
    }

    r = pthread_create(&thread, &attr, stack_worker, (void *)token);
    if (r != 0) {
        fail("pthread_create", r);
        return 1;
    }

    r = pthread_attr_destroy(&attr);
    if (r != 0) {
        fail("pthread_attr_destroy", r);
        return 1;
    }

    r = pthread_join(thread, &ret);
    if (r != 0 || (intptr_t)ret != token) {
        fail("pthread_join", r != 0 ? r : (long)(intptr_t)ret);
        return 1;
    }

    return 0;
}

static int check_limits_and_pagesize(size_t *page_out, size_t *stack_limit_out) {
    errno = 0;
    int page = getpagesize();
    if (page <= 0 || (page & (page - 1)) != 0) {
        fail("getpagesize", page);
        return 1;
    }

    struct rlimit lim;
    if (getrlimit(RLIMIT_STACK, &lim) != 0) {
        fail("getrlimit stack", errno);
        return 1;
    }

    size_t min_stack = libuv_effective_min_stack();
    if (lim.rlim_cur == RLIM_INFINITY ||
        lim.rlim_cur < (rlim_t)min_stack ||
        (lim.rlim_cur % (rlim_t)page) != 0) {
        fail("rlimit stack shape", (long)lim.rlim_cur);
        return 1;
    }
    size_t stack_limit = (size_t)lim.rlim_cur;

    errno = 0;
    if (getrlimit(RLIM_NLIMITS + 1, &lim) != -1 || errno != EINVAL) {
        fail("getrlimit invalid resource", errno);
        return 1;
    }

    *page_out = (size_t)page;
    *stack_limit_out = stack_limit;
    printf("uvthreadstackprobe: limits/pagesize OK\n");
    return 0;
}

static int check_attr_bounds(size_t page, size_t stack_limit) {
    pthread_attr_t attr;
    size_t actual = 0;
    size_t min_stack = libuv_effective_min_stack();
    size_t pthread_min_stack = 1;
#ifdef PTHREAD_STACK_MIN
    pthread_min_stack = (size_t)PTHREAD_STACK_MIN;
#endif

    int r = pthread_attr_init(&attr);
    if (r != 0) {
        fail("attr init", r);
        return 1;
    }

    if (pthread_min_stack > 0) {
        r = pthread_attr_setstacksize(&attr, pthread_min_stack - 1);
        if (r != EINVAL) {
            fail("too-small stack accepted", r);
            return 1;
        }
    }

    size_t rounded = align_up(page + 123, page);
    rounded = max_size(rounded, min_stack);
    r = pthread_attr_setstacksize(&attr, rounded);
    if (r != 0 ||
        pthread_attr_getstacksize(&attr, &actual) != 0 ||
        actual != rounded) {
        fail("rounded stack attr", r != 0 ? r : (long)actual);
        return 1;
    }

    r = pthread_attr_setstacksize(&attr, stack_limit);
    if (r != 0 ||
        pthread_attr_getstacksize(&attr, &actual) != 0 ||
        actual != stack_limit) {
        fail("rlimit stack attr", r != 0 ? r : (long)actual);
        return 1;
    }

    r = pthread_attr_destroy(&attr);
    if (r != 0) {
        fail("attr destroy", r);
        return 1;
    }

    printf("uvthreadstackprobe: attr stack bounds OK\n");
    return 0;
}

int main(void) {
    size_t page = 0;
    size_t stack_limit = 0;

    if (check_limits_and_pagesize(&page, &stack_limit) != 0) { return 1; }
    if (check_attr_bounds(page, stack_limit) != 0) { return 1; }

    size_t min_stack = libuv_effective_min_stack();
    size_t rounded = align_up(page + 123, page);
    rounded = max_size(rounded, min_stack);

    if (run_thread_with_stack(rounded, 101) != 0) { return 1; }
    printf("uvthreadstackprobe: rounded stack thread OK\n");

    if (run_thread_with_stack(stack_limit, 202) != 0) { return 1; }
    printf("uvthreadstackprobe: rlimit stack thread OK\n");

    printf("UVTHREADSTACKPROBE-OK\n");
    return 0;
}
