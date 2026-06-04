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

    return 0;
}
