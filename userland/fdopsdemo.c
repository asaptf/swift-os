// fdopsdemo.c — M8e demo: real dup/dup2, pipe, poll, and tmpfs mutations.

#include "lib/syscall.h"
#include "lib/fs.h"

#define POLLIN  0x001
#define POLLOUT 0x004

struct pollfd {
    int fd;
    short events;
    short revents;
};

int puts_raw(const char *s);

static int streq(const char *a, const char *b) {
    int i = 0;
    while (a[i] && b[i]) {
        if (a[i] != b[i]) { return 0; }
        i++;
    }
    return a[i] == b[i];
}

static int poll(struct pollfd *fds, unsigned long nfds, int timeout) {
    return (int)__syscall3(SYS_POLL, (long)fds, (long)nfds, timeout);
}

int main(void) {
    if (mkdir("/tmp/fdops", 0777) != 0) {
        puts_raw("fdopsdemo: mkdir failed\n");
        return 1;
    }

    int fd = open("/tmp/fdops/a", O_CREAT | O_RDWR);
    if (fd < 0 || write(fd, "abc", 3) != 3) {
        puts_raw("fdopsdemo: create/write failed\n");
        return 1;
    }

    int fd2 = dup(fd);
    if (fd2 < 0 || write(fd2, "DEF", 3) != 3) {
        puts_raw("fdopsdemo: dup shared write failed\n");
        return 1;
    }
    if (lseek(fd, 0, 0) != 0) {
        puts_raw("fdopsdemo: lseek failed\n");
        return 1;
    }
    char buf[32];
    long n = read(fd2, buf, 6);
    buf[n] = 0;
    if (n != 6 || !streq(buf, "abcDEF")) {
        puts_raw("fdopsdemo: dup offset mismatch\n");
        return 1;
    }
    if (dup2(fd, 9) != 9 || close(fd) != 0 || close(fd2) != 0 || close(9) != 0) {
        puts_raw("fdopsdemo: dup2/close failed\n");
        return 1;
    }
    puts_raw("fdopsdemo: dup/dup2 shared offsets OK\n");

    int p[2];
    if (pipe(p) != 0) {
        puts_raw("fdopsdemo: pipe failed\n");
        return 1;
    }
    int pid = fork();
    if (pid < 0) {
        puts_raw("fdopsdemo: fork failed\n");
        return 1;
    }
    if (pid == 0) {
        close(p[0]);
        if (write(p[1], "pipe-ok", 7) != 7) { return 2; }
        close(p[1]);
        return 0;
    }
    close(p[1]);
    struct pollfd pf;
    pf.fd = p[0];
    pf.events = POLLIN;
    pf.revents = 0;
    if (poll(&pf, 1, 1000) != 1 || (pf.revents & POLLIN) == 0) {
        puts_raw("fdopsdemo: poll failed\n");
        return 1;
    }
    n = read(p[0], buf, sizeof(buf) - 1);
    buf[n] = 0;
    int status = 0;
    if (waitpid(pid, &status, 0) != pid || n != 7 || !streq(buf, "pipe-ok")) {
        puts_raw("fdopsdemo: pipe data mismatch\n");
        return 1;
    }
    close(p[0]);
    puts_raw("fdopsdemo: pipe/poll/fork OK\n");

    if (rename("/tmp/fdops/a", "/tmp/fdops/b") != 0) {
        puts_raw("fdopsdemo: rename failed\n");
        return 1;
    }
    fd = open("/tmp/fdops/b", O_RDONLY);
    n = read(fd, buf, 6);
    buf[n] = 0;
    close(fd);
    if (n != 6 || !streq(buf, "abcDEF")) {
        puts_raw("fdopsdemo: renamed file read failed\n");
        return 1;
    }
    if (unlink("/tmp/fdops/b") != 0 || rmdir("/tmp/fdops") != 0) {
        puts_raw("fdopsdemo: unlink/rmdir failed\n");
        return 1;
    }
    puts_raw("fdopsdemo: rename/unlink/mkdir/rmdir OK\n");
    return 0;
}
