// SPDX-License-Identifier: Apache-2.0
// qw5_rightsxfer.c — QW5 rights = held ∩ requested on IPC handle transfer.
//
// Attenuation must be MONOTONIC: a grant can only ever narrow the sender's
// authority, never widen it. Three scenarios prove both directions of that
// invariant over a C4 endpoint handle move:
//   1. downgrade  — hold READ|WRITE|TRANSFER, request only READ|TRANSFER  ->
//                   the receiver LOSES write (the requested mask narrowed it).
//   2. escalation — hold only READ|TRANSFER (O_RDONLY), request READ|WRITE|
//                   TRANSFER -> write must NOT appear: asking for a right the
//                   sender never held cannot conjure it. THIS is the security
//                   property; the old test only proved direction 1.
//   3. all-inherit— hold only READ|TRANSFER, request SWIFTOS_RIGHTS_ALL_INHERIT
//                   (0xFFFFFFFF) -> the receiver still gets only READ|TRANSFER.
//
// In every case the receiver must be able to read /dev/zero (READ survived) but
// be DENIED a write — the kernel checks the WRITE right before /dev/zero's
// accept-everything write path, so a denied write proves the right is absent,
// not silently swallowed. The sender's source fd must also be invalidated (the
// transfer is a move, not a copy).

#include "lib/syscall.h"
#include "lib/fs.h"

#define ERR_BADFD (-9)

int puts_raw(const char *s);

// Run one transfer scenario. The parent opens /dev/zero with `open_flags` (which
// fixes the rights it HOLDS), then moves the handle requesting `requested`. The
// child asserts a read succeeds and a write is denied. Prints `ok_msg` and
// returns 0 on success; prints a QW5: FAIL line and returns 1 otherwise.
static int run_scenario(const char *ok_msg, int open_flags, unsigned long requested) {
    int ep[2];
    if (endpoint_create(ep) != 0) { puts_raw("QW5: FAIL endpoint_create\n"); return 1; }

    int pid = fork();
    if (pid < 0) { puts_raw("QW5: FAIL fork\n"); return 1; }

    if (pid == 0) {
        // Child: receive the moved-and-attenuated handle, then probe its rights.
        // It runs inside run_scenario, so it must _exit, never return into main.
        close(ep[0]);
        char buf[16];
        int rh = -1;
        long n = ipc_recv(ep[1], buf, sizeof(buf), &rh);
        if (n < 0 || rh < 0) { puts_raw("QW5: FAIL child recv (no handle arrived)\n"); _exit(1); }
        char rb[4];
        if (read(rh, rb, sizeof(rb)) < 0) {
            puts_raw("QW5: FAIL child read denied (READ should survive)\n"); _exit(1);
        }
        // WRITE may be present only if the sender HELD it AND requested it. In
        // scenarios 2 and 3 the sender never held it, so this must be denied.
        if (write(rh, "x", 1) >= 0) {
            puts_raw("QW5: FAIL child write allowed (rights were widened!)\n"); _exit(1);
        }
        close(rh);
        _exit(0);
    }

    // Parent: hold a /dev/zero handle (rights fixed by open_flags), then move it.
    close(ep[1]);
    int xf = open("/dev/zero", open_flags);
    if (xf < 0) { puts_raw("QW5: FAIL parent open /dev/zero\n"); return 1; }
    if (ipc_send(ep[0], "Q5", 2, xf, requested) != 0) {
        puts_raw("QW5: FAIL parent ipc_send\n"); return 1;
    }
    // Move semantics: the source fd is cleared, not duplicated.
    char probe;
    if (read(xf, &probe, 1) != ERR_BADFD) {
        puts_raw("QW5: FAIL parent source fd still readable (move leaked)\n"); return 1;
    }

    int status = 0;
    if (waitpid(pid, &status, 0) != pid || ((status >> 8) & 0xff) != 0) {
        puts_raw("QW5: FAIL child reported a failed assertion\n"); return 1;
    }
    close(ep[0]);
    puts_raw(ok_msg);
    return 0;
}

int main(void) {
    // 1. Downgrade: hold READ|WRITE|TRANSFER, grant only READ|TRANSFER.
    if (run_scenario("QW5: downgrade narrowed away WRITE\n", O_RDWR,
                     SWIFTOS_RIGHT_READ | SWIFTOS_RIGHT_TRANSFER) != 0) return 1;

    // 2. Escalation: hold only READ|TRANSFER (O_RDONLY), but REQUEST WRITE too.
    //    The intersection must not conjure a right the sender never held.
    if (run_scenario("QW5: escalation request for +WRITE denied\n", O_RDONLY,
                     SWIFTOS_RIGHT_READ | SWIFTOS_RIGHT_WRITE | SWIFTOS_RIGHT_TRANSFER) != 0) return 1;

    // 3. Ask for EVERYTHING (ALL_INHERIT) while holding only READ|TRANSFER.
    if (run_scenario("QW5: ALL_INHERIT yields only held rights\n", O_RDONLY,
                     SWIFTOS_RIGHTS_ALL_INHERIT) != 0) return 1;

    puts_raw("QW5: PASS\n");
    return 0;
}
