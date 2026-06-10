// drvsvcdemo.c - C5a restartable driver-service supervisor smoke.
//
// The supervisor starts a pseudo driver service twice, talks to it only over
// endpoint handles, stops it, and proves a fresh generation recovers service.

#include "lib/syscall.h"

int puts_raw(const char *s);

static int streq_n(const char *a, const char *b, int n) {
    for (int i = 0; i < n; i += 1) {
        if (a[i] != b[i]) { return 0; }
    }
    return 1;
}

static void u32_to_str(int v, char out[12]) {
    char tmp[12];
    int n = 0;
    if (v == 0) {
        out[0] = '0';
        out[1] = 0;
        return;
    }
    while (v > 0 && n < 11) {
        tmp[n++] = (char)('0' + (v % 10));
        v /= 10;
    }
    for (int i = 0; i < n; i += 1) {
        out[i] = tmp[n - i - 1];
    }
    out[n] = 0;
}

static int expect_msg(int fd, const char *want, int len, const char *fail) {
    char buf[16];
    int received_fd = -1;
    long n = ipc_recv(fd, buf, sizeof(buf), &received_fd);
    if (received_fd >= 0) {
        close(received_fd);
    }
    if (n != len || !streq_n(buf, want, len)) {
        puts_raw(fail);
        return 0;
    }
    return 1;
}

static int run_generation(int gen) {
    int service_to_supervisor[2];
    int supervisor_to_service[2];
    if (endpoint_create(service_to_supervisor) != 0 ||
        endpoint_create(supervisor_to_service) != 0) {
        puts_raw("drvsvc: endpoint_create failed\n");
        return 0;
    }

    int pid = fork();
    if (pid < 0) {
        puts_raw("drvsvc: fork failed\n");
        return 0;
    }

    if (pid == 0) {
        close(service_to_supervisor[1]);
        close(supervisor_to_service[0]);

        char ready_fd[12];
        char command_fd[12];
        char gen_arg[12];
        u32_to_str(service_to_supervisor[0], ready_fd);
        u32_to_str(supervisor_to_service[1], command_fd);
        u32_to_str(gen, gen_arg);

        char *argv[] = { "/bin/drvinputd", ready_fd, command_fd, gen_arg, 0 };
        execve("/bin/drvinputd", argv, 0);
        puts_raw("drvsvc: exec drvinputd failed\n");
        return 1;
    }

    close(service_to_supervisor[0]);
    close(supervisor_to_service[1]);

    char ready[10] = "DRVREADY0";
    ready[8] = (char)('0' + gen);
    if (!expect_msg(service_to_supervisor[1], ready, 9,
                    "drvsvc: ready message mismatch\n")) {
        return 0;
    }
    puts_raw(gen == 1 ? "drvsvc: generation 1 ready\n"
                      : "drvsvc: generation 2 ready\n");

    if (ipc_send(supervisor_to_service[0], "PING", 4, -1) != 0) {
        puts_raw("drvsvc: ping send failed\n");
        return 0;
    }
    char event[10] = "DRVEVENT0";
    event[8] = (char)('0' + gen);
    if (!expect_msg(service_to_supervisor[1], event, 9,
                    "drvsvc: event message mismatch\n")) {
        return 0;
    }
    puts_raw(gen == 1 ? "drvsvc: generation 1 event\n"
                      : "drvsvc: generation 2 event\n");

    if (ipc_send(supervisor_to_service[0], "STOP", 4, -1) != 0) {
        puts_raw("drvsvc: stop send failed\n");
        return 0;
    }
    int status = 0;
    int waited = waitpid(pid, &status, 0);
    if (waited != pid || ((status >> 8) & 0xff) != 40 + gen) {
        puts_raw("drvsvc: service wait failed\n");
        return 0;
    }
    puts_raw(gen == 1 ? "drvsvc: generation 1 stopped\n"
                      : "drvsvc: generation 2 stopped\n");

    close(service_to_supervisor[1]);
    close(supervisor_to_service[0]);
    return 1;
}

int main(void) {
    puts_raw("drvsvc: C5a supervisor starting\n");
    if (!run_generation(1)) { return 1; }
    if (!run_generation(2)) { return 1; }
    puts_raw("C5a OK: restartable driver service recovered over IPC\n");
    return 0;
}
