// forkdemo.c — M8d process demo: eager-copy fork + waitpid.

#include "lib/syscall.h"
#include "lib/fs.h"

#define POLLIN  0x001
#define POLLOUT 0x004
#define POLLERR 0x008

struct pollfd {
    int fd;
    short events;
    short revents;
};

int puts_raw(const char *s);

static volatile int marker = 7;

static int poll(struct pollfd *fds, unsigned long nfds, int timeout) {
    return (int)__syscall3(SYS_POLL, (long)fds, (long)nfds, timeout);
}

static int streq(const char *a, const char *b) {
    int i = 0;
    while (a[i] != 0 && b[i] != 0) {
        if (a[i] != b[i]) { return 0; }
        i += 1;
    }
    return a[i] == 0 && b[i] == 0;
}

static int expect_poll_bit(int fd, short events, short want, int timeout,
                           const char *fail) {
    struct pollfd pf;
    pf.fd = fd;
    pf.events = events;
    pf.revents = 0;
    if (poll(&pf, 1, timeout) != 1 || (pf.revents & want) == 0) {
        puts_raw(fail);
        return 0;
    }
    return 1;
}

static int endpoint_closed_poll_checks(void) {
    int ep[2];
    if (endpoint_create(ep) != 0) {
        puts_raw("forkdemo: closed-poll endpoint_create failed\n");
        return 0;
    }
    close(ep[0]);
    if (!expect_poll_bit(ep[1], POLLIN, POLLIN, 0,
                         "forkdemo: recv poll after senders closed failed\n")) {
        close(ep[1]);
        return 0;
    }
    close(ep[1]);

    if (endpoint_create(ep) != 0) {
        puts_raw("forkdemo: err-poll endpoint_create failed\n");
        return 0;
    }
    close(ep[1]);
    if (!expect_poll_bit(ep[0], POLLOUT, POLLERR, 0,
                         "forkdemo: send poll after receiver closed failed\n")) {
        close(ep[0]);
        return 0;
    }
    close(ep[0]);
    puts_raw("forkdemo: IPC-POLL-CLOSED-OK\n");
    return 1;
}

int main(void) {
    puts_raw("forkdemo: before fork\n");

    if (!endpoint_closed_poll_checks()) {
        return 1;
    }

    char buf[32];
    if (chdir("/etc") != 0) {
        puts_raw("forkdemo: chdir failed\n");
        return 1;
    }
    int fd = open("hostname", O_RDONLY);
    if (fd < 0) {
        puts_raw("forkdemo: open inherited fd failed\n");
        return 1;
    }

    int ep[2];
    if (endpoint_create(ep) != 0) {
        puts_raw("forkdemo: endpoint_create failed\n");
        return 1;
    }

    int status = 0;
    int pid = fork();
    if (pid < 0) {
        puts_raw("forkdemo: fork failed\n");
        return 1;
    }

    if (pid == 0) {
        marker = 42;
        getcwd(buf, sizeof(buf));
        if (!streq(buf, "/etc")) {
            puts_raw("forkdemo: child cwd not inherited\n");
            return 1;
        }
        long n = read(fd, buf, sizeof(buf) - 1);
        if (n <= 0) {
            puts_raw("forkdemo: child fd not inherited\n");
            return 1;
        }
        buf[n] = 0;
        if (!streq(buf, "swiftos\n")) {
            puts_raw("forkdemo: child fd read mismatch\n");
            return 1;
        }
        puts_raw("forkdemo: child inherited cwd/fd\n");
        puts_raw("forkdemo: child sees private marker\n");
        // C4b: receive a byte message AND a handle the parent transfers over the IPC
        // endpoint — the handle is one the child never inherited (the parent opens it
        // after the fork). The bytes prove the payload arrived; reading the handle
        // proves the capability moved across the same message.
        close(ep[0]);
        if (!expect_poll_bit(ep[1], POLLIN, POLLIN, 1000,
                             "forkdemo: IPC pollin failed\n")) {
            return 1;
        }
        puts_raw("forkdemo: IPC-POLL-IN-OK\n");
        int rh = -1;
        long bn = ipc_recv(ep[1], buf, sizeof(buf) - 1, &rh);
        if (bn < 0) { puts_raw("forkdemo: ipc_recv failed\n"); return 1; }
        buf[bn] = 0;
        if (bn != 5 || !streq(buf, "PING\n")) {
            puts_raw("forkdemo: IPC byte message mismatch\n");
            return 1;
        }
        puts_raw("forkdemo: IPC-MSG-OK\n");
        puts_raw("C4A-BYTES-OK\n");
        if (rh < 0) { puts_raw("forkdemo: no handle transferred\n"); return 1; }
        long m = read(rh, buf, sizeof(buf) - 1);
        if (m <= 0) { puts_raw("forkdemo: transferred handle unreadable\n"); return 1; }
        puts_raw("forkdemo: IPC-XFER-OK\n");
        puts_raw("C4A-XFER-READ-OK\n");
        close(rh);
        return 42;
    }

    // C4b: send the child a byte message plus a handle it did not inherit — the
    // handle is opened after the fork — over the endpoint in one ipc_send.
    close(ep[1]);
    if (!expect_poll_bit(ep[0], POLLOUT, POLLOUT, 0,
                         "forkdemo: IPC pollout failed\n")) {
        return 1;
    }
    puts_raw("forkdemo: IPC-POLL-OUT-OK\n");
    int xf = open("/etc/hostname", O_RDONLY);
    if (xf < 0 || ipc_send(ep[0], "PING\n", 5, xf) != 0) {
        puts_raw("forkdemo: ipc_send failed\n");
        return 1;
    }
    char moved_probe;
    long moved = read(xf, &moved_probe, 1);
    if (moved == -9) {
        puts_raw("forkdemo: IPC-MOVE-ONLY-OK err=-9\n");
        puts_raw("C4A-XFER-MOVE-OK\n");
    } else {
        puts_raw(moved >= 0 ? "forkdemo: IPC-MOVE-ONLY-LEAK\n"
                            : "forkdemo: IPC-MOVE-ONLY-FAIL\n");
        return 1;
    }

    int waited = waitpid(pid, &status, 0);
    if (waited != pid || ((status >> 8) & 0xff) != 42) {
        puts_raw("forkdemo: waitpid failed\n");
        return 1;
    }
    if (marker != 7) {
        puts_raw("forkdemo: parent marker corrupted\n");
        return 1;
    }

    puts_raw("forkdemo: parent waited child\n");
    return 0;
}
