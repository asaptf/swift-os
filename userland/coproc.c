// coproc.c — M8d concurrency demo: a CPU-bound EL0 process.
//
// Prints its tag (argv[1]) a few times with a busy delay between iterations, so
// the timer preempts it. Run two of these and their output interleaves —
// demonstrating real preemptive EL0 multitasking.

#include "lib/syscall.h"

int puts_raw(const char *s);

int main(int argc, char **argv) {
    const char *tag = argc > 1 ? argv[1] : "?";
    for (int i = 0; i < 3; i += 1) {
        puts_raw("coproc ");
        puts_raw(tag);
        char c = (char)('0' + i);
        write(1, " iter ", 6);
        write(1, &c, 1);
        write(1, "\n", 1);
        for (volatile long j = 0; j < 3000000; j += 1) {
            // Burn time so the 100 Hz timer preempts us mid-loop.
        }
    }
    puts_raw("coproc ");
    puts_raw(tag);
    puts_raw(" done\n");
    return 0;
}
