// SPDX-License-Identifier: Apache-2.0
// ptysigprobe.c — HC36 PTY job-control SIGINT self-test (C/newlib).
//
// Written in C rather than Embedded Swift because it needs newlib's working
// sigaction + sigreturn trampoline (proven by signalprobe.c); the Swift userland
// bridge has no signal-handler machinery yet. openpty() and the new
// pty_set_foreground() syscall are issued via a small raw `svc #0` helper.
//
// Each test allocates a PTY pair, forks a child that adopts the slave as its
// controlling terminal (stdin) and is named the PTY's foreground process, then
// the parent writes Ctrl-C (0x03) to the master and asserts the child observed
// SIGINT:
//   1) default disposition  -> child is terminated with WTERMSIG == SIGINT,
//      and the "^C" echo appears on the master-readable side;
//   2) installed handler     -> the handler runs, read() returns EINTR, and the
//      child exits 42.
// Prints one "ptysigprobe: ... OK" line per check and a final "PTYSIGPROBE-OK";
// tests/ptysig_test.sh asserts on these markers.

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define SYS_OPENPTY            84
#define SYS_PTY_SET_FOREGROUND 85

static long sys3(long n, long a0, long a1, long a2) {
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a0;
    register long x1 __asm__("x1") = a1;
    register long x2 __asm__("x2") = a2;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
    return x0;
}

static void fail(const char *msg) {
    printf("ptysigprobe: FAIL: %s errno=%d\n", msg, errno);
    fflush(stdout);
    _exit(1);
}

static void tiny_sleep(void) {
    struct timespec ts;
    ts.tv_sec = 0;
    ts.tv_nsec = 80000000; // 80ms — let the child reach its blocking read()
    nanosleep(&ts, NULL);
}

static volatile sig_atomic_t handler_seen = 0;
static void on_sigint(int sig) { if (sig == SIGINT) { handler_seen++; } }

// Fork a child blocked reading the PTY slave, deliver Ctrl-C from the master,
// and return the child's wait status via *status. `install_handler` selects the
// default-terminate vs custom-handler child behaviour.
static int run_case(int install_handler, int *status) {
    int m = -1, s = -1;
    if (sys3(SYS_OPENPTY, (long)&m, (long)&s, 0) != 0 || m < 0 || s < 0) {
        fail("openpty");
    }

    pid_t child = fork();
    if (child < 0) { fail("fork"); }
    if (child == 0) {
        // Child: become the controlling-tty reader on the slave end.
        close(m);
        if (dup2(s, 0) < 0) { _exit(43); }
        if (install_handler) {
            struct sigaction act;
            memset(&act, 0, sizeof(act));
            act.sa_handler = on_sigint;
            if (sigaction(SIGINT, &act, NULL) != 0) { _exit(44); }
        }
        char buf[8];
        long n = read(0, buf, sizeof(buf));
        // With a handler installed, the interrupted read returns EINTR and we
        // report whether the handler actually ran. Without a handler the default
        // action terminates us before read() ever returns.
        if (install_handler && n < 0 && handler_seen) { _exit(42); }
        _exit(45);
    }

    // Parent: name the child the PTY's foreground process, then interrupt it.
    if (sys3(SYS_PTY_SET_FOREGROUND, m, child, 0) != 0) { fail("pty_set_foreground"); }
    tiny_sleep();
    char ctrlc = 0x03;
    if (write(m, &ctrlc, 1) != 1) { fail("write Ctrl-C"); }

    // The "^C" echo is queued synchronously on the master-readable side.
    char echo[4];
    long e = read(m, echo, sizeof(echo));
    if (e < 2 || echo[0] != '^' || echo[1] != 'C') { fail("missing ^C echo"); }

    if (waitpid(child, status, 0) != child) { fail("waitpid"); }
    close(m);
    close(s);
    return 0;
}

int main(void) {
    int status = 0;

    // 1) Default disposition: Ctrl-C terminates the foreground child with SIGINT.
    run_case(0, &status);
    if (!WIFSIGNALED(status) || WTERMSIG(status) != SIGINT) {
        fail("default-terminate status");
    }
    printf("ptysigprobe: default terminate OK\n");

    // 2) Installed handler: Ctrl-C runs the handler; read() returns EINTR.
    run_case(1, &status);
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 42) {
        fail("handler delivery status");
    }
    printf("ptysigprobe: handler delivered OK\n");

    printf("PTYSIGPROBE-OK\n");
    fflush(stdout);
    return 0;
}
