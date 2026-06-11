// socketprobe.c - C/newlib socket and fd-flag compatibility proof.

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#ifndef O_CLOEXEC
#define O_CLOEXEC 0x40000
#endif

static int check_status_flag(int fd, int mask, const char *label) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || (flags & mask) != mask) {
        printf("socketprobe: %s status flags=0x%x errno=%d\n", label, flags, errno);
        return 0;
    }
    return 1;
}

static int check_fd_flag(int fd, int mask, const char *label) {
    int flags = fcntl(fd, F_GETFD, 0);
    if (flags < 0 || (flags & mask) != mask) {
        printf("socketprobe: %s fd flags=0x%x errno=%d\n", label, flags, errno);
        return 0;
    }
    return 1;
}

static int wait_readable(int fd, int timeout_ms, const char *label) {
    struct pollfd p;
    p.fd = fd;
    p.events = POLLIN;
    p.revents = 0;
    int r = poll(&p, 1, timeout_ms);
    if (r != 1 || (p.revents & POLLIN) == 0) {
        printf("socketprobe: %s poll r=%d revents=0x%x errno=%d\n",
               label, r, p.revents, errno);
        return 0;
    }
    return 1;
}

static int run_flags(void) {
    int fds[2];
    if (pipe2(fds, O_NONBLOCK | O_CLOEXEC) != 0) {
        printf("socketprobe: pipe2 failed errno=%d\n", errno);
        return 1;
    }
    if (!check_status_flag(fds[0], O_NONBLOCK, "pipe2 read end") ||
        !check_status_flag(fds[1], O_NONBLOCK, "pipe2 write end") ||
        !check_fd_flag(fds[0], FD_CLOEXEC, "pipe2 read end") ||
        !check_fd_flag(fds[1], FD_CLOEXEC, "pipe2 write end")) {
        return 1;
    }

    char c = 0;
    errno = 0;
    if (read(fds[0], &c, 1) != -1 || errno != EAGAIN) {
        printf("socketprobe: pipe2 empty read did not return EAGAIN errno=%d\n", errno);
        return 1;
    }
    if (write(fds[1], "p", 1) != 1 || !wait_readable(fds[0], 1000, "pipe2")) {
        printf("socketprobe: pipe2 write/readiness failed errno=%d\n", errno);
        return 1;
    }
    if (read(fds[0], &c, 1) != 1 || c != 'p') {
        printf("socketprobe: pipe2 readback failed c=%c errno=%d\n", c, errno);
        return 1;
    }
    close(fds[0]);
    close(fds[1]);
    printf("socketprobe: pipe2 flags OK\n");

    int s = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (s < 0) {
        printf("socketprobe: flagged socket failed errno=%d\n", errno);
        return 1;
    }
    if (!check_status_flag(s, O_NONBLOCK, "socket") ||
        !check_fd_flag(s, FD_CLOEXEC, "socket")) {
        return 1;
    }
    close(s);
    printf("socketprobe: socket flags OK\n");
    printf("SOCKETPROBE-FLAGS-OK\n");
    return 0;
}

static int make_addrinfo(const char *host, const char *port, int passive,
                         struct addrinfo **out) {
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    hints.ai_flags = AI_NUMERICSERV | (passive ? AI_PASSIVE : 0);
    int rc = getaddrinfo(host, port, &hints, out);
    if (rc != 0) {
        printf("socketprobe: getaddrinfo(%s,%s) failed %s\n",
               host ? host : "NULL", port, gai_strerror(rc));
        return 0;
    }
    return 1;
}

static int run_client(const char *host, const char *port) {
    struct addrinfo *ai = 0;
    if (!make_addrinfo(host, port, 0, &ai)) { return 1; }

    int fd = socket(ai->ai_family, ai->ai_socktype | SOCK_CLOEXEC, ai->ai_protocol);
    if (fd < 0) {
        printf("socketprobe: client socket failed errno=%d\n", errno);
        freeaddrinfo(ai);
        return 1;
    }
    if (!check_fd_flag(fd, FD_CLOEXEC, "client socket")) { return 1; }

    int one = 1;
    if (setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one)) != 0 ||
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one)) != 0) {
        printf("socketprobe: client setsockopt failed errno=%d\n", errno);
        return 1;
    }
    if (connect(fd, ai->ai_addr, ai->ai_addrlen) != 0) {
        printf("socketprobe: client connect failed errno=%d\n", errno);
        freeaddrinfo(ai);
        return 1;
    }
    freeaddrinfo(ai);
    printf("socketprobe: client connected OK\n");

    socklen_t optlen = sizeof(one);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &one, &optlen) != 0 || one != 0) {
        printf("socketprobe: client SO_ERROR=%d errno=%d\n", one, errno);
        return 1;
    }
    const char *msg = "ping-from-guest";
    if (send(fd, msg, strlen(msg), MSG_NOSIGNAL) != (long)strlen(msg)) {
        printf("socketprobe: client send failed errno=%d\n", errno);
        return 1;
    }
    if (!wait_readable(fd, 60000, "client reply")) { return 1; }
    char buf[128];
    long n = recv(fd, buf, sizeof(buf) - 1, MSG_DONTWAIT);
    if (n <= 0) {
        printf("socketprobe: client recv failed n=%ld errno=%d\n", n, errno);
        return 1;
    }
    buf[n] = 0;
    if (strcmp(buf, "socketprobe-client-ok") != 0) {
        printf("socketprobe: client unexpected reply '%s'\n", buf);
        return 1;
    }
    close(fd);
    printf("socketprobe: client exchange OK\n");
    printf("SOCKETPROBE-CLIENT-OK\n");
    return 0;
}

static int run_server(const char *port) {
    struct addrinfo *ai = 0;
    if (!make_addrinfo(0, port, 1, &ai)) { return 1; }

    int fd = socket(ai->ai_family, ai->ai_socktype | SOCK_NONBLOCK | SOCK_CLOEXEC,
                    ai->ai_protocol);
    if (fd < 0) {
        printf("socketprobe: server socket failed errno=%d\n", errno);
        freeaddrinfo(ai);
        return 1;
    }
    if (!check_status_flag(fd, O_NONBLOCK, "server socket") ||
        !check_fd_flag(fd, FD_CLOEXEC, "server socket")) {
        return 1;
    }
    int one = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)) != 0) {
        printf("socketprobe: server SO_REUSEADDR failed errno=%d\n", errno);
        return 1;
    }
    if (bind(fd, ai->ai_addr, ai->ai_addrlen) != 0 || listen(fd, 8) != 0) {
        printf("socketprobe: server bind/listen failed errno=%d\n", errno);
        freeaddrinfo(ai);
        return 1;
    }
    freeaddrinfo(ai);
    printf("socketprobe: server listening port=%s\n", port);
    fflush(stdout);

    if (!wait_readable(fd, 60000, "server listener")) { return 1; }
    struct sockaddr_storage peer;
    socklen_t peerlen = sizeof(peer);
    int cfd = accept4(fd, (struct sockaddr *)&peer, &peerlen,
                      SOCK_NONBLOCK | SOCK_CLOEXEC);
    if (cfd < 0) {
        printf("socketprobe: accept4 failed errno=%d\n", errno);
        return 1;
    }
    if (!check_status_flag(cfd, O_NONBLOCK, "accepted socket") ||
        !check_fd_flag(cfd, FD_CLOEXEC, "accepted socket")) {
        return 1;
    }
    printf("socketprobe: accept4 flags OK\n");

    if (!wait_readable(cfd, 30000, "server client data")) { return 1; }
    char buf[128];
    long n = recv(cfd, buf, sizeof(buf) - 1, MSG_DONTWAIT);
    if (n <= 0) {
        printf("socketprobe: server recv failed n=%ld errno=%d\n", n, errno);
        return 1;
    }
    buf[n] = 0;
    if (strcmp(buf, "ping-from-host") != 0) {
        printf("socketprobe: server unexpected request '%s'\n", buf);
        return 1;
    }
    const char *reply = "socketprobe-server-ok";
    if (send(cfd, reply, strlen(reply), MSG_NOSIGNAL) != (long)strlen(reply)) {
        printf("socketprobe: server send failed errno=%d\n", errno);
        return 1;
    }
    close(cfd);
    close(fd);
    printf("socketprobe: server exchange OK\n");
    printf("SOCKETPROBE-SERVER-OK\n");
    return 0;
}

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "flags") == 0) {
        return run_flags();
    }
    if (argc >= 4 && strcmp(argv[1], "client") == 0) {
        return run_client(argv[2], argv[3]);
    }
    if (argc >= 3 && strcmp(argv[1], "server") == 0) {
        return run_server(argv[2]);
    }
    printf("usage: socketprobe flags | client HOST PORT | server PORT\n");
    return 2;
}
