// drvsvcdemo.c - C5 restartable driver-service supervisor smoke.
//
// The supervisor starts a pseudo driver service twice, talks to it only over
// endpoint handles, transfers an opaque device handle, stops it, and proves a
// fresh generation recovers service.

#include "lib/syscall.h"

int puts_raw(const char *s);

static int streq_n(const char *a, const char *b, int n) {
    for (int i = 0; i < n; i += 1) {
        if (a[i] != b[i]) { return 0; }
    }
    return 1;
}

static int cstr_eq(const char *a, const char *b) {
    int i = 0;
    while (a[i] != 0 && b[i] != 0) {
        if (a[i] != b[i]) { return 0; }
        i += 1;
    }
    return a[i] == b[i];
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

static int valid_device_info(const struct swiftos_device_info *info) {
    return info->kind == SWIFTOS_DEVICE_KIND_PSEUDO_INPUT &&
           info->bus == SWIFTOS_DEVICE_BUS_PSEUDO &&
           info->mmio_base == 0 &&
           info->mmio_len == 0 &&
           (info->flags & SWIFTOS_DEVICE_FLAG_NO_MMIO_GRANT) != 0 &&
           info->claimed == 1 &&
           cstr_eq(info->name, "pseudo-input.0");
}

static int run_device_handoff(int command_fd, int event_fd) {
    struct swiftos_device_info info;
    int dev_fd = device_claim("pseudo-input.0", &info);
    if (dev_fd < 0) {
        puts_raw("drvsvc: device claim failed\n");
        return 0;
    }
    if (!valid_device_info(&info)) {
        close(dev_fd);
        puts_raw("drvsvc: device info mismatch\n");
        return 0;
    }
    puts_raw("drvsvc: C5b device grant claimed\n");

    int dup_fd = dup(dev_fd);
    if (dup_fd != -13) {
        if (dup_fd >= 0) { close(dup_fd); }
        close(dev_fd);
        puts_raw("drvsvc: device dup unexpectedly succeeded\n");
        return 0;
    }

    if (ipc_send(command_fd, "DEVH", 4, dev_fd) != 0) {
        close(dev_fd);
        puts_raw("drvsvc: device grant send failed\n");
        return 0;
    }
    if (device_info(dev_fd, &info) != -9) {
        close(dev_fd);
        puts_raw("drvsvc: moved device fd still valid\n");
        return 0;
    }
    puts_raw("drvsvc: C5b device grant moved\n");

    if (!expect_msg(event_fd, "DEVACK2", 7,
                    "drvsvc: device ack mismatch\n")) {
        return 0;
    }

    int busy_fd = device_claim("pseudo-input.0", &info);
    if (busy_fd != -16) {
        if (busy_fd >= 0) { close(busy_fd); }
        puts_raw("drvsvc: busy claim failed\n");
        return 0;
    }
    puts_raw("drvsvc: C5b device busy while service owns grant\n");
    return 1;
}

static int verify_device_reclaimed(void) {
    struct swiftos_device_info info;
    int fd = device_claim("pseudo-input.0", &info);
    if (fd < 0) {
        puts_raw("drvsvc: reclaim claim failed\n");
        return 0;
    }
    if (!valid_device_info(&info)) {
        close(fd);
        puts_raw("drvsvc: reclaim info mismatch\n");
        return 0;
    }
    close(fd);
    puts_raw("drvsvc: C5b device grant reclaimed\n");
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

    if (gen == 2 && !run_device_handoff(supervisor_to_service[0],
                                        service_to_supervisor[1])) {
        return 0;
    }

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

    if (gen == 2 && !verify_device_reclaimed()) {
        return 0;
    }

    close(service_to_supervisor[1]);
    close(supervisor_to_service[0]);
    return 1;
}

int main(void) {
    puts_raw("drvsvc: C5a supervisor starting\n");
    if (!run_generation(1)) { return 1; }
    if (!run_generation(2)) { return 1; }
    puts_raw("C5a OK: restartable driver service recovered over IPC\n");
    puts_raw("C5b OK: opaque device handle transferred and released\n");
    return 0;
}
