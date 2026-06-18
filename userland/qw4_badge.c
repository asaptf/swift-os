// SPDX-License-Identifier: Apache-2.0
// qw4_badge.c — QW4 endpoint-badge smoke.
//
// A single process proves a server-chosen badge rides on the send-capability
// HandleEntry, not the endpoint: it creates two endpoint pairs (two clients on
// otherwise-identical endpoints), stamps a distinct badge into each send handle
// with ipc_badge, sends a message on each, and receives with ipc_recv_badged.
// Each received badge must equal the one stamped. A third, *unbadged* send
// (no ipc_badge call) must report badge == 0. This is the structural
// confused-deputy defense in docs/CAPABILITIES.md §4.2.

#include "lib/syscall.h"

#define BADGE_A 0xA1u
#define BADGE_B 0xB2u

int puts_raw(const char *s);

static int send_recv(int sfd, int rfd, const char *msg, int len,
                     unsigned int *out_badge) {
    if (ipc_send(sfd, msg, (unsigned long)len, -1) != 0) { return -1; }
    char buf[32];
    int got = -1;
    unsigned int badge = 0xFFFFFFFFu;
    long n = ipc_recv_badged(rfd, buf, sizeof(buf), &got, &badge);
    if (n != len) { return -1; }
    *out_badge = badge;
    return 0;
}

int main(void) {
    int epA[2], epB[2], epU[2];
    if (endpoint_create(epA) != 0 || endpoint_create(epB) != 0 ||
        endpoint_create(epU) != 0) {
        puts_raw("qw4-badge: endpoint_create failed\n");
        return 1;
    }

    // Stamp a distinct badge into each client's SEND end. epU is left unbadged.
    if (ipc_badge(epA[0], BADGE_A) != 0) {
        puts_raw("qw4-badge: ipc_badge A failed\n");
        return 1;
    }
    if (ipc_badge(epB[0], BADGE_B) != 0) {
        puts_raw("qw4-badge: ipc_badge B failed\n");
        return 1;
    }

    // Badging the RECV end (or any non-send-endpoint fd) must be rejected.
    if (ipc_badge(epA[1], BADGE_A) == 0) {
        puts_raw("qw4-badge: ipc_badge wrongly accepted a recv-end fd\n");
        return 1;
    }
    puts_raw("QW4-BADGE-RECVEND-REJECTED-OK\n");

    unsigned int badge = 0;
    if (send_recv(epA[0], epA[1], "aaaa", 4, &badge) != 0) {
        puts_raw("qw4-badge: client A send/recv failed\n");
        return 1;
    }
    if (badge != BADGE_A) {
        puts_raw("qw4-badge: client A badge mismatch\n");
        return 1;
    }
    puts_raw("QW4-BADGE-A1-OK\n");

    if (send_recv(epB[0], epB[1], "bbbb", 4, &badge) != 0) {
        puts_raw("qw4-badge: client B send/recv failed\n");
        return 1;
    }
    if (badge != BADGE_B) {
        puts_raw("qw4-badge: client B badge mismatch\n");
        return 1;
    }
    puts_raw("QW4-BADGE-B2-OK\n");

    if (send_recv(epU[0], epU[1], "uuuu", 4, &badge) != 0) {
        puts_raw("qw4-badge: unbadged send/recv failed\n");
        return 1;
    }
    if (badge != 0) {
        puts_raw("qw4-badge: unbadged send reported a non-zero badge\n");
        return 1;
    }
    puts_raw("QW4-BADGE-UNBADGED-ZERO-OK\n");

    close(epA[0]); close(epA[1]);
    close(epB[0]); close(epB[1]);
    close(epU[0]); close(epU[1]);

    puts_raw("QW4 OK: badges distinguish clients on a shared endpoint\n");
    return 0;
}
