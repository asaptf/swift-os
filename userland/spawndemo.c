// spawndemo.c — M8a(2) spawn demo: an EL0 process launches another.
//
// Demonstrates the core shell capability: spawn a child program with arguments
// and receive its exit status. Here we run argvdemo, which prints its argv and
// exits with argc; we print the status we got back.

#include "lib/syscall.h"

int puts_raw(const char *s);

int main(void) {
    puts_raw("spawndemo: spawning /bin/argvdemo\n");

    char *const argv[] = { "argvdemo", "child-arg", 0 };
    long status = spawn("/bin/argvdemo", argv);

    puts_raw("spawndemo: child exit status ");
    char c = (char)('0' + (status >= 0 && status < 10 ? status : 9));
    write(1, &c, 1);
    puts_raw("\n");
    return 0;
}
