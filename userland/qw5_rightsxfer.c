// SPDX-License-Identifier: Apache-2.0
// qw5_rightsxfer.c — QW5 rights-intersection on IPC handle transfer smoke.
//
// The parent opens /dev/zero O_RDWR (a handle holding READ|WRITE|TRANSFER), then
// ipc_sends it over a C4 endpoint requesting only READ|TRANSFER — deliberately
// dropping WRITE. The kernel installs a fresh handle attenuated to held ∩
// requested, so the child receives READ|TRANSFER. The child proves (a) a read
// through the received fd succeeds (READ survived), (b) a write fails (WRITE was
// attenuated away), and the parent proves (c) its source fd was invalidated
// (move semantics). Monotonic attenuation: a grant can only ever narrow, never
// widen, the sender's authority.

#include "lib/syscall.h"
#include "lib/fs.h"

#define ERR_BADFD (-9)

int puts_raw(const char *s);

int main(void) {
    int ep[2];
    if (endpoint_create(ep) != 0) {
        puts_raw("QW5: FAIL endpoint_create\n");
        return 1;
    }

    int pid = fork();
    if (pid < 0) {
        puts_raw("QW5: FAIL fork\n");
        return 1;
    }

    if (pid == 0) {
        // Child: receive the moved-and-attenuated handle on the recv end.
        close(ep[0]);
        char buf[16];
        int rh = -1;
        long n = ipc_recv(ep[1], buf, sizeof(buf), &rh);
        if (n < 0 || rh < 0) {
            puts_raw("QW5: FAIL child recv (no handle arrived)\n");
            return 1;
        }
        // (a) READ survived the intersection — reading /dev/zero returns bytes.
        char rb[4];
        long r = read(rh, rb, sizeof(rb));
        if (r < 0) {
            puts_raw("QW5: FAIL child read denied (READ should survive)\n");
            return 1;
        }
        puts_raw("QW5: child read OK\n");
        // (b) WRITE was attenuated away — the write must be rejected for lack of
        // the right, not silently discarded by /dev/zero.
        long w = write(rh, "x", 1);
        if (w >= 0) {
            puts_raw("QW5: FAIL child write allowed (WRITE should be attenuated)\n");
            return 1;
        }
        puts_raw("QW5: child write denied as expected\n");
        close(rh);
        return 0;
    }

    // Parent: open a handle that holds READ|WRITE|TRANSFER, then hand the peer
    // strictly fewer rights — READ|TRANSFER, dropping WRITE.
    close(ep[1]);
    int xf = open("/dev/zero", O_RDWR);
    if (xf < 0) {
        puts_raw("QW5: FAIL parent open /dev/zero\n");
        return 1;
    }
    if (ipc_send(ep[0], "Q5", 2, xf,
                 SWIFTOS_RIGHT_READ | SWIFTOS_RIGHT_TRANSFER) != 0) {
        puts_raw("QW5: FAIL parent ipc_send\n");
        return 1;
    }
    // (c) Move semantics: the source fd is cleared, not duplicated. A read through
    // it must now fail with EBADF rather than leak the original authority.
    char probe;
    long moved = read(xf, &probe, 1);
    if (moved != ERR_BADFD) {
        puts_raw(moved >= 0 ? "QW5: FAIL parent source fd still readable (leak)\n"
                            : "QW5: FAIL parent source fd unexpected error\n");
        return 1;
    }
    puts_raw("QW5: parent source fd invalidated\n");

    int status = 0;
    int waited = waitpid(pid, &status, 0);
    if (waited != pid || ((status >> 8) & 0xff) != 0) {
        puts_raw("QW5: FAIL child reported a failed assertion\n");
        return 1;
    }

    puts_raw("QW5: PASS\n");
    return 0;
}
