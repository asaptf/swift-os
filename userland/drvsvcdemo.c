// drvsvcdemo.c - C5 restartable driver-service supervisor smoke.
//
// The supervisor starts a pseudo driver service twice, talks to it only over
// endpoint handles, transfers an opaque pseudo/virtio-input device handle,
// stops it, and proves a fresh generation recovers service.

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

static void cstr_copy(char *dst, const char *src, int cap) {
    int i = 0;
    while (i + 1 < cap && src[i] != 0) {
        dst[i] = src[i];
        i += 1;
    }
    dst[i] = 0;
}

struct device_expect {
    char name[24];
    int real;
};

static int c5c_real_device_seen = 0;
static int saw_virtio_input_metadata = 0;
static int c5e_authority_withheld_seen = 0;
static int c5f_metadata_rights_seen = 0;

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

static int is_real_virtio_input(const struct swiftos_device_info *info) {
    return info->kind == SWIFTOS_DEVICE_KIND_VIRTIO_INPUT &&
           info->bus == SWIFTOS_DEVICE_BUS_VIRTIO_MMIO &&
           info->mmio_base != 0 &&
           info->mmio_len != 0 &&
           (info->flags & SWIFTOS_DEVICE_FLAG_DISCOVERED) != 0 &&
           cstr_eq(info->name, "virtio-input.0");
}

static int is_pseudo_input(const struct swiftos_device_info *info) {
    return info->kind == SWIFTOS_DEVICE_KIND_PSEUDO_INPUT &&
           info->bus == SWIFTOS_DEVICE_BUS_PSEUDO &&
           info->mmio_base == 0 &&
           info->mmio_len == 0 &&
           cstr_eq(info->name, "pseudo-input.0");
}

static int hardware_authority_withheld(const struct swiftos_device_info *info) {
    return info->irq == 0 &&
           (info->flags & SWIFTOS_DEVICE_FLAG_NO_MMIO_GRANT) != 0 &&
           (info->flags & SWIFTOS_DEVICE_FLAG_HARDWARE_AUTHORITY) == 0;
}

static int valid_device_info(const struct swiftos_device_info *info, int real,
                             unsigned int claimed) {
    if (info->claimed != claimed) { return 0; }
    if (!hardware_authority_withheld(info)) { return 0; }
    return real ? is_real_virtio_input(info) : is_pseudo_input(info);
}

static int discover_input_device(struct swiftos_device_info *info,
                                 struct device_expect *expect) {
    int found = 0;
    for (int i = 0; i < 4; i += 1) {
        int r = device_discover(i, info);
        if (r == -2) { break; }
        if (r != 0) {
            puts_raw("drvsvc: device discovery failed\n");
            return 0;
        }
        if (valid_device_info(info, 1, 0)) {
            cstr_copy(expect->name, "virtio-input.0", sizeof(expect->name));
            expect->real = 1;
            found = 1;
            break;
        }
        if (valid_device_info(info, 0, 0)) {
            cstr_copy(expect->name, "pseudo-input.0", sizeof(expect->name));
            expect->real = 0;
            found = 1;
            break;
        }
    }
    if (!found) {
        puts_raw("drvsvc: device manifest mismatch\n");
        return 0;
    }
    puts_raw("drvsvc: C5c device manifest matched\n");
    if (expect->real) {
        saw_virtio_input_metadata = 1;
        puts_raw("drvsvc: C5d virtio-input metadata discovered\n");
    }

    struct swiftos_device_info extra;
    if (device_discover(1, &extra) != -2) {
        puts_raw("drvsvc: device discovery exhaustion failed\n");
        return 0;
    }
    puts_raw("drvsvc: C5c discovery exhausted\n");
    return 1;
}

static int run_device_handoff(int command_fd, int event_fd, struct device_expect *expect) {
    struct swiftos_device_info info;
    if (!discover_input_device(&info, expect)) {
        return 0;
    }

    int dev_fd = device_claim(expect->name, &info);
    if (dev_fd < 0) {
        puts_raw("drvsvc: device claim failed\n");
        return 0;
    }
    if (!valid_device_info(&info, expect->real, 1)) {
        close(dev_fd);
        puts_raw("drvsvc: device info mismatch\n");
        return 0;
    }
    c5e_authority_withheld_seen = 1;
    puts_raw("drvsvc: C5b device grant claimed\n");
    if (expect->real) {
        c5c_real_device_seen = 1;
        puts_raw("drvsvc: C5c virtio-input grant matched\n");
    }

    int dup_fd = dup(dev_fd);
    if (dup_fd != -13) {
        if (dup_fd >= 0) { close(dup_fd); }
        close(dev_fd);
        puts_raw("drvsvc: device dup unexpectedly succeeded\n");
        return 0;
    }
    c5f_metadata_rights_seen = 1;
    puts_raw("drvsvc: C5f device grant rights metadata-only\n");

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

    int busy_fd = device_claim(expect->name, &info);
    if (busy_fd != -16) {
        if (busy_fd >= 0) { close(busy_fd); }
        puts_raw("drvsvc: busy claim failed\n");
        return 0;
    }
    puts_raw("drvsvc: C5b device busy while service owns grant\n");
    return 1;
}

static int verify_device_reclaimed(const struct device_expect *expect) {
    struct swiftos_device_info info;
    int fd = device_claim(expect->name, &info);
    if (fd < 0) {
        puts_raw("drvsvc: reclaim claim failed\n");
        return 0;
    }
    if (!valid_device_info(&info, expect->real, 1)) {
        close(fd);
        puts_raw("drvsvc: reclaim info mismatch\n");
        return 0;
    }
    close(fd);
    puts_raw("drvsvc: C5b device grant reclaimed\n");
    if (expect->real) {
        puts_raw("drvsvc: C5c virtio-input grant reclaimed\n");
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

    struct device_expect expect;
    expect.name[0] = 0;
    expect.real = 0;
    if (gen == 2 && !run_device_handoff(supervisor_to_service[0],
                                        service_to_supervisor[1],
                                        &expect)) {
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

    if (gen == 2 && !verify_device_reclaimed(&expect)) {
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
    if (c5c_real_device_seen) {
        puts_raw("C5c OK: virtio-input device grant discovered and matched\n");
    } else {
        puts_raw("C5c OK: device discovery manifest matched pseudo input\n");
    }
    if (saw_virtio_input_metadata) {
        puts_raw("C5d OK: virtio input discovery metadata surfaced\n");
    }
    if (c5e_authority_withheld_seen) {
        puts_raw("C5e OK: device authority withheld until explicit handoff\n");
    }
    if (c5f_metadata_rights_seen) {
        puts_raw("C5f OK: device grant rights stayed metadata-only\n");
    }
    return 0;
}
