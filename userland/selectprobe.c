// selectprobe.c - C/newlib select/pselect compatibility proof over poll.

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/select.h>
#include <time.h>
#include <unistd.h>

int main(void) {
    int fds[2];
    if (pipe(fds) != 0) {
        printf("selectprobe: pipe failed errno=%d\n", errno);
        return 1;
    }

    fd_set rfds;
    FD_ZERO(&rfds);
    FD_SET(fds[0], &rfds);
    struct timeval tv = { 0, 0 };
    int r = select(fds[0] + 1, &rfds, 0, 0, &tv);
    if (r != 0 || FD_ISSET(fds[0], &rfds)) {
        printf("selectprobe: empty read select r=%d isset=%d errno=%d\n",
               r, FD_ISSET(fds[0], &rfds), errno);
        return 1;
    }
    printf("selectprobe: empty read timeout OK\n");

    char byte = 'x';
    if (write(fds[1], &byte, 1) != 1) {
        printf("selectprobe: write failed errno=%d\n", errno);
        return 1;
    }

    FD_ZERO(&rfds);
    FD_SET(fds[0], &rfds);
    tv.tv_sec = 1;
    tv.tv_usec = 0;
    r = select(fds[0] + 1, &rfds, 0, 0, &tv);
    if (r != 1 || !FD_ISSET(fds[0], &rfds)) {
        printf("selectprobe: read readiness r=%d isset=%d errno=%d\n",
               r, FD_ISSET(fds[0], &rfds), errno);
        return 1;
    }
    if (read(fds[0], &byte, 1) != 1 || byte != 'x') {
        printf("selectprobe: readback failed byte=%c errno=%d\n", byte, errno);
        return 1;
    }
    printf("selectprobe: pipe read readiness OK\n");

    fd_set wfds;
    FD_ZERO(&wfds);
    FD_SET(fds[1], &wfds);
    struct timespec ts = { 0, 0 };
    r = pselect(fds[1] + 1, 0, &wfds, 0, &ts, 0);
    if (r != 1 || !FD_ISSET(fds[1], &wfds)) {
        printf("selectprobe: pselect write readiness r=%d isset=%d errno=%d\n",
               r, FD_ISSET(fds[1], &wfds), errno);
        return 1;
    }
    printf("selectprobe: pselect write readiness OK\n");

    tv.tv_sec = 0;
    tv.tv_usec = 1000;
    r = select(0, 0, 0, 0, &tv);
    if (r != 0) {
        printf("selectprobe: zero-fd timeout r=%d errno=%d\n", r, errno);
        return 1;
    }
    printf("selectprobe: zero-fd timeout OK\n");

    close(fds[0]);
    close(fds[1]);
    printf("SELECTPROBE-OK\n");
    return 0;
}
