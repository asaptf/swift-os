// fsdemo.c — M8b VFS demo: exercise the directory/stat/getdents/cwd/tmpfs API.
//
// Stands in for ls/cat/echo until busybox is built: lists a directory, cats a
// file, stats a file, changes directory, and writes+reads a tmpfs file.

#include "lib/syscall.h"
#include "lib/fs.h"

int puts_raw(const char *s);

int main(void) {
    char buf[256];

    getcwd(buf, sizeof(buf));
    puts_raw("cwd=");
    puts_raw(buf);
    puts_raw("\n");

    puts_raw("ls /:\n");
    int fd = open("/", O_RDONLY);
    long n;
    while ((n = getdents(fd, buf, sizeof(buf))) > 0) {
        long off = 0;
        while (off < n) {
            struct dirent *d = (struct dirent *)(buf + off);
            puts_raw("  ");
            puts_raw(d->d_name);
            puts_raw("\n");
            off += d->d_reclen;
        }
    }
    close(fd);

    puts_raw("cat /etc/motd: ");
    fd = open("/etc/motd", O_RDONLY);
    while ((n = read(fd, buf, sizeof(buf))) > 0) {
        write(1, buf, (size_t)n);
    }
    close(fd);

    struct stat st;
    stat("/etc/hostname", &st);
    puts_raw("/etc/hostname size=");
    char c = (char)('0' + (st.st_size % 10));
    write(1, &c, 1);
    puts_raw("\n");

    chdir("/etc");
    getcwd(buf, sizeof(buf));
    puts_raw("cwd2=");
    puts_raw(buf);
    puts_raw("\n");

    fd = open("/tmp/note", O_WRONLY | O_CREAT);
    write(fd, "hi-tmpfs\n", 9);
    close(fd);
    fd = open("/tmp/note", O_RDONLY);
    puts_raw("tmp/note: ");
    while ((n = read(fd, buf, sizeof(buf))) > 0) {
        write(1, buf, (size_t)n);
    }
    close(fd);

    // C3: confine FS access to /etc and prove path operations cannot escape it.
    if (confine("/etc") != 0) {
        puts_raw("C3-SCOPE-CONFINE-FAIL\n");
        return 1;
    }
    int cin = open("/etc/motd", O_RDONLY);
    if (cin >= 0) {
        puts_raw("CONFINE-IN-OK\n");
        puts_raw("C3-SCOPE-IN-OK\n");
        close(cin);
    } else {
        puts_raw("CONFINE-IN-FAIL\n");
        puts_raw("C3-SCOPE-IN-FAIL\n");
        return 1;
    }
    int cout = open("/bin/ps", O_RDONLY);
    if (cout == -13) {
        puts_raw("CONFINE-OUT-OK\n");
        puts_raw("C3-SCOPE-OPEN-OUT-OK err=-13\n");
    } else {
        puts_raw("CONFINE-OUT-LEAK\n");
        puts_raw("C3-SCOPE-OPEN-OUT-LEAK\n");
        if (cout >= 0) close(cout);
        return 1;
    }
    if (stat("/bin/ps", &st) == -13) {
        puts_raw("C3-SCOPE-STAT-OUT-OK err=-13\n");
    } else {
        puts_raw("C3-SCOPE-STAT-OUT-LEAK\n");
        return 1;
    }
    if (confine("/") == -13) {
        puts_raw("C3-SCOPE-WIDEN-OK err=-13\n");
    } else {
        puts_raw("C3-SCOPE-WIDEN-LEAK\n");
        return 1;
    }
    int created = open("/tmp/c3-out", O_WRONLY | O_CREAT);
    if (created == -13) {
        puts_raw("C3-SCOPE-CREATE-OUT-OK err=-13\n");
    } else {
        puts_raw("C3-SCOPE-CREATE-OUT-LEAK\n");
        if (created >= 0) close(created);
        return 1;
    }
    puts_raw("C3-SCOPE-OK\n");

    return 0;
}
