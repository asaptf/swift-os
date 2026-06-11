// uvwakeprobe.c - C/newlib libuv-style async wake proof for SwiftOS.

#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/eventfd.h>
#include <time.h>
#include <unistd.h>

static int wake_fd = -1;

static void fail(const char *label, int detail) {
    printf("uvwakeprobe: FAIL: %s detail=%d errno=%d\n", label, detail, errno);
}

static void *wake_worker(void *arg) {
    (void)arg;
    struct timespec delay = { 0, 20 * 1000 * 1000 };
    if (nanosleep(&delay, 0) != 0) {
        return (void *)(intptr_t)-1;
    }
    if (eventfd_write(wake_fd, 3) != 0) {
        return (void *)(intptr_t)-2;
    }
    return 0;
}

int main(void) {
    wake_fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    if (wake_fd < 0) {
        fail("eventfd", wake_fd);
        return 1;
    }

    pthread_t worker;
    int r = pthread_create(&worker, 0, wake_worker, 0);
    if (r != 0) {
        fail("pthread_create", r);
        return 1;
    }

    struct pollfd pfd;
    pfd.fd = wake_fd;
    pfd.events = POLLIN;
    pfd.revents = 0;
    r = poll(&pfd, 1, 1000);
    if (r != 1 || (pfd.revents & POLLIN) == 0) {
        fail("poll wake", r);
        printf("uvwakeprobe: poll wake revents=0x%x\n", pfd.revents);
        return 1;
    }

    eventfd_t value = 0;
    if (eventfd_read(wake_fd, &value) != 0 || value != 3) {
        fail("eventfd_read", (int)value);
        return 1;
    }

    void *worker_result = 0;
    r = pthread_join(worker, &worker_result);
    if (r != 0 || worker_result != 0) {
        fail("pthread_join", r);
        printf("uvwakeprobe: worker_result=%ld\n", (long)(intptr_t)worker_result);
        return 1;
    }
    printf("uvwakeprobe: cross-thread eventfd wake OK\n");

    pfd.revents = 0;
    r = poll(&pfd, 1, 0);
    if (r != 0) {
        fail("drained poll", r);
        printf("uvwakeprobe: drained revents=0x%x\n", pfd.revents);
        return 1;
    }
    printf("uvwakeprobe: drained poll timeout OK\n");

    close(wake_fd);
    printf("UVWAKEPROBE-OK\n");
    return 0;
}
