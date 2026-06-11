// SPDX-License-Identifier: Apache-2.0
// swos-init.c - tiny boot init for configured foreground-independent services.
//
// This is deliberately not a full service manager. It reads immutable
// /etc/swos/services, starts a small allowlisted set of boot services with
// fork+exec, then replaces itself with /bin/console-login. Long-running child
// services inherit the boot principal/capabilities and keep logging to serial.

#include "lib/fs.h"
#include "lib/syscall.h"

int puts_raw(const char *s);

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

static void start_sshd(void) {
    int pid = fork();
    if (pid < 0) {
        puts_raw("swos-init: fork failed for sshd\n");
        return;
    }
    if (pid == 0) {
        char *argv[] = { "sshd", 0 };
        execve("/bin/sshd", argv, 0);
        puts_raw("swos-init: exec /bin/sshd failed\n");
        _exit(127);
    }
    puts_raw("swos-init: started sshd pid ");
    print_uint((unsigned int)pid);
    puts_raw("\n");
}

static void run_service_token(char *tok) {
    if (streq(tok, "sshd") || streq(tok, "/bin/sshd")) {
        start_sshd();
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

int main(void) {
    puts_raw("swos-init: starting configured services\n");
    start_configured_services();
    puts_raw("swos-init: handoff to console-login\n");
    char *argv[] = { "console-login", 0 };
    execve("/bin/console-login", argv, 0);
    puts_raw("swos-init: exec /bin/console-login failed\n");
    return 1;
}
