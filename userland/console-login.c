// console-login.c — authenticate a principal from the base-image identity
// store, then hand off to the user's shell (M12b).
//
// Reads /etc/swos/passwd (name:principal:session:caps:password:shell), prompts
// for a login name and password on the console, and on a match calls login()
// to adopt that principal/session/capability context before execve()'ing the
// shell. login() is privileged (needs CAP_CONSOLE), which this process inherits
// from the boot context; the shell then runs with the authenticated context.
//
// Passwords are compared in plaintext for bring-up; hashing is a later step.
// The password prompt echoes for now (no termios juggling yet).

#include "lib/syscall.h"

#define STORE_PATH "/etc/swos/passwd"
#define LINEMAX 128
#define STOREMAX 4096

static unsigned long ustrlen(const char *s) {
    unsigned long n = 0;
    while (s[n]) n++;
    return n;
}

static void puts1(const char *s) { write(1, s, ustrlen(s)); }

static void put_uint(unsigned long v) {
    char buf[20];
    int i = 20;
    buf[--i] = 0;
    if (v == 0) buf[--i] = '0';
    while (v && i > 0) { buf[--i] = (char)('0' + v % 10); v /= 10; }
    write(1, buf + i, ustrlen(buf + i));
}

// Read one line from fd 0 into buf (canonical tty: one read == one line).
// Strips a trailing newline. Returns the length, or -1 on EOF/error.
static int read_line(char *buf, int max) {
    long n = read(0, buf, max - 1);
    if (n <= 0) return -1;
    if (buf[n - 1] == '\n') n--;
    buf[n] = 0;
    return (int)n;
}

// Compare NUL-terminated a with the [b, b+len) slice (exact length match).
static int field_eq(const char *a, const char *b, int len) {
    int i = 0;
    for (; i < len; i++) {
        if (a[i] == 0 || a[i] != b[i]) return 0;
    }
    return a[i] == 0;
}

static unsigned long parse_uint(const char *p, int len) {
    unsigned long v = 0;
    for (int i = 0; i < len; i++) {
        if (p[i] < '0' || p[i] > '9') break;
        v = v * 10 + (unsigned long)(p[i] - '0');
    }
    return v;
}

// Split a store line into up to 6 ':'-separated fields; returns field count.
static int split_fields(char *line, int len, const char **fp, int *flen) {
    int n = 0, start = 0;
    for (int i = 0; i <= len && n < 6; i++) {
        if (i == len || line[i] == ':') {
            fp[n] = line + start;
            flen[n] = i - start;
            n++;
            start = i + 1;
        }
    }
    return n;
}

static char g_store[STOREMAX];

int main(void) {
    int fd = open(STORE_PATH, 0);
    if (fd < 0) {
        puts1("console-login: cannot open " STORE_PATH "\n");
        return 1;
    }
    int total = 0;
    for (;;) {
        long r = read(fd, g_store + total, STOREMAX - 1 - total);
        if (r <= 0) break;
        total += (int)r;
        if (total >= STOREMAX - 1) break;
    }
    close(fd);
    g_store[total] = 0;

    char name[LINEMAX], pass[LINEMAX];
    for (;;) {
        puts1("\nswift-os login: ");
        if (read_line(name, LINEMAX) < 0) return 0; // EOF
        if (name[0] == 0) continue;
        puts1("Password: ");
        if (read_line(pass, LINEMAX) < 0) return 0;

        // Walk the store line by line looking for name+password.
        int i = 0;
        while (i < total) {
            int j = i;
            while (j < total && g_store[j] != '\n') j++;
            int len = j - i;
            char *line = g_store + i;
            i = j + 1;
            if (len == 0 || line[0] == '#') continue;

            const char *fp[6];
            int flen[6];
            if (split_fields(line, len, fp, flen) < 6) continue;
            if (!field_eq(name, fp[0], flen[0])) continue;
            if (!field_eq(pass, fp[4], flen[4])) continue;

            // Authenticated: adopt the principal and run the shell.
            unsigned int principal = (unsigned int)parse_uint(fp[1], flen[1]);
            unsigned int session = (unsigned int)parse_uint(fp[2], flen[2]);
            unsigned long caps = parse_uint(fp[3], flen[3]);
            if (login(principal, session, caps) != 0) {
                puts1("console-login: login() denied\n");
                return 1;
            }
            puts1("Welcome to swift-os, ");
            puts1(name);
            puts1("\n");

            // Report the kernel-side context we just adopted (proves login took).
            struct security_info si;
            if (security_info(&si) == 0) {
                puts1("session: principal=");
                put_uint(si.principal);
                puts1(" session=");
                put_uint(si.session);
                puts1(" caps=");
                put_uint(si.caps);
                puts1("\n");
            }

            // shell path is field 5 (NUL-terminate it in place).
            char shell[LINEMAX];
            int sl = flen[5] < LINEMAX - 1 ? flen[5] : LINEMAX - 1;
            for (int k = 0; k < sl; k++) shell[k] = fp[5][k];
            shell[sl] = 0;

            char arg0[] = "sh";
            char *argv[] = { arg0, 0 };
            execve(shell, argv, 0);
            puts1("console-login: exec of shell failed\n");
            return 1;
        }
        puts1("Login incorrect\n");
    }
}
