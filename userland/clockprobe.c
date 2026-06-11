// clockprobe.c - C/newlib compat proof for POSIX realtime and monotonic clocks.

#include <errno.h>
#include <stdio.h>
#include <time.h>

static long diff_ns(const struct timespec *a, const struct timespec *b) {
    return (long)((b->tv_sec - a->tv_sec) * 1000000000L) +
           (long)(b->tv_nsec - a->tv_nsec);
}

int main(void) {
    struct timespec realtime;
    struct timespec mono0;
    struct timespec mono1;
    struct timespec res;
    struct timespec wait = { 0, 120000000L };

    if (clock_gettime(CLOCK_REALTIME, &realtime) != 0) {
        printf("clockprobe: CLOCK_REALTIME failed errno=%d\n", errno);
        return 1;
    }
    if (realtime.tv_sec <= 0) {
        printf("clockprobe: CLOCK_REALTIME invalid sec=%ld\n", (long)realtime.tv_sec);
        return 2;
    }
    printf("clockprobe: realtime sec=%ld nsec=%ld\n",
           (long)realtime.tv_sec, realtime.tv_nsec);

    if (clock_getres(CLOCK_MONOTONIC, &res) != 0) {
        printf("clockprobe: CLOCK_MONOTONIC res failed errno=%d\n", errno);
        return 3;
    }
    if (res.tv_sec < 0 || res.tv_nsec < 0 || res.tv_nsec >= 1000000000L) {
        printf("clockprobe: CLOCK_MONOTONIC invalid res=%ld.%09ld\n",
               (long)res.tv_sec, res.tv_nsec);
        return 4;
    }
    printf("clockprobe: monotonic res=%ld.%09ld\n", (long)res.tv_sec, res.tv_nsec);

    if (clock_gettime(CLOCK_MONOTONIC, &mono0) != 0) {
        printf("clockprobe: CLOCK_MONOTONIC start failed errno=%d\n", errno);
        return 5;
    }
    if (nanosleep(&wait, 0) != 0) {
        printf("clockprobe: nanosleep failed errno=%d\n", errno);
        return 6;
    }
    if (clock_gettime(CLOCK_MONOTONIC, &mono1) != 0) {
        printf("clockprobe: CLOCK_MONOTONIC end failed errno=%d\n", errno);
        return 7;
    }

    long elapsed = diff_ns(&mono0, &mono1);
    if (elapsed <= 0) {
        printf("clockprobe: monotonic did not advance elapsed_ns=%ld\n", elapsed);
        return 8;
    }
    printf("clockprobe: monotonic elapsed_ns=%ld\n", elapsed);
    printf("CLOCKPROBE-OK\n");
    return 0;
}
