// SPDX-License-Identifier: Apache-2.0
// ipc_call_test.c — QW1 acceptance fixture for the synchronous request/reply IPC
// verbs ipc_call / ipc_reply_recv over a kernel reply port.
//
// Scenario 1 (correlation + handle round-trip): the parent creates one endpoint
// and forks a server child. The child runs the canonical hot loop — a single
// ipc_reply_recv per turn that replies to the previous request and blocks for the
// next. The parent issues several ipc_calls; each blocks until the server's reply
// for THAT request arrives over its reply port:
//   - rounds 1..3 send byte N and expect N+1 back (reply correlates to request);
//   - round 4 moves a pipe write end to the server, which writes 'Z' through it
//     and moves the handle back — proving a handle round-trips both ways.
// The ping-pong is self-synchronizing (each side blocks for the other), so it is
// robust at -smp 4 with no sleeps.
//
// Scenario 2 (bogus token → EINVAL): ipc_reply_recv with a reply-port token that
// names no awaiting port must be rejected with EINVAL (-22), never honored.
//
// Scenario 3 (server dies without replying → EPIPE): a blocked ipc_call whose
// server exits without replying must fail EPIPE (-32), not hang or panic.
//
// Emitting "IPC-CALL OK: ..." signals full acceptance.

#include "lib/syscall.h"

int puts_raw(const char *s);

#define ERR_INVAL (-22)
#define ERR_PIPE  (-32)

static void sleep_100ms(void) {
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

static void print_int(int n) {
    char b[16];
    fmt_int(n, b);
    puts_raw(b);
}

// The server hot loop: one ipc_reply_recv per request. Replies to the previous
// request (rp), receives the next. Echoes byte+1 for plain requests; for a
// request that carried a handle it writes 'Z' through it and moves it back.
static int server_loop(int recv_fd) {
    unsigned long rp = 0;          // reply-port token of the request to reply to
    char reply_buf[8];
    unsigned long reply_len = 0;
    int reply_h = -1;
    for (;;) {
        char in[64];
        int in_h = -1;
        unsigned long tok = 0;
        long n = ipc_reply_recv(recv_fd, rp, reply_buf, reply_len, reply_h,
                                in, sizeof(in), &in_h, &tok);
        if (n < 0) {
            // Endpoint torn down by the parent: the server is done.
            return 0;
        }
        rp = tok;                  // reply to THIS request on the next turn
        if (in_h >= 0) {
            // Handle round-trip: prove the moved handle works, then send it back.
            write(in_h, "Z", 1);
            reply_buf[0] = in[0];  // echo the request marker byte
            reply_len = 1;
            reply_h = in_h;        // move the handle back to the caller
        } else {
            reply_buf[0] = (char)(in[0] + 1);
            reply_len = 1;
            reply_h = -1;
        }
    }
}

int main(void) {
    // ---- Scenario 2 first: a bogus reply-port token is rejected with EINVAL ----
    {
        int epb[2];
        if (endpoint_create(epb) != 0) { puts_raw("ipc-call: endpoint_create epb failed\n"); return 1; }
        char jb[8];
        int jh = -1;
        unsigned long jt = 0;
        long r = ipc_reply_recv(epb[1], 0xDEADBEEFUL, jb, 0, -1, jb, sizeof(jb), &jh, &jt);
        if (r == ERR_INVAL) {
            puts_raw("ipc-call: bogus token rejected EINVAL\n");
        } else {
            puts_raw("ipc-call: bogus token NOT rejected\n");
            return 1;
        }
        close(epb[0]);
        close(epb[1]);
    }

    // ---- Scenario 1: correlation + handle round-trip ---------------------------
    int ep[2];
    if (endpoint_create(ep) != 0) { puts_raw("ipc-call: endpoint_create failed\n"); return 1; }

    int srv = fork();
    if (srv < 0) { puts_raw("ipc-call: fork failed\n"); return 1; }
    if (srv == 0) {
        close(ep[0]);              // server holds only the recv end
        return server_loop(ep[1]);
    }
    close(ep[1]);                  // parent (caller) holds only the send end

    for (int i = 1; i <= 3; i++) {
        char req = (char)i;
        char rep[8];
        int oh = -1;
        long r = ipc_call(ep[0], &req, 1, -1, rep, sizeof(rep), &oh);
        if (r == 1 && rep[0] == (char)(i + 1)) {
            puts_raw("ipc-call: reply ");
            print_int(i);
            puts_raw(" correlated\n");
        } else {
            puts_raw("ipc-call: reply ");
            print_int(i);
            puts_raw(" MISMATCH\n");
            return 1;
        }
    }

    // Handle round-trip: move a pipe write end to the server and get it back.
    {
        int p[2];
        if (pipe(p) != 0) { puts_raw("ipc-call: pipe failed\n"); return 1; }
        char req = 'H';
        char rep[8];
        int oh = -1;
        long r = ipc_call(ep[0], &req, 1, p[1], rep, sizeof(rep), &oh);
        char c = 0;
        if (r == 1 && rep[0] == 'H' && oh >= 0 && read(p[0], &c, 1) == 1 && c == 'Z') {
            puts_raw("ipc-call: handle round-tripped\n");
        } else {
            puts_raw("ipc-call: handle round-trip FAILED\n");
            return 1;
        }
        close(p[0]);
        close(oh);
    }

    // Tear down the endpoint: closing the last sender wakes the server's blocked
    // receive with EOF, so it exits cleanly.
    close(ep[0]);
    int st = 0;
    waitpid(srv, &st, 0);

    // ---- Scenario 3: a server that exits without replying gives EPIPE ----------
    {
        int epe[2];
        if (endpoint_create(epe) != 0) { puts_raw("ipc-call: endpoint_create epe failed\n"); return 1; }
        int dead = fork();
        if (dead < 0) { puts_raw("ipc-call: fork 2 failed\n"); return 1; }
        if (dead == 0) {
            close(epe[0]);         // hold only the recv end
            sleep_100ms();         // let the parent block in ipc_call first
            sleep_100ms();
            _exit(0);              // exit WITHOUT replying — caller must get EPIPE
        }
        close(epe[1]);             // only the dying child holds a recv end now
        char req = 7;
        char rep[8];
        int oh = -1;
        long r = ipc_call(epe[0], &req, 1, -1, rep, sizeof(rep), &oh);
        if (r == ERR_PIPE) {
            puts_raw("ipc-call: server-exit gives EPIPE\n");
        } else {
            puts_raw("ipc-call: server-exit did NOT give EPIPE\n");
            return 1;
        }
        int st2 = 0;
        waitpid(dead, &st2, 0);
        close(epe[0]);
    }

    puts_raw("IPC-CALL OK: synchronous request/reply over reply port\n");
    return 0;
}
