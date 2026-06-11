// eventfdprobe.c - C/newlib eventfd compatibility proof.

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/eventfd.h>
#include <sys/select.h>
#include <unistd.h>

#ifndef O_CLOEXEC
#define O_CLOEXEC 0x40000
#endif

static int check_status_flag(int fd, int mask, const char *label) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || (flags & mask) != mask) {
        printf("eventfdprobe: %s status flags=0x%x errno=%d\n", label, flags, errno);
        return 0;
    }
    return 1;
}

static int check_fd_flag(int fd, int mask, const char *label) {
    int flags = fcntl(fd, F_GETFD, 0);
    if (flags < 0 || (flags & mask) != mask) {
        printf("eventfdprobe: %s fd flags=0x%x errno=%d\n", label, flags, errno);
        return 0;
    }
    return 1;
}

static int poll_readable(int fd, int expect, const char *label) {
    struct pollfd p;
    p.fd = fd;
    p.events = POLLIN;
    p.revents = 0;
    int r = poll(&p, 1, 0);
    int readable = r == 1 && (p.revents & POLLIN) != 0;
    if (readable != expect) {
        printf("eventfdprobe: %s poll r=%d revents=0x%x errno=%d\n",
               label, r, p.revents, errno);
        return 0;
    }
    return 1;
}

int main(void) {
    int fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    if (fd < 0) {
        printf("eventfdprobe: eventfd failed errno=%d\n", errno);
        return 1;
    }
    if (!check_status_flag(fd, O_NONBLOCK, "eventfd") ||
        !check_fd_flag(fd, FD_CLOEXEC, "eventfd")) {
        return 1;
    }
    printf("eventfdprobe: flags OK\n");

    if (!poll_readable(fd, 0, "empty")) { return 1; }
    eventfd_t value = 0;
    errno = 0;
    if (eventfd_read(fd, &value) != -1 || errno != EAGAIN) {
        printf("eventfdprobe: empty read value=%llu errno=%d\n",
               (unsigned long long)value, errno);
        return 1;
    }
    printf("eventfdprobe: empty EAGAIN OK\n");

    if (eventfd_write(fd, 5) != 0 || !poll_readable(fd, 1, "counter")) {
        printf("eventfdprobe: counter write/readiness failed errno=%d\n", errno);
        return 1;
    }
    value = 0;
    if (eventfd_read(fd, &value) != 0 || value != 5) {
        printf("eventfdprobe: counter read value=%llu errno=%d\n",
               (unsigned long long)value, errno);
        return 1;
    }
    if (!poll_readable(fd, 0, "drained")) { return 1; }
    printf("eventfdprobe: counter poll/read OK\n");

    int sem = eventfd(2, EFD_SEMAPHORE | EFD_NONBLOCK);
    if (sem < 0) {
        printf("eventfdprobe: semaphore eventfd failed errno=%d\n", errno);
        return 1;
    }
    value = 0;
    if (eventfd_read(sem, &value) != 0 || value != 1 ||
        eventfd_read(sem, &value) != 0 || value != 1) {
        printf("eventfdprobe: semaphore reads value=%llu errno=%d\n",
               (unsigned long long)value, errno);
        return 1;
    }
    errno = 0;
    if (eventfd_read(sem, &value) != -1 || errno != EAGAIN) {
        printf("eventfdprobe: semaphore empty errno=%d\n", errno);
        return 1;
    }
    printf("eventfdprobe: semaphore reads OK\n");

    if (eventfd_write(fd, 7) != 0) {
        printf("eventfdprobe: select write failed errno=%d\n", errno);
        return 1;
    }
    fd_set rfds;
    FD_ZERO(&rfds);
    FD_SET(fd, &rfds);
    struct timeval tv = { 0, 0 };
    int r = select(fd + 1, &rfds, 0, 0, &tv);
    if (r != 1 || !FD_ISSET(fd, &rfds)) {
        printf("eventfdprobe: select r=%d isset=%d errno=%d\n",
               r, FD_ISSET(fd, &rfds), errno);
        return 1;
    }
    value = 0;
    if (eventfd_read(fd, &value) != 0 || value != 7) {
        printf("eventfdprobe: select read value=%llu errno=%d\n",
               (unsigned long long)value, errno);
        return 1;
    }
    printf("eventfdprobe: select readiness OK\n");

    close(sem);
    close(fd);
    printf("EVENTFDPROBE-OK\n");
    return 0;
}
