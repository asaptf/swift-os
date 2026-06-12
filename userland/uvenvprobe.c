// uvenvprobe.c - C/newlib environment propagation proof for libuv/Node.

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static void fail(const char *label, int detail) {
    printf("uvenvprobe: FAIL: %s detail=%d errno=%d\n", label, detail, errno);
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

static int check_parent_env_mutation(void) {
    if (setenv("SWOS_ENV_PARENT_ONLY", "parent-value", 1) != 0) {
        fail("setenv parent", 0);
        return 1;
    }
    if (setenv("SWOS_ENV_MUTATE", "first", 1) != 0) {
        fail("setenv first", 0);
        return 1;
    }
    if (setenv("SWOS_ENV_MUTATE", "ignored", 0) != 0) {
        fail("setenv overwrite=0", 0);
        return 1;
    }
    const char *value = getenv("SWOS_ENV_MUTATE");
    if (!value || strcmp(value, "first") != 0) {
        fail("getenv overwrite=0", value ? value[0] : 0);
        return 1;
    }
    if (setenv("SWOS_ENV_MUTATE", "second", 1) != 0) {
        fail("setenv overwrite=1", 0);
        return 1;
    }
    value = getenv("SWOS_ENV_MUTATE");
    if (!value || strcmp(value, "second") != 0) {
        fail("getenv overwrite=1", value ? value[0] : 0);
        return 1;
    }
    if (unsetenv("SWOS_ENV_MUTATE") != 0 || getenv("SWOS_ENV_MUTATE") != 0) {
        fail("unsetenv", 0);
        return 1;
    }
    printf("uvenvprobe: getenv/setenv/unsetenv OK\n");
    return 0;
}

static void child_exec_env(int error_write, int stdout_write) {
    static char env_alpha[] = "SWOS_ENV_ALPHA=alpha-child";
    static char env_beta[] = "SWOS_ENV_BETA=beta-child";
    static char env_path[] = "PATH=/bin";
    static char *child_env[] = { env_alpha, env_beta, env_path, 0 };

    if (dup2(stdout_write, 1) < 0) {
        int err = -errno;
        (void)write_full(error_write, &err, sizeof(err));
        _exit(127);
    }
    if (stdout_write != 1) {
        close(stdout_write);
    }

    environ = child_env;
    char *argv[] = { "envchild", 0 };
    execvp("envchild", argv);

    int err = -errno;
    (void)write_full(error_write, &err, sizeof(err));
    _exit(127);
}

static int run_exec_env(void) {
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

    pid_t child = fork();
    if (child < 0) {
        fail("fork env child", 0);
        return 1;
    }
    if (child == 0) {
        close(error_pipe[0]);
        close(stdout_pipe[0]);
        child_exec_env(error_pipe[1], stdout_pipe[1]);
    }

    close(error_pipe[1]);
    close(stdout_pipe[1]);

    int exec_error = 0;
    ssize_t n = read_retry(error_pipe[0], &exec_error, sizeof(exec_error));
    close(error_pipe[0]);
    if (n != 0) {
        fail("env exec error-pipe EOF", (int)n);
        return 1;
    }

    char out[512];
    size_t out_len = 0;
    if (read_to_eof(stdout_pipe[0], out, sizeof(out), &out_len) != 0) {
        fail("read stdout pipe", 0);
        return 1;
    }
    close(stdout_pipe[0]);

    int status = 0;
    if (waitpid(child, &status, 0) != child) {
        fail("waitpid env child", 0);
        return 1;
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 7) {
        fail("waitpid env status", status);
        printf("uvenvprobe: captured stdout: %s\n", out);
        return 1;
    }

    if (!contains(out, "envchild: getenv inherited OK") ||
        !contains(out, "envchild: envp/environ pointers OK") ||
        !contains(out, "ENVCHILD-OK")) {
        fail("env child stdout", (int)out_len);
        printf("uvenvprobe: captured stdout: %s\n", out);
        return 1;
    }
    printf("%s", out);
    if (out_len == 0 || out[out_len - 1] != '\n') {
        printf("\n");
    }
    printf("uvenvprobe: execvp custom env OK\n");
    return 0;
}

int main(void) {
    if (check_parent_env_mutation() != 0) {
        return 1;
    }
    if (run_exec_env() != 0) {
        return 1;
    }
    const char *parent = getenv("SWOS_ENV_PARENT_ONLY");
    if (!parent || strcmp(parent, "parent-value") != 0 ||
        getenv("SWOS_ENV_ALPHA") != 0) {
        fail("parent env preserved", 0);
        return 1;
    }
    printf("uvenvprobe: parent env preserved OK\n");
    printf("UVENVPROBE-OK\n");
    return 0;
}
