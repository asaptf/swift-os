// uvatforkprobe.c - C/newlib pthread_atfork ordering proof for libuv.

#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

struct child_report {
    int ok;
    int seq;
    int prepare_count;
    int prepare_order[4];
    int parent_count;
    int child_count;
    int child_order[4];
};

static int report_pipe[2] = { -1, -1 };
static int seq;
static int prepare_count;
static int prepare_order[4];
static int parent_count;
static int parent_order[4];
static int child_count;
static int child_order[4];

static void fail(const char *label, int detail) {
    printf("uvatforkprobe: FAIL: %s detail=%d errno=%d\n", label, detail, errno);
}

static int order_is_21(const int order[4], int count) {
    return count == 2 && order[0] == 2 && order[1] == 1;
}

static int order_is_12(const int order[4], int count) {
    return count == 2 && order[0] == 1 && order[1] == 2;
}

static void prepare1(void) {
    prepare_order[prepare_count++] = 1;
    seq = seq * 10 + 1;
}

static void prepare2(void) {
    prepare_order[prepare_count++] = 2;
    seq = seq * 10 + 2;
}

static void parent1(void) {
    parent_order[parent_count++] = 1;
}

static void parent2(void) {
    parent_order[parent_count++] = 2;
}

static void child1(void) {
    child_order[child_count++] = 1;
}

static void child2(void) {
    child_order[child_count++] = 2;
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

static int read_full(int fd, void *buf, size_t len) {
    char *p = (char *)buf;
    while (len > 0) {
        ssize_t n = read(fd, p, len);
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

static void child_main(void) {
    struct child_report report;
    memset(&report, 0, sizeof(report));
    report.seq = seq;
    report.prepare_count = prepare_count;
    report.prepare_order[0] = prepare_order[0];
    report.prepare_order[1] = prepare_order[1];
    report.parent_count = parent_count;
    report.child_count = child_count;
    report.child_order[0] = child_order[0];
    report.child_order[1] = child_order[1];
    report.ok = seq == 21 &&
                order_is_21(prepare_order, prepare_count) &&
                parent_count == 0 &&
                order_is_12(child_order, child_count);

    close(report_pipe[0]);
    (void)write_full(report_pipe[1], &report, sizeof(report));
    close(report_pipe[1]);
    _exit(report.ok ? 0 : 3);
}

int main(void) {
    int r = pthread_atfork(prepare1, parent1, child1);
    if (r != 0) {
        fail("pthread_atfork register 1", r);
        return 1;
    }
    r = pthread_atfork(prepare2, parent2, child2);
    if (r != 0) {
        fail("pthread_atfork register 2", r);
        return 1;
    }
    if (pipe(report_pipe) != 0) {
        fail("report pipe", 0);
        return 1;
    }

    pid_t child = fork();
    if (child < 0) {
        fail("fork", 0);
        return 1;
    }
    if (child == 0) {
        child_main();
    }

    close(report_pipe[1]);

    if (seq != 21 || !order_is_21(prepare_order, prepare_count)) {
        fail("prepare reverse order", seq);
        return 1;
    }
    printf("uvatforkprobe: prepare reverse order OK\n");

    if (!order_is_12(parent_order, parent_count) || child_count != 0) {
        fail("parent handler order", parent_count);
        return 1;
    }
    printf("uvatforkprobe: parent handler order OK\n");

    struct child_report report;
    memset(&report, 0, sizeof(report));
    if (read_full(report_pipe[0], &report, sizeof(report)) != 0) {
        fail("read child report", 0);
        return 1;
    }
    close(report_pipe[0]);

    int status = 0;
    if (waitpid(child, &status, 0) != child) {
        fail("waitpid child", 0);
        return 1;
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0 || !report.ok ||
        report.seq != 21 ||
        !order_is_21(report.prepare_order, report.prepare_count) ||
        report.parent_count != 0 ||
        !order_is_12(report.child_order, report.child_count)) {
        fail("child handler order", status);
        printf("uvatforkprobe: child seq=%d prepare=%d,%d/%d parent=%d child=%d,%d/%d ok=%d\n",
               report.seq,
               report.prepare_order[0], report.prepare_order[1], report.prepare_count,
               report.parent_count,
               report.child_order[0], report.child_order[1], report.child_count,
               report.ok);
        return 1;
    }
    printf("uvatforkprobe: child handler order OK\n");
    printf("uvatforkprobe: copy-on-write isolation OK\n");
    printf("UVATFORKPROBE-OK\n");
    return 0;
}
