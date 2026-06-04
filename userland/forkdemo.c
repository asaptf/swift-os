// forkdemo.c — M8d process demo: eager-copy fork + waitpid.

#include "lib/syscall.h"

int puts_raw(const char *s);

static volatile int marker = 7;

int main(void) {
    puts_raw("forkdemo: before fork\n");

    int status = 0;
    int pid = fork();
    if (pid < 0) {
        puts_raw("forkdemo: fork failed\n");
        return 1;
    }

    if (pid == 0) {
        marker = 42;
        puts_raw("forkdemo: child sees private marker\n");
        return 42;
    }

    int waited = waitpid(pid, &status, 0);
    if (waited != pid || ((status >> 8) & 0xff) != 42) {
        puts_raw("forkdemo: waitpid failed\n");
        return 1;
    }
    if (marker != 7) {
        puts_raw("forkdemo: parent marker corrupted\n");
        return 1;
    }

    puts_raw("forkdemo: parent waited child\n");
    return 0;
}
