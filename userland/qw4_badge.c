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
//
// Two further checks exercise the badge's per-message and slot lifecycle on a
// SINGLE endpoint (the original test used three separate pairs):
//   - mixed: re-stamp one send handle A1 -> 0 -> B2 and confirm each recv reports
//     the CURRENT badge, catching a "sticky" endpoint badge that fails to update
//     or clear between messages;
//   - reuse: badge an endpoint, exchange a message, close it, then create a fresh
//     endpoint (which reuses the freed slot) and confirm an unbadged send reports
//     0 — the freed slot's badge must not bleed into its reuse.

#include "lib/syscall.h"

#define BADGE_A 0xA1u
#define BADGE_B 0xB2u

int puts_raw(const char *s);

static int send_recv(int sfd, int rfd, const char *msg, int len,
                     unsigned int *out_badge) {
    if (ipc_send(sfd, msg, (unsigned long)len, -1, SWIFTOS_RIGHTS_ALL_INHERIT) != 0) { return -1; }
    char buf[32];
    int got = -1;
    unsigned int badge = 0xFFFFFFFFu;
    long n = ipc_recv_badged(rfd, buf, sizeof(buf), &got, &badge);
    if (n != len) { return -1; }
    *out_badge = badge;
    return 0;
}

// Mixed badged/unbadged/re-badged on ONE endpoint: re-stamp the send handle
// between messages and confirm each recv reports the current badge. Returns 0 on
// success, 1 on a badge mismatch, -1 on a setup error.
static int test_mixed_one_endpoint(void) {
    int ep[2];
    if (endpoint_create(ep) != 0) return -1;
    unsigned int b = 0;
    int rc = 1;
    if (ipc_badge(ep[0], BADGE_A) == 0 && send_recv(ep[0], ep[1], "m1", 2, &b) == 0 && b == BADGE_A &&
        ipc_badge(ep[0], 0u)     == 0 && send_recv(ep[0], ep[1], "m2", 2, &b) == 0 && b == 0 &&
        ipc_badge(ep[0], BADGE_B) == 0 && send_recv(ep[0], ep[1], "m3", 2, &b) == 0 && b == BADGE_B) {
        rc = 0;
    }
    close(ep[0]); close(ep[1]);
    return rc;
}

// Stale badge after slot reuse: badge a send handle A1, exchange a message, close
// the endpoint (freeing its slot), then create a fresh endpoint (which reuses the
// slot) and confirm an UNBADGED send reports 0. Returns 0/1/-1 as above.
static int test_badge_slot_reuse(void) {
    int ep1[2];
    if (endpoint_create(ep1) != 0) return -1;
    unsigned int b = 0;
    int armed = (ipc_badge(ep1[0], BADGE_A) == 0 &&
                 send_recv(ep1[0], ep1[1], "r1", 2, &b) == 0 && b == BADGE_A);
    close(ep1[0]); close(ep1[1]);              // free the slot; its badge must not linger
    if (!armed) return 1;

    int ep2[2];
    if (endpoint_create(ep2) != 0) return -1;  // reuses the just-freed slot
    int rc = 1;
    if (send_recv(ep2[0], ep2[1], "r2", 2, &b) == 0) rc = (b == 0) ? 0 : 1;
    close(ep2[0]); close(ep2[1]);
    return rc;
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

    int mres = test_mixed_one_endpoint();
    if (mres != 0) {
        puts_raw(mres > 0 ? "qw4-badge: mixed-on-one-endpoint badge mismatch\n"
                          : "qw4-badge: mixed-on-one-endpoint setup failed\n");
        return 1;
    }
    puts_raw("QW4-BADGE-MIXED-OK\n");

    int rres = test_badge_slot_reuse();
    if (rres != 0) {
        puts_raw(rres > 0 ? "qw4-badge: stale badge bled across slot reuse\n"
                          : "qw4-badge: slot-reuse setup failed\n");
        return 1;
    }
    puts_raw("QW4-BADGE-REUSE-CLEAN-OK\n");

    close(epA[0]); close(epA[1]);
    close(epB[0]); close(epB[1]);
    close(epU[0]); close(epU[1]);

    puts_raw("QW4 OK: badges distinguish clients on a shared endpoint\n");
    return 0;
}
