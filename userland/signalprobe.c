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

// Fork a child that blocks in nanosleep, kill it with `sig`, and confirm the
// default action terminated it with the matching 128+signo wait status. Returns
// 1 on the expected result, 0 on a wrong status, negative on a setup failure.
static int kill_sleeping_child(int sig) {
    pid_t child = fork();
    if (child < 0) { return -1; }
    if (child == 0) {
        struct timespec ts;
        ts.tv_sec = 10;
        ts.tv_nsec = 0;
        for (;;) { nanosleep(&ts, NULL); }
    }
    tiny_sleep();   // let the child settle into nanosleep (not on-CPU)
    if (kill(child, sig) != 0) { return -2; }
    int status = 0;
    if (waitpid(child, &status, 0) != child) { return -3; }
    if (!WIFSIGNALED(status) || WTERMSIG(status) != sig) { return 0; }
    return 1;
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

    // Default-action terminate is not special to SIGTERM: kill a sleeping child
    // with SIGINT, SIGKILL, and SIGSEGV and confirm each reports the matching
    // 128+signo status. (SIGKILL in particular must always terminate.)
    static const int fatal_sigs[] = { SIGINT, SIGKILL, SIGSEGV };
    static const char *const fatal_names[] = { "SIGINT", "SIGKILL", "SIGSEGV" };
    for (int i = 0; i < 3; i++) {
        int r = kill_sleeping_child(fatal_sigs[i]);
        if (r != 1) {
            printf("signalprobe: FAIL %s default terminate (r=%d)\n", fatal_names[i], r);
            _exit(1);
        }
    }
    printf("signalprobe: multi-signal default terminate OK\n");

    printf("SIGNALPROBE-OK\n");
    return 0;
}
