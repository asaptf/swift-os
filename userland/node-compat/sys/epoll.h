// SPDX-License-Identifier: Apache-2.0
// sys/epoll.h - epoll surface for the Node.js/libuv linux masquerade.
//
// SwiftOS has no epoll; these declarations let libuv's linux backend compile,
// and the companion implementation emulates epoll over poll()/eventfd. The
// flag values are internally consistent for that emulation (they need not
// match Linux's ABI since nothing crosses a Linux syscall boundary).
#ifndef _SWOS_NODE_COMPAT_SYS_EPOLL_H
#define _SWOS_NODE_COMPAT_SYS_EPOLL_H

#include <stdint.h>
#include <signal.h>

typedef union epoll_data {
    void     *ptr;
    int       fd;
    uint32_t  u32;
    uint64_t  u64;
} epoll_data_t;

struct epoll_event {
    uint32_t     events;
    epoll_data_t data;
};

/* Event flags. */
#define EPOLLIN      0x0001
#define EPOLLPRI     0x0002
#define EPOLLOUT     0x0004
#define EPOLLERR     0x0008
#define EPOLLHUP     0x0010
#define EPOLLRDHUP   0x2000
#define EPOLLWAKEUP  (1u << 29)
#define EPOLLONESHOT (1u << 30)
#define EPOLLET      (1u << 31)

/* epoll_ctl ops. */
#define EPOLL_CTL_ADD 1
#define EPOLL_CTL_DEL 2
#define EPOLL_CTL_MOD 3

/* epoll_create1 flags. */
#define EPOLL_CLOEXEC 02000000

int epoll_create1(int flags);
int epoll_ctl(int epfd, int op, int fd, struct epoll_event *event);
int epoll_wait(int epfd, struct epoll_event *events, int maxevents, int timeout);
int epoll_pwait(int epfd, struct epoll_event *events, int maxevents,
                int timeout, const sigset_t *sigmask);

#endif /* _SWOS_NODE_COMPAT_SYS_EPOLL_H */
