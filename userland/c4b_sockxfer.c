// c4b_sockxfer.c — C4b socket-handle transfer smoke.
//
// The parent creates and binds a UDP socket after fork, moves that socket handle
// over a C4 endpoint, and the child receives/echoes a host datagram through the
// received fd. This proves endpoint handle transfer works for socket objects,
// not just files/pipes, without adding a new kernel ABI.

#include "lib/syscall.h"

#define AF_INET 2
#define SOCK_DGRAM 2
#define C4B_PORT 5566
#define ERR_BADFD (-9)

int puts_raw(const char *s);

struct udp_msg {
    unsigned long buf;
    unsigned int len;
    unsigned int ip;
    unsigned short port;
    unsigned short pad;
};

static int streq_n(const char *a, const char *b, int n) {
    for (int i = 0; i < n; i += 1) {
        if (a[i] != b[i]) { return 0; }
    }
    return 1;
}

static int udp_socket(void) {
    return (int)__syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
}

static int udp_bind(int fd, unsigned short port) {
    return (int)__syscall3(SYS_BIND, fd, port, 0);
}

static long udp_sendto(int fd, const void *buf, unsigned long len,
                       unsigned int ip, unsigned short port) {
    struct udp_msg m;
    m.buf = (unsigned long)buf;
    m.len = (unsigned int)len;
    m.ip = ip;
    m.port = port;
    m.pad = 0;
    return __syscall3(SYS_SENDTO, fd, (long)&m, 0);
}

static long udp_recvfrom(int fd, void *buf, unsigned long cap,
                         unsigned int *ip, unsigned short *port) {
    struct udp_msg m;
    m.buf = (unsigned long)buf;
    m.len = (unsigned int)cap;
    m.ip = 0;
    m.port = 0;
    m.pad = 0;
    long n = __syscall3(SYS_RECVFROM, fd, (long)&m, 0);
    if (n >= 0) {
        if (ip) { *ip = m.ip; }
        if (port) { *port = m.port; }
    }
    return n;
}

int main(void) {
    int ep[2];
    if (endpoint_create(ep) != 0) {
        puts_raw("c4b-sockxfer: endpoint_create failed\n");
        return 1;
    }

    int pid = fork();
    if (pid < 0) {
        puts_raw("c4b-sockxfer: fork failed\n");
        return 1;
    }

    if (pid == 0) {
        close(ep[0]);
        char ctrl[8];
        int sock = -1;
        long cn = ipc_recv(ep[1], ctrl, sizeof(ctrl), &sock);
        if (cn != 4 || !streq_n(ctrl, "SOCK", 4) || sock < 0) {
            puts_raw("c4b-sockxfer: child did not receive socket handle\n");
            return 1;
        }
        puts_raw("C4B-SOCKET-XFER-RECV\n");

        char buf[64];
        unsigned int src_ip = 0;
        unsigned short src_port = 0;
        long n = udp_recvfrom(sock, buf, sizeof(buf), &src_ip, &src_port);
        if (n != 8 || !streq_n(buf, "c4b-sock", 8)) {
            puts_raw("c4b-sockxfer: child recvfrom failed\n");
            return 1;
        }
        puts_raw("C4B-SOCKET-RECV-OK\n");

        long sent = udp_sendto(sock, buf, (unsigned long)n, src_ip, src_port);
        if (sent != n) {
            puts_raw("c4b-sockxfer: child echo failed\n");
            return 1;
        }
        puts_raw("C4B-SOCKET-ECHO-OK\n");
        close(sock);
        close(ep[1]);
        return 42;
    }

    close(ep[1]);
    int sock = udp_socket();
    if (sock < 0) {
        puts_raw("c4b-sockxfer: socket failed\n");
        return 1;
    }
    if (udp_bind(sock, C4B_PORT) != 0) {
        puts_raw("c4b-sockxfer: bind failed\n");
        close(sock);
        return 1;
    }
    puts_raw("c4b-sockxfer: listening on 5566\n");

    if (ipc_send(ep[0], "SOCK", 4, sock) != 0) {
        puts_raw("c4b-sockxfer: ipc_send socket failed\n");
        return 1;
    }

    char moved_probe;
    unsigned int moved_ip = 0;
    unsigned short moved_port = 0;
    long moved = udp_recvfrom(sock, &moved_probe, 1, &moved_ip, &moved_port);
    if (moved == ERR_BADFD) {
        puts_raw("C4B-SOCKET-MOVE-ONLY-OK err=-9\n");
    } else {
        puts_raw(moved >= 0 ? "C4B-SOCKET-MOVE-ONLY-LEAK\n"
                            : "C4B-SOCKET-MOVE-ONLY-FAIL\n");
        return 1;
    }

    int status = 0;
    int waited = waitpid(pid, &status, 0);
    if (waited != pid || ((status >> 8) & 0xff) != 42) {
        puts_raw("c4b-sockxfer: child wait failed\n");
        return 1;
    }
    close(ep[0]);
    puts_raw("C4b OK: endpoint IPC moved socket handle safely\n");
    return 0;
}
