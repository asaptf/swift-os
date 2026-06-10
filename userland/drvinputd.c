// drvinputd.c - C5 pseudo driver service.
//
// This is deliberately not a real virtio-input driver yet. It is the smallest
// restartable service shape C5 needs: a process receives only endpoint/device
// handles, announces readiness, serves requests, and exits on supervisor command.

#include "lib/syscall.h"

int puts_raw(const char *s);

static int parse_u32(const char *s) {
    int v = 0;
    int i = 0;
    while (s[i] >= '0' && s[i] <= '9') {
        v = v * 10 + (s[i] - '0');
        i += 1;
    }
    return v;
}

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

static void gen_msg(char out[10], const char *prefix, int gen) {
    int i = 0;
    while (prefix[i] != 0) {
        out[i] = prefix[i];
        i += 1;
    }
    out[i] = (char)('0' + gen);
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

int main(int argc, char **argv) {
    if (argc < 4) {
        puts_raw("drvinputd: missing endpoint args\n");
        return 1;
    }

    int ready_fd = parse_u32(argv[1]);
    int command_fd = parse_u32(argv[2]);
    int gen = parse_u32(argv[3]);
    if (gen < 1 || gen > 9) {
        puts_raw("drvinputd: invalid generation\n");
        return 1;
    }

    char msg[10];
    gen_msg(msg, "DRVREADY", gen);
    if (ipc_send(ready_fd, msg, 9, -1) != 0) {
        puts_raw("drvinputd: ready send failed\n");
        return 1;
    }

    int device_fd = -1;
    while (1) {
        char cmd[8];
        int received_fd = -1;
        long n = ipc_recv(command_fd, cmd, sizeof(cmd), &received_fd);
        if (n < 0) {
            puts_raw("drvinputd: command receive failed\n");
            return 1;
        }
        if (n == 4 && streq_n(cmd, "PING", 4)) {
            if (received_fd >= 0) { close(received_fd); }
            gen_msg(msg, "DRVEVENT", gen);
            if (ipc_send(ready_fd, msg, 9, -1) != 0) {
                puts_raw("drvinputd: event send failed\n");
                return 1;
            }
        } else if (n == 4 && streq_n(cmd, "DEVH", 4)) {
            if (received_fd < 0) {
                puts_raw("drvinputd: device handle missing\n");
                return 1;
            }
            if (device_fd >= 0) {
                close(received_fd);
                puts_raw("drvinputd: duplicate device grant\n");
                return 1;
            }
            struct swiftos_device_info info;
            if (device_info(received_fd, &info) != 0) {
                close(received_fd);
                puts_raw("drvinputd: device info failed\n");
                return 1;
            }
            if (!valid_device_info(&info)) {
                close(received_fd);
                puts_raw("drvinputd: device info mismatch\n");
                return 1;
            }
            device_fd = received_fd;
            puts_raw("drvinputd: C5b device grant accepted\n");
            gen_msg(msg, "DEVACK", gen);
            if (ipc_send(ready_fd, msg, 7, -1) != 0) {
                puts_raw("drvinputd: device ack send failed\n");
                return 1;
            }
        } else if (n == 4 && streq_n(cmd, "STOP", 4)) {
            if (received_fd >= 0) { close(received_fd); }
            if (device_fd >= 0) { close(device_fd); }
            return 40 + gen;
        } else {
            if (received_fd >= 0) { close(received_fd); }
            puts_raw("drvinputd: unknown command\n");
            return 1;
        }
    }
}
