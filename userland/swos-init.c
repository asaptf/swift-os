// SPDX-License-Identifier: Apache-2.0
// swos-init.c - tiny boot init for configured foreground-independent services.
//
// This is deliberately not a full service manager. It reads immutable
// /etc/swos/services, starts a small allowlisted set of boot services with
// fork+exec, then starts /bin/console-login as a child. Opt-in supervised
// service tokens restart children that exit; the console session stays available
// either way. Long-running children inherit the boot principal/capabilities and
// keep logging to serial.
//
// Restart policy is rate-based, not kind-based. A child that dies soon after
// start is treated as a startup failure: consecutive quick deaths are counted
// and the service is given up on after MAX_RESTARTS_PER_SERVICE. A child that
// ran for at least MIN_SUCCESSFUL_RUN_SECS before exiting (e.g. sshd after a
// real session, or sshd-once after accept) is restarted immediately with the
// consecutive-failure counter reset — so legitimate long-run restarts stay
// unbounded and prompt. Elapsed time comes from SYS_SYSINFO uptime ticks.

#include "lib/fs.h"
#include "lib/syscall.h"

int puts_raw(const char *s);

#define MAX_SUPERVISED_SERVICES 6
// Consecutive *quick* deaths (lived < MIN_SUCCESSFUL_RUN_SECS) before giving up.
// Matches the historical nginx crash-loop report wording ("after N restarts").
#define MAX_RESTARTS_PER_SERVICE 5
// A service that lived at least this long is not a startup failure: reset the
// consecutive-failure counter and restart immediately (no cap).
#define MIN_SUCCESSFUL_RUN_SECS 2u
#define SSHD_ONCE_MARKER "/tmp/swos-sshd-once"
#define SSHD_IPV6_MARKER "/tmp/swos-sshd-ipv6"

enum service_kind {
    SERVICE_SSHD = 1,
    SERVICE_SSHD_ONCE = 2,
    SERVICE_SSHD6 = 3,
    SERVICE_SSHD6_ONCE = 4,
    SERVICE_NGINX = 5,
    SERVICE_CROND = 6,
    SERVICE_INPUTD = 7,   // C5j: persistent userland virtio-input driver
    SERVICE_LLMD = 8,
    SERVICE_FALSE = 9,    // child exits immediately — rate-policy regression probe
};

struct supervised_service {
    enum service_kind kind;
    int pid;
    int restarts;
    unsigned long start_tick;  // SYS_SYSINFO uptime_ticks when last started
};

static struct supervised_service supervised[MAX_SUPERVISED_SERVICES];
static int supervised_count = 0;
static int supervision_requested = 0;

// Monotonic uptime ticks from SYS_SYSINFO (legacy layout: u64 at offset 0,
// hz:u32 at offset 48). Falls back to 0 ticks / 100 Hz if the call fails.
static unsigned long mono_ticks(unsigned int *out_hz) {
    unsigned char raw[64];
    unsigned long ticks = 0;
    unsigned int hz = 100;
    if (__syscall3(SYS_SYSINFO, (long)raw, (long)sizeof(raw), 0) >= 0) {
        __builtin_memcpy(&ticks, raw, sizeof(ticks));
        __builtin_memcpy(&hz, raw + 48, sizeof(hz));
        if (hz == 0) {
            hz = 100;
        }
    }
    if (out_hz) {
        *out_hz = hz;
    }
    return ticks;
}

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
    if (kind == SERVICE_CROND) {
        return "crond";
    }
    if (kind == SERVICE_NGINX) {
        return "nginx";
    }
    if (kind == SERVICE_INPUTD) {
        return "inputd";
    }
    if (kind == SERVICE_LLMD) {
        return "llmd";
    }
    if (kind == SERVICE_FALSE) {
        return "false";
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
        // Immediate exit — used by the rate-based restart regression test so a
        // supervised child dies well under MIN_SUCCESSFUL_RUN_SECS without
        // depending on network or external config.
        if (kind == SERVICE_FALSE) {
            _exit(1);
        }
        if (kind == SERVICE_CROND) {
            char *argvc[] = { "crond", 0 };
            execve("/bin/crond", argvc, 0);
            puts_raw("swos-init: exec /bin/crond failed\n");
            _exit(127);
        }
        if (kind == SERVICE_NGINX) {
            char *argvn[] = { "nginx", "-c", "/usr/etc/nginx/nginx-prod.conf", 0 };
            execve("/sbin/nginx", argvn, 0);
            puts_raw("swos-init: exec /sbin/nginx failed\n");
            _exit(127);
        }
        if (kind == SERVICE_INPUTD) {
            char *argvi[] = { "inputd", 0 };
            execve("/bin/inputd", argvi, 0);
            puts_raw("swos-init: exec /bin/inputd failed\n");
            _exit(127);
        }
        if (kind == SERVICE_LLMD) {
            char *argvl[] = { "llmd", 0 };
            execve("/bin/llmd", argvl, 0);
            puts_raw("swos-init: exec /bin/llmd failed\n");
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

// INCLUDE_OS_STAGE_TEST: when the baked marker is present, apply the tiny SWSYS
// fixture once at boot (headless — no host serial input). Gates like
// hetzner_os_update_test.sh assert the coordinated ESP activate markers on UART.
static void apply_os_stage_test_fixture(void) {
    if (open("/usr/share/swupdate-test/run-os-apply-local-at-boot", O_RDONLY) < 0) {
        return;
    }
    int pid = fork();
    if (pid < 0) {
        puts_raw("swos-init: fork failed for os stage test apply\n");
        return;
    }
    if (pid == 0) {
        char *argv[] = {
            "swupdate", "os-apply-local", "/usr/share/swupdate-test/os.swsys", 0
        };
        execve("/bin/swupdate", argv, 0);
        puts_raw("swos-init: exec swupdate os-apply-local failed\n");
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
    supervised[supervised_count].start_tick = mono_ticks(0);
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
    } else if (streq(tok, "crond") || streq(tok, "/bin/crond")) {
        (void)start_service(SERVICE_CROND);
    } else if (streq(tok, "crond-supervised")) {
        add_supervised_service(SERVICE_CROND);
    } else if (streq(tok, "inputd") || streq(tok, "/bin/inputd")) {
        (void)start_service(SERVICE_INPUTD);
    } else if (streq(tok, "llmd") || streq(tok, "/bin/llmd")) {
        (void)start_service(SERVICE_LLMD);
    } else if (streq(tok, "llmd-supervised")) {
        add_supervised_service(SERVICE_LLMD);
    } else if (streq(tok, "false-supervised")) {
        add_supervised_service(SERVICE_FALSE);
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

// Decide whether this exit counts as a startup failure (quick death) or a
// completed run (long enough life). Quick deaths feed the consecutive-failure
// cap; long runs clear it and restart without bound.
static int restart_supervised_pid(int pid, int status) {
    int i;
    for (i = 0; i < supervised_count; i += 1) {
        if (supervised[i].pid == pid) {
            unsigned int hz = 100;
            unsigned long now = mono_ticks(&hz);
            unsigned long lived = 0;
            if (now >= supervised[i].start_tick) {
                lived = now - supervised[i].start_tick;
            }
            unsigned long min_ticks = (unsigned long)hz * (unsigned long)MIN_SUCCESSFUL_RUN_SECS;
            if (lived < min_ticks) {
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
            } else {
                // Legitimate long run (session served, etc.): unbounded restart.
                supervised[i].restarts = 0;
            }
            puts_raw("swos-init: service ");
            puts_raw(service_name(supervised[i].kind));
            puts_raw(" pid ");
            print_uint((unsigned int)pid);
            puts_raw(" exited status ");
            print_uint((unsigned int)status);
            puts_raw("; restarting\n");
            supervised[i].pid = start_service(supervised[i].kind);
            if (supervised[i].pid >= 0) {
                supervised[i].start_tick = mono_ticks(0);
            }
            return 1;
        }
    }
    return 0;
}

int main(void) {
    puts_raw("swos-init: starting configured services\n");
    seed_site();
    apply_os_stage_test_fixture();
    start_configured_services();
    if (supervision_requested) {
        puts_raw("swos-init: supervision active\n");
    }
    // Run the interactive console login as a CHILD (a sibling of the daemons),
    // rather than execve-ing it in place. If swos-init *became* the shell (the
    // old handoff), the shell would be the parent of sshd/crond, and busybox
    // ash's blocking wait(-1) would hang forever on a never-exiting daemon child
    // after a foreground command exits (see docs/NOTES.md, CR2). As a child the
    // shell only ever parents its own foreground jobs. swos-init reaps any daemon
    // that exits during the session (and restarts supervised ones under the
    // rate-based policy above); when the login child ends it exits with that
    // code — so slot0 exits and the kernel prints "M12c: session ended" and
    // restarts init exactly as before. Supervision and console-login run
    // together so a crash-looping service cannot starve the login prompt.
    puts_raw("swos-init: starting console-login session\n");
    int login = fork();
    if (login < 0) {
        puts_raw("swos-init: fork console-login failed\n");
        return 1;
    }
    if (login == 0) {
        char *argv[] = { "console-login", 0 };
        execve("/bin/console-login", argv, 0);
        puts_raw("swos-init: exec /bin/console-login failed\n");
        _exit(127);
    }
    for (;;) {
        int status = 0;
        int pid = waitpid(-1, &status, 0);
        if (pid < 0) {
            puts_raw("swos-init: session waitpid failed\n");
            return 1;
        }
        if (pid == login) {
            return (status >> 8) & 0xff;   // session over -> slot0 exits
        }
        // Supervised daemon exit → rate-based restart (or give up). Unsupervised
        // daemons are simply reaped; keep serving the login session either way.
        if (!restart_supervised_pid(pid, status) && supervision_requested) {
            puts_raw("swos-init: child pid ");
            print_uint((unsigned int)pid);
            puts_raw(" exited outside service table\n");
        }
    }
}
