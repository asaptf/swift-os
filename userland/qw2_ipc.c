// SPDX-License-Identifier: Apache-2.0
// qw2_ipc.c — QW2 blocking IPC acceptance fixture.
//
// Scenario 1 (recv parks, sender wakes): parent creates an endpoint, forks a
// child. The child prints QW2-RECV-PARKED and calls ipc_recv on the empty
// endpoint — it must block until the parent sends. The parent sleeps ~200 ms
// (enough for the child to park), sends "hello" (5 bytes), and the child
// receives and prints QW2-RECV-OK 5.
//
// Scenario 2 (EOF wake): parent creates a second endpoint, forks another
// child. The child closes its own copy of the send end (so only the parent
// holds it), then parks on ipc_recv. The parent closes the send end; sendRefs
// reaches 0 and the parked receiver wakes with errPipe (-32), which the child
// reports as QW2-EOF-OK.
//
// Emitting QW2 OK at the end signals full acceptance.

#include "lib/syscall.h"

int puts_raw(const char *s);

static void sleep_100ms(void) {
    // nanosleep(0 s, 100_000_000 ns) — uses the kernel timer, yields the CPU.
    __syscall3(SYS_NANOSLEEP, 0, 100000000, 0);
}

// Write a decimal integer to buf (null-terminated), return length.
static int fmt_int(int n, char *buf) {
    if (n == 0) { buf[0] = '0'; buf[1] = '\0'; return 1; }
    char tmp[12];
    int len = 0;
    while (n > 0) { tmp[len++] = (char)('0' + n % 10); n /= 10; }
    for (int i = 0; i < len; i++) buf[i] = tmp[len - 1 - i];
    buf[len] = '\0';
    return len;
}

int main(void) {
    // ---- Scenario 1: child parks on recv, parent sends after delay ----------
    int ep[2];
    if (endpoint_create(ep) != 0) {
        puts_raw("qw2-ipc: endpoint_create failed\n");
        return 1;
    }

    int child1 = fork();
    if (child1 < 0) {
        puts_raw("qw2-ipc: fork failed\n");
        return 1;
    }

    if (child1 == 0) {
        char buf[64];
        int hfd = -1;
        // Print the marker BEFORE the blocking call so the test can observe it.
        puts_raw("QW2-RECV-PARKED\n");
        long n = ipc_recv(ep[1], buf, sizeof(buf), &hfd);
        if (n < 0) {
            puts_raw("qw2-ipc: ipc_recv failed\n");
            return 1;
        }
        char nbuf[16];
        fmt_int((int)n, nbuf);
        puts_raw("QW2-RECV-OK ");
        puts_raw(nbuf);
        puts_raw("\n");
        return 0;
    }

    // Parent: sleep long enough for the child to reach ipc_recv and park.
    sleep_100ms();
    sleep_100ms();
    const char msg[] = "hello";
    if (ipc_send(ep[0], msg, 5, -1) != 0) {
        puts_raw("qw2-ipc: ipc_send failed\n");
        return 1;
    }
    int st1 = 0;
    waitpid(child1, &st1, 0);

    // ---- Scenario 2: child parks on recv, parent closes send → EOF ----------
    int ep2[2];
    if (endpoint_create(ep2) != 0) {
        puts_raw("qw2-ipc: endpoint_create 2 failed\n");
        return 1;
    }

    int child2 = fork();
    if (child2 < 0) {
        puts_raw("qw2-ipc: fork 2 failed\n");
        return 1;
    }

    if (child2 == 0) {
        // Child: drop the send end so only the parent holds it; then park.
        // Once the parent closes ep2[0], sendRefs reaches 0 and the receiver
        // is woken with errPipe.
        close(ep2[0]);
        char buf2[64];
        int hfd2 = -1;
        long n = ipc_recv(ep2[1], buf2, sizeof(buf2), &hfd2);
        // errPipe = -32 (kernel/vfs/vfs.swift errPipe constant)
        if (n == -32) {
            puts_raw("QW2-EOF-OK\n");
        } else {
            puts_raw("qw2-ipc: expected errPipe (-32)\n");
            return 1;
        }
        return 0;
    }

    // Parent: give child2 time to close ep2[0] and park, then close the send
    // end — this drops sendRefs to 0 and wakes the parked receiver.
    sleep_100ms();
    sleep_100ms();
    close(ep2[0]);

    int st2 = 0;
    waitpid(child2, &st2, 0);

    puts_raw("QW2 OK\n");
    return 0;
}
