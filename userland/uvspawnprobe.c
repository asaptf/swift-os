// uvspawnprobe.c - C/newlib process-spawn handshake proof for libuv.

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static void fail(const char *label, int detail) {
    printf("uvspawnprobe: FAIL: %s detail=%d errno=%d\n", label, detail, errno);
}

static int write_full(int fd, const void *buf, size_t len) {
    const char *p = (const char *)buf;
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n < 0) {
            if (errno == EINTR) { continue; }
            return -1;
        }
        if (n == 0) { return -1; }
        p += n;
        len -= (size_t)n;
    }
    return 0;
}

static ssize_t read_retry(int fd, void *buf, size_t len) {
    for (;;) {
        ssize_t n = read(fd, buf, len);
        if (n < 0 && errno == EINTR) { continue; }
        return n;
    }
}

static int read_to_eof(int fd, char *buf, size_t cap, size_t *out_len) {
    size_t len = 0;
    while (len + 1 < cap) {
        ssize_t n = read_retry(fd, buf + len, cap - 1 - len);
        if (n < 0) { return -1; }
        if (n == 0) {
            buf[len] = 0;
            *out_len = len;
            return 0;
        }
        len += (size_t)n;
    }
    buf[len] = 0;
    *out_len = len;
    return 0;
}

static int contains(const char *haystack, const char *needle) {
    return strstr(haystack, needle) != 0;
}

static int cloexec_is_set(int fd) {
    int flags = fcntl(fd, F_GETFD, 0);
    return flags >= 0 && (flags & FD_CLOEXEC) != 0;
}

static void remove_signal(sigset_t *set, int sig) {
    (void)sigdelset(set, sig);
}

static void restore_child_signal_mask(void) {
    sigset_t empty;
    if (sigemptyset(&empty) == 0) {
        (void)pthread_sigmask(SIG_SETMASK, &empty, 0);
    }
}

static void child_exec_success(int error_write, int stdout_write) {
    if (dup2(stdout_write, 1) < 0) {
        int err = -errno;
        (void)write_full(error_write, &err, sizeof(err));
        _exit(127);
    }
    if (stdout_write != 1) {
        close(stdout_write);
    }
    restore_child_signal_mask();

    char *argv[] = { "argvdemo", "spawn-alpha", "spawn-beta", 0 };
    execvp("argvdemo", argv);

    int err = -errno;
    (void)write_full(error_write, &err, sizeof(err));
    _exit(127);
}

static int run_success_spawn(void) {
    int error_pipe[2] = { -1, -1 };
    int stdout_pipe[2] = { -1, -1 };
    if (pipe2(error_pipe, O_CLOEXEC) != 0) {
        fail("error pipe", 0);
        return 1;
    }
    if (!cloexec_is_set(error_pipe[0]) || !cloexec_is_set(error_pipe[1])) {
        fail("error pipe cloexec", 0);
        return 1;
    }
    if (pipe2(stdout_pipe, O_CLOEXEC) != 0) {
        fail("stdout pipe", 0);
        return 1;
    }

    sigset_t block_set;
    sigset_t saved_set;
    if (sigfillset(&block_set) != 0) {
        fail("sigfillset", 0);
        return 1;
    }
    remove_signal(&block_set, SIGKILL);
    remove_signal(&block_set, SIGSTOP);
    int r = pthread_sigmask(SIG_BLOCK, &block_set, &saved_set);
    if (r != 0) {
        fail("pthread_sigmask block", r);
        return 1;
    }

    pid_t child = fork();
    if (child < 0) {
        int saved_errno = errno;
        (void)pthread_sigmask(SIG_SETMASK, &saved_set, 0);
        errno = saved_errno;
        fail("fork success path", 0);
        return 1;
    }
    if (child == 0) {
        close(error_pipe[0]);
        close(stdout_pipe[0]);
        child_exec_success(error_pipe[1], stdout_pipe[1]);
    }

    (void)pthread_sigmask(SIG_SETMASK, &saved_set, 0);
    close(error_pipe[1]);
    close(stdout_pipe[1]);

    int exec_error = 0;
    ssize_t n = read_retry(error_pipe[0], &exec_error, sizeof(exec_error));
    if (n != 0) {
        fail("success error-pipe EOF", (int)n);
        return 1;
    }
    printf("uvspawnprobe: close-on-exec error pipe OK\n");
    close(error_pipe[0]);

    char out[512];
    size_t out_len = 0;
    if (read_to_eof(stdout_pipe[0], out, sizeof(out), &out_len) != 0) {
        fail("read stdout pipe", 0);
        return 1;
    }
    close(stdout_pipe[0]);

    int status = 0;
    if (waitpid(child, &status, 0) != child) {
        fail("waitpid success child", 0);
        return 1;
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 3) {
        fail("waitpid success status", status);
        return 1;
    }
    printf("uvspawnprobe: waitpid status OK\n");

    if (!contains(out, "argv[0]=argvdemo") ||
        !contains(out, "argv[1]=spawn-alpha") ||
        !contains(out, "argv[2]=spawn-beta")) {
        fail("dup2 stdout argv capture", (int)out_len);
        printf("uvspawnprobe: captured stdout: %s\n", out);
        return 1;
    }
    printf("uvspawnprobe: dup2 stdout capture OK\n");
    return 0;
}

static void child_exec_failure(int error_write) {
    restore_child_signal_mask();

    char *argv[] = { "missing-uvspawn-target", 0 };
    execvp("missing-uvspawn-target", argv);

    int err = -errno;
    (void)write_full(error_write, &err, sizeof(err));
    _exit(127);
}

static int run_failure_spawn(void) {
    int error_pipe[2] = { -1, -1 };
    if (pipe2(error_pipe, O_CLOEXEC) != 0) {
        fail("failure error pipe", 0);
        return 1;
    }

    pid_t child = fork();
    if (child < 0) {
        fail("fork failure path", 0);
        return 1;
    }
    if (child == 0) {
        close(error_pipe[0]);
        child_exec_failure(error_pipe[1]);
    }

    close(error_pipe[1]);
    int exec_error = 0;
    ssize_t n = read_retry(error_pipe[0], &exec_error, sizeof(exec_error));
    close(error_pipe[0]);
    if (n != (ssize_t)sizeof(exec_error) || exec_error >= 0) {
        fail("exec error pipe", (int)n);
        return 1;
    }

    int status = 0;
    if (waitpid(child, &status, 0) != child) {
        fail("waitpid failure child", 0);
        return 1;
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 127) {
        fail("waitpid failure status", status);
        return 1;
    }
    printf("uvspawnprobe: exec error pipe OK\n");
    return 0;
}

int main(void) {
    if (run_success_spawn() != 0) {
        return 1;
    }
    if (run_failure_spawn() != 0) {
        return 1;
    }
    printf("UVSPAWNPROBE-OK\n");
    return 0;
}
