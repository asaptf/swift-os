// SPDX-License-Identifier: Apache-2.0
// swos-init.c - tiny boot init for configured foreground-independent services.
//
// This is deliberately not a full service manager. It reads immutable
// /etc/swos/services, starts a small allowlisted set of boot services with
// fork+exec, then replaces itself with /bin/console-login. Opt-in supervised
// service tokens keep swos-init alive as a restart loop for deploy preflights.
// Long-running child services inherit the boot principal/capabilities and keep
// logging to serial.

#include "lib/fs.h"
#include "lib/syscall.h"

int puts_raw(const char *s);

#define MAX_SUPERVISED_SERVICES 4
// Cap restarts for daemons that fail *at startup* with no external gating (nginx:
// a TLS/entropy failure fork-storms the kernel into a panic in a tight loop).
// After the cap we give up on that one service; others keep running.
//
// This cap is deliberately NOT applied to sshd: sshd is a long-running daemon
// that only exits when accept() returns an error, i.e. its restarts are gated by
// inbound connections and can never fork-storm. Capping it let internet scan
// traffic on a public IP exhaust the limit within minutes and permanently kill
// SSH. sshd therefore keeps the original unbounded-restart supervision.
#define MAX_RESTARTS_PER_SERVICE 5
#define SSHD_ONCE_MARKER "/tmp/swos-sshd-once"
#define SSHD_IPV6_MARKER "/tmp/swos-sshd-ipv6"

enum service_kind {
    SERVICE_SSHD = 1,
    SERVICE_SSHD_ONCE = 2,
    SERVICE_SSHD6 = 3,
    SERVICE_SSHD6_ONCE = 4,
    SERVICE_NGINX = 5,
};

struct supervised_service {
    enum service_kind kind;
    int pid;
    int restarts;
};

static struct supervised_service supervised[MAX_SUPERVISED_SERVICES];
static int supervised_count = 0;
static int supervision_requested = 0;

static int streq(const char *a, const char *b) {
    while (*a && *b && *a == *b) {
        a += 1;
        b += 1;
    }
    return *a == 0 && *b == 0;
}

static int is_space(char c) {
    return c == ' ' || c == '\t' || c == '\r';
}

static void print_uint(unsigned int v) {
    char buf[10];
    int n = 0;
    if (v == 0) {
        char z = '0';
        write(1, &z, 1);
        return;
    }
    while (v > 0 && n < (int)sizeof(buf)) {
        buf[n++] = (char)('0' + (v % 10));
        v /= 10;
    }
    while (n > 0) {
        n -= 1;
        write(1, &buf[n], 1);
    }
}

static const char *service_name(enum service_kind kind) {
    if (kind == SERVICE_NGINX) {
        return "nginx";
    }
    if (kind == SERVICE_SSHD_ONCE) {
        return "sshd-once";
    }
    if (kind == SERVICE_SSHD6_ONCE) {
        return "sshd6-once";
    }
    if (kind == SERVICE_SSHD6) {
        return "sshd6";
    }
    return "sshd";
}

static void create_marker(const char *path) {
    int fd = open(path, O_WRONLY | O_CREAT);
    if (fd < 0) {
        puts_raw("swos-init: could not create service marker\n");
        return;
    }
    (void)write(fd, "1\n", 2);
    close(fd);
}

static void prepare_sshd_mode(enum service_kind kind) {
    if (kind == SERVICE_SSHD_ONCE || kind == SERVICE_SSHD6_ONCE) {
        create_marker(SSHD_ONCE_MARKER);
    }
    if (kind == SERVICE_SSHD6 || kind == SERVICE_SSHD6_ONCE) {
        create_marker(SSHD_IPV6_MARKER);
    }
}

static int start_service(enum service_kind kind) {
    prepare_sshd_mode(kind);
    int pid = fork();
    if (pid < 0) {
        puts_raw("swos-init: fork failed for ");
        puts_raw(service_name(kind));
        puts_raw("\n");
        return -1;
    }
    if (pid == 0) {
        if (kind == SERVICE_NGINX) {
            char *argvn[] = { "nginx", "-c", "/usr/etc/nginx/nginx-prod.conf", 0 };
            execve("/sbin/nginx", argvn, 0);
            puts_raw("swos-init: exec /sbin/nginx failed\n");
            _exit(127);
        }
        char *argv4[] = { "sshd", 0 };
        char *argv6[] = { "sshd6", "-6", 0 };
        execve("/bin/sshd",
               (kind == SERVICE_SSHD6 || kind == SERVICE_SSHD6_ONCE) ? argv6 : argv4,
               0);
        puts_raw("swos-init: exec /bin/sshd failed\n");
        _exit(127);
    }
    puts_raw("swos-init: started ");
    puts_raw(service_name(kind));
    puts_raw(" pid ");
    print_uint((unsigned int)pid);
    puts_raw("\n");
    return pid;
}

static void start_sshd(void) {
    (void)start_service(SERVICE_SSHD);
}

// Seed / recover the persistent nginx docroot on /data before any service
// starts. Runs unconditionally (independent of /etc/swos/services) so a freshly
// flashed box, an empty /data, or a crash-interrupted update all resolve to a
// fully-populated /data/www/current ahead of nginx. Blocks until it exits.
static void seed_site(void) {
    int pid = fork();
    if (pid < 0) {
        puts_raw("swos-init: fork failed for swupdate seed\n");
        return;
    }
    if (pid == 0) {
        char *argv[] = { "swupdate", "seed", 0 };
        execve("/bin/swupdate", argv, 0);
        puts_raw("swos-init: exec /bin/swupdate failed\n");
        _exit(127);
    }
    int status = 0;
    (void)waitpid(pid, &status, 0);
}

static void add_supervised_service(enum service_kind kind) {
    if (supervised_count >= MAX_SUPERVISED_SERVICES) {
        puts_raw("swos-init: too many supervised services\n");
        return;
    }
    int pid = start_service(kind);
    if (pid < 0) {
        return;
    }
    supervised[supervised_count].kind = kind;
    supervised[supervised_count].pid = pid;
    supervised[supervised_count].restarts = 0;
    supervised_count += 1;
    supervision_requested = 1;
}

static void run_service_token(char *tok) {
    if (streq(tok, "sshd") || streq(tok, "/bin/sshd")) {
        start_sshd();
    } else if (streq(tok, "sshd6")) {
        (void)start_service(SERVICE_SSHD6);
    } else if (streq(tok, "sshd-supervised")) {
        add_supervised_service(SERVICE_SSHD);
    } else if (streq(tok, "sshd6-supervised")) {
        add_supervised_service(SERVICE_SSHD6);
    } else if (streq(tok, "sshd-once")) {
        add_supervised_service(SERVICE_SSHD_ONCE);
    } else if (streq(tok, "sshd6-once")) {
        add_supervised_service(SERVICE_SSHD6_ONCE);
    } else if (streq(tok, "nginx")) {
        (void)start_service(SERVICE_NGINX);
    } else if (streq(tok, "nginx-supervised")) {
        add_supervised_service(SERVICE_NGINX);
    } else {
        puts_raw("swos-init: unsupported service ");
        puts_raw(tok);
        puts_raw("\n");
    }
}

static void start_configured_services(void) {
    char buf[512];
    int fd = open("/etc/swos/services", O_RDONLY);
    if (fd < 0) {
        puts_raw("swos-init: no /etc/swos/services\n");
        return;
    }
    long n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) {
        puts_raw("swos-init: empty /etc/swos/services\n");
        return;
    }
    buf[n] = 0;

    long i = 0;
    while (i < n) {
        while (i < n && (buf[i] == '\n' || is_space(buf[i]))) {
            i += 1;
        }
        if (i >= n) {
            break;
        }
        if (buf[i] == '#') {
            while (i < n && buf[i] != '\n') {
                i += 1;
            }
            continue;
        }

        long start = i;
        while (i < n && buf[i] != '\n' && !is_space(buf[i])) {
            i += 1;
        }
        char saved = buf[i];
        buf[i] = 0;
        run_service_token(&buf[start]);
        buf[i] = saved;

        while (i < n && buf[i] != '\n') {
            i += 1;
        }
    }
}

// Only startup-failing daemons (nginx) are restart-capped; connection-gated
// services (sshd) restart without bound. See MAX_RESTARTS_PER_SERVICE above.
static int service_restart_is_capped(enum service_kind kind) {
    return kind == SERVICE_NGINX;
}

static int restart_supervised_pid(int pid, int status) {
    int i;
    for (i = 0; i < supervised_count; i += 1) {
        if (supervised[i].pid == pid) {
            if (service_restart_is_capped(supervised[i].kind)) {
                supervised[i].restarts += 1;
                if (supervised[i].restarts > MAX_RESTARTS_PER_SERVICE) {
                    puts_raw("swos-init: service ");
                    puts_raw(service_name(supervised[i].kind));
                    puts_raw(" crash-looped; giving up after ");
                    print_uint((unsigned int)MAX_RESTARTS_PER_SERVICE);
                    puts_raw(" restarts\n");
                    supervised[i].pid = -1;
                    return 1;
                }
            }
            puts_raw("swos-init: service ");
            puts_raw(service_name(supervised[i].kind));
            puts_raw(" pid ");
            print_uint((unsigned int)pid);
            puts_raw(" exited status ");
            print_uint((unsigned int)status);
            puts_raw("; restarting\n");
            supervised[i].pid = start_service(supervised[i].kind);
            return 1;
        }
    }
    return 0;
}

static int supervise_services_forever(void) {
    puts_raw("swos-init: supervision active\n");
    while (1) {
        int status = 0;
        int pid = waitpid(-1, &status, 0);
        if (pid < 0) {
            puts_raw("swos-init: supervision waitpid failed\n");
            return 1;
        }
        if (!restart_supervised_pid(pid, status)) {
            puts_raw("swos-init: child pid ");
            print_uint((unsigned int)pid);
            puts_raw(" exited outside service table\n");
        }
    }
}

int main(void) {
    puts_raw("swos-init: starting configured services\n");
    seed_site();
    start_configured_services();
    if (supervision_requested) {
        return supervise_services_forever();
    }
    puts_raw("swos-init: handoff to console-login\n");
    char *argv[] = { "console-login", 0 };
    execve("/bin/console-login", argv, 0);
    puts_raw("swos-init: exec /bin/console-login failed\n");
    return 1;
}
