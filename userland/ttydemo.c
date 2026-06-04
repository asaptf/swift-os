// ttydemo.c — M7 acceptance program: interactive tty + Ctrl-C.
//
// Reads one line from stdin (canonical mode, echoed by the tty line discipline),
// echoes it back, then spins in a "running command" loop. The kernel delivers
// SIGINT when Ctrl-C is typed, whose default action terminates this process.

#include "lib/syscall.h"

int puts_raw(const char *s);

int main(void) {
    char buf[64];

    puts_raw("M7 tty: type a line then Enter\n");
    long n = read(0, buf, sizeof(buf));

    puts_raw("you typed: ");
    if (n > 0) {
        write(1, buf, (size_t)n);
    }

    puts_raw("M7 tty: running; press Ctrl-C to interrupt\n");
    for (;;) {
        for (volatile unsigned long i = 0; i < 2000000UL; i += 1) {
            // Burn time so the loop is interruptible on a human/scripted scale.
        }
    }
    return 0;
}
