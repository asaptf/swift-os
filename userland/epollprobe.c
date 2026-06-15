// SPDX-License-Identifier: Apache-2.0
// epollprobe.c - runtime test for the SwiftOS epoll-over-poll emulation
// (userland/node-compat/node_compat.c) that the Node.js/libuv masquerade relies
// on. SwiftOS has poll + eventfd + futex but no epoll, so libuv's linux backend
// runs on an epoll API emulated over poll(). This probe exercises that API end
// to end: create, register, idle-timeout, readiness, and delete.

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>

static int fail(const char *msg) {
    printf("epollprobe: FAIL %s\n", msg);
    return 1;
}

int main(void) {
    int ep = epoll_create1(EPOLL_CLOEXEC);
    if (ep < 0) return fail("epoll_create1");

    int efd = eventfd(0, 0);
    if (efd < 0) return fail("eventfd");

    struct epoll_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.events = EPOLLIN;
    ev.data.fd = efd;
    if (epoll_ctl(ep, EPOLL_CTL_ADD, efd, &ev) != 0) return fail("epoll_ctl ADD");

    /* Nothing signalled yet: a short wait must time out with zero events. */
    struct epoll_event out[4];
    int n = epoll_wait(ep, out, 4, 50);
    if (n != 0) return fail("expected idle timeout");
    printf("epollprobe: idle timeout OK\n");

    /* Signal the eventfd; the registered fd must become readable. */
    uint64_t one = 1;
    if (write(efd, &one, sizeof(one)) != (ssize_t)sizeof(one))
        return fail("eventfd write");

    n = epoll_wait(ep, out, 4, 1000);
    if (n != 1) return fail("expected one ready event");
    if (out[0].data.fd != efd) return fail("wrong data.fd");
    if (!(out[0].events & EPOLLIN)) return fail("missing EPOLLIN");
    printf("epollprobe: readable event OK\n");

    /* Drain and deregister; the fd must no longer be reported. */
    uint64_t drain = 0;
    (void)read(efd, &drain, sizeof(drain));
    if (epoll_ctl(ep, EPOLL_CTL_DEL, efd, NULL) != 0) return fail("epoll_ctl DEL");
    n = epoll_wait(ep, out, 4, 50);
    if (n != 0) return fail("expected no events after DEL");
    printf("epollprobe: ctl del OK\n");

    close(efd);
    close(ep);
    printf("EPOLLPROBE-OK\n");
    return 0;
}
