// forkdemo.c — M8d process demo: eager-copy fork + waitpid.

#include "lib/syscall.h"
#include "lib/fs.h"

int puts_raw(const char *s);

static volatile int marker = 7;

static int streq(const char *a, const char *b) {
    int i = 0;
    while (a[i] != 0 && b[i] != 0) {
        if (a[i] != b[i]) { return 0; }
        i += 1;
    }
    return a[i] == 0 && b[i] == 0;
}

int main(void) {
    puts_raw("forkdemo: before fork\n");

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
        int rh = -1;
        long bn = ipc_recv(ep[1], buf, sizeof(buf) - 1, &rh);
        if (bn < 0) { puts_raw("forkdemo: ipc_recv failed\n"); return 1; }
        buf[bn] = 0;
        if (bn != 5 || !streq(buf, "PING\n")) {
            puts_raw("forkdemo: IPC byte message mismatch\n");
            return 1;
        }
        puts_raw("forkdemo: IPC-MSG-OK\n");
        if (rh < 0) { puts_raw("forkdemo: no handle transferred\n"); return 1; }
        long m = read(rh, buf, sizeof(buf) - 1);
        if (m <= 0) { puts_raw("forkdemo: transferred handle unreadable\n"); return 1; }
        puts_raw("forkdemo: IPC-XFER-OK\n");
        close(rh);
        return 42;
    }

    // C4b: send the child a byte message plus a handle it did not inherit — the
    // handle is opened after the fork — over the endpoint in one ipc_send.
    close(ep[1]);
    int xf = open("/etc/hostname", O_RDONLY);
    if (xf < 0 || ipc_send(ep[0], "PING\n", 5, xf) != 0) {
        puts_raw("forkdemo: ipc_send failed\n");
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
