// uvsocketpairprobe.c - C/newlib socketpair proof for libuv local streams.

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static void fail(const char *label, int detail) {
    printf("uvsocketpairprobe: FAIL: %s detail=%d errno=%d\n", label, detail, errno);
}

static int check_status_flag(int fd, int mask, const char *label) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || (flags & mask) != mask) {
        fail(label, flags);
        return 0;
    }
    return 1;
}

static int check_fd_flag(int fd, int mask, const char *label) {
    int flags = fcntl(fd, F_GETFD, 0);
    if (flags < 0 || (flags & mask) != mask) {
        fail(label, flags);
        return 0;
    }
    return 1;
}

static int expect_poll(int fd, short events, short want, const char *label) {
    struct pollfd pfd;
    pfd.fd = fd;
    pfd.events = events;
    pfd.revents = 0;
    int r = poll(&pfd, 1, 1000);
    if (r != 1 || (pfd.revents & want) != want) {
        printf("uvsocketpairprobe: %s poll r=%d revents=0x%x want=0x%x errno=%d\n",
               label, r, pfd.revents, want, errno);
        return 0;
    }
    return 1;
}

int main(void) {
    int bad[2];
    errno = 0;
    if (socketpair(AF_INET, SOCK_STREAM, 0, bad) != -1 || errno != EAFNOSUPPORT) {
        fail("unsupported domain", errno);
        return 1;
    }

    int fds[2];
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0, fds) != 0) {
        fail("socketpair", 0);
        return 1;
    }
    if (!check_status_flag(fds[0], O_NONBLOCK, "fd0 nonblock") ||
        !check_status_flag(fds[1], O_NONBLOCK, "fd1 nonblock") ||
        !check_fd_flag(fds[0], FD_CLOEXEC, "fd0 cloexec") ||
        !check_fd_flag(fds[1], FD_CLOEXEC, "fd1 cloexec")) {
        return 1;
    }
    int type = 0;
    socklen_t type_len = sizeof(type);
    if (getsockopt(fds[0], SOL_SOCKET, SO_TYPE, &type, &type_len) != 0 ||
        type != SOCK_STREAM) {
        fail("getsockopt SO_TYPE", type);
        return 1;
    }
    printf("uvsocketpairprobe: flags and type OK\n");

    char c = 0;
    errno = 0;
    if (read(fds[0], &c, 1) != -1 || errno != EAGAIN) {
        fail("empty nonblocking read", errno);
        return 1;
    }

    if (!expect_poll(fds[0], POLLOUT, POLLOUT, "fd0 writable") ||
        write(fds[0], "a", 1) != 1 ||
        !expect_poll(fds[1], POLLIN, POLLIN, "fd1 readable") ||
        read(fds[1], &c, 1) != 1 || c != 'a') {
        fail("fd0 to fd1", c);
        return 1;
    }

    if (send(fds[1], "b", 1, MSG_DONTWAIT) != 1 ||
        !expect_poll(fds[0], POLLIN, POLLIN, "fd0 readable") ||
        recv(fds[0], &c, 1, MSG_DONTWAIT) != 1 || c != 'b') {
        fail("fd1 to fd0", c);
        return 1;
    }
    printf("uvsocketpairprobe: bidirectional IO OK\n");

    close(fds[1]);
    if (!expect_poll(fds[0], POLLIN | POLLOUT, POLLHUP | POLLERR, "peer close")) {
        return 1;
    }
    close(fds[0]);

    printf("uvsocketpairprobe: peer close readiness OK\n");
    printf("UVSOCKETPAIRPROBE-OK\n");
    return 0;
}
