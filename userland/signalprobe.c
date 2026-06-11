// signalprobe.c - C/newlib signal lifecycle probe for SwiftOS.

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static void fail(const char *msg) {
    printf("signalprobe: FAIL: %s errno=%d\n", msg, errno);
    _exit(1);
}

static void tiny_sleep(void) {
    struct timespec ts;
    ts.tv_sec = 0;
    ts.tv_nsec = 20000000;
    nanosleep(&ts, NULL);
}

static volatile sig_atomic_t custom_handler_seen = 0;

static void custom_handler(int sig) {
    if (sig == SIGTERM) { custom_handler_seen++; }
}

int main(void) {
    errno = 0;
    if (kill(getpid(), 0) != 0) { fail("kill self probe"); }
    if (kill(9999, 0) != -1 || errno != ESRCH) { fail("kill missing pid errno"); }
    printf("signalprobe: kill self probe OK\n");

    struct sigaction act;
    struct sigaction old;
    memset(&act, 0, sizeof(act));
    memset(&old, 0, sizeof(old));
    act.sa_handler = SIG_IGN;
    if (sigaction(SIGTERM, &act, &old) != 0) { fail("sigaction ignore"); }
    if (old.sa_handler != SIG_DFL) { fail("sigaction old default"); }
    if (raise(SIGTERM) != 0) { fail("raise ignored SIGTERM"); }

    memset(&act, 0, sizeof(act));
    act.sa_handler = SIG_DFL;
    if (sigaction(SIGTERM, &act, &old) != 0) { fail("sigaction restore"); }
    if (old.sa_handler != SIG_IGN) { fail("sigaction old ignore"); }
    printf("signalprobe: sigaction ignore/old OK\n");

    memset(&act, 0, sizeof(act));
    act.sa_handler = custom_handler;
    if (sigaction(SIGTERM, &act, &old) != 0) { fail("sigaction custom handler"); }
    if (old.sa_handler != SIG_DFL) { fail("sigaction old default before custom"); }
    if (raise(SIGTERM) != 0) { fail("raise custom SIGTERM"); }
    if (custom_handler_seen != 1) { fail("custom handler delivery"); }

    memset(&act, 0, sizeof(act));
    act.sa_handler = SIG_DFL;
    if (sigaction(SIGTERM, &act, &old) != 0) { fail("sigaction restore after custom"); }
    if (old.sa_handler != custom_handler) { fail("sigaction old custom handler"); }
    printf("signalprobe: custom handler frame OK\n");

    pid_t child = fork();
    if (child < 0) { fail("fork"); }
    if (child == 0) {
        struct timespec ts;
        ts.tv_sec = 10;
        ts.tv_nsec = 0;
        for (;;) { nanosleep(&ts, NULL); }
    }

    tiny_sleep();
    if (kill(child, 0) != 0) { fail("kill child probe"); }
    if (kill(child, SIGTERM) != 0) { fail("kill child SIGTERM"); }

    int status = 0;
    pid_t reaped = waitpid(child, &status, 0);
    if (reaped != child) { fail("waitpid child"); }
    if (!WIFSIGNALED(status) || WTERMSIG(status) != SIGTERM) {
        fail("waitpid signaled status");
    }
    printf("signalprobe: child SIGTERM status OK\n");
    printf("SIGNALPROBE-OK\n");
    return 0;
}
