#ifndef _SWIFTOS_POLL_H
#define _SWIFTOS_POLL_H
struct pollfd { int fd; short events; short revents; };
typedef unsigned long nfds_t;
#define POLLIN  0x001
#define POLLPRI 0x002
#define POLLOUT 0x004
#define POLLERR 0x008
#define POLLHUP 0x010
#define POLLNVAL 0x020
int poll(struct pollfd *fds, nfds_t nfds, int timeout);
struct timespec;
int ppoll(struct pollfd *fds, nfds_t nfds, const struct timespec *tmo, const void *sigmask);
#endif
