// uvsignalprobe.c - C/newlib libuv-style signal watcher proof.

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

struct signal_msg {
    int signum;
};

static int signal_pipe[2] = { -1, -1 };
static int lock_pipe[2] = { -1, -1 };
static volatile sig_atomic_t handler_seen = 0;

static void fail(const char *label, int detail) {
    printf("uvsignalprobe: FAIL: %s detail=%d errno=%d\n", label, detail, errno);
}

static int lock_signal_state(void) {
    unsigned char token = 0;
    return read(lock_pipe[0], &token, 1) == 1 ? 0 : -1;
}

static int unlock_signal_state(void) {
    unsigned char token = 1;
    return write(lock_pipe[1], &token, 1) == 1 ? 0 : -1;
}

static void signal_handler(int sig) {
    struct signal_msg msg;
    msg.signum = sig;
    if (write(signal_pipe[1], &msg, sizeof(msg)) == (ssize_t)sizeof(msg)) {
        handler_seen++;
    }
}

int main(void) {
    if (pipe2(signal_pipe, O_NONBLOCK | O_CLOEXEC) != 0) {
        fail("signal pipe", 0);
        return 1;
    }
    if (pipe2(lock_pipe, O_CLOEXEC) != 0) {
        fail("lock pipe", 0);
        return 1;
    }
    if (unlock_signal_state() != 0 || lock_signal_state() != 0 ||
        unlock_signal_state() != 0) {
        fail("lock pipe token", 0);
        return 1;
    }

    sigset_t all;
    sigset_t empty;
    sigset_t saved;
    if (sigfillset(&all) != 0 || sigemptyset(&empty) != 0) {
        fail("sigset init", 0);
        return 1;
    }
    int r = pthread_sigmask(SIG_SETMASK, &all, &saved);
    if (r != 0) {
        fail("pthread_sigmask set", r);
        return 1;
    }
    r = pthread_sigmask(SIG_SETMASK, &saved, 0);
    if (r != 0) {
        fail("pthread_sigmask restore", r);
        return 1;
    }
    r = pthread_sigmask(SIG_SETMASK, &empty, &saved);
    if (r != 0) {
        fail("pthread_sigmask empty", r);
        return 1;
    }
    printf("uvsignalprobe: pthread_sigmask facade OK\n");

    struct sigaction act;
    struct sigaction old;
    memset(&act, 0, sizeof(act));
    memset(&old, 0, sizeof(old));
    act.sa_handler = signal_handler;
    act.sa_mask = all;
    act.sa_flags = SA_RESTART;

    if (lock_signal_state() != 0) {
        fail("lock before sigaction", 0);
        return 1;
    }
    if (sigaction(SIGTERM, &act, &old) != 0) {
        fail("sigaction install", 0);
        return 1;
    }
    if (unlock_signal_state() != 0) {
        fail("unlock after sigaction", 0);
        return 1;
    }

    if (raise(SIGTERM) != 0) {
        fail("raise SIGTERM", 0);
        return 1;
    }

    struct pollfd pfd;
    pfd.fd = signal_pipe[0];
    pfd.events = POLLIN;
    pfd.revents = 0;
    r = poll(&pfd, 1, 1000);
    if (r != 1 || (pfd.revents & POLLIN) == 0) {
        fail("poll signal pipe", r);
        printf("uvsignalprobe: poll revents=0x%x handler_seen=%d\n",
               pfd.revents, (int)handler_seen);
        return 1;
    }

    struct signal_msg msg;
    ssize_t n = read(signal_pipe[0], &msg, sizeof(msg));
    if (n != (ssize_t)sizeof(msg) || msg.signum != SIGTERM || handler_seen != 1) {
        fail("read signal message", (int)n);
        printf("uvsignalprobe: signum=%d handler_seen=%d\n",
               msg.signum, (int)handler_seen);
        return 1;
    }
    printf("uvsignalprobe: handler pipe wake OK\n");

    errno = 0;
    n = read(signal_pipe[0], &msg, sizeof(msg));
    if (n != -1 || errno != EAGAIN) {
        fail("drained nonblocking read", (int)n);
        return 1;
    }

    struct sigaction restore;
    memset(&restore, 0, sizeof(restore));
    restore.sa_handler = old.sa_handler;
    restore.sa_mask = old.sa_mask;
    restore.sa_flags = old.sa_flags;
    if (sigaction(SIGTERM, &restore, &old) != 0) {
        fail("sigaction restore", 0);
        return 1;
    }
    if (old.sa_handler != signal_handler) {
        fail("sigaction old handler", 0);
        return 1;
    }
    printf("uvsignalprobe: restore disposition OK\n");

    close(signal_pipe[0]);
    close(signal_pipe[1]);
    close(lock_pipe[0]);
    close(lock_pipe[1]);
    printf("UVSIGNALPROBE-OK\n");
    return 0;
}
