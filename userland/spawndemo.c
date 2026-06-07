// spawndemo.c — M8a(2) spawn demo: an EL0 process launches another.
//
// Demonstrates the core shell capability: spawn a child program with arguments
// and receive its exit status. Here we run argvdemo, which prints its argv and
// exits with argc; we print the status we got back.

#include "lib/syscall.h"

int puts_raw(const char *s);

int main(void) {
    puts_raw("spawndemo: spawning /bin/argvdemo\n");

    char *const argv[] = { "argvdemo", "isocheck", 0 };
    // C2: hold a non-stdio fd open (fd 3) before spawning, to prove the child
    // does NOT inherit it. Open a DIFFERENT file than the one being spawned.
    (void)open("/etc/motd", 0); // O_RDONLY
    long status = spawn("/bin/argvdemo", argv);

    puts_raw("spawndemo: child exit status ");
    char c = (char)('0' + (status >= 0 && status < 10 ? status : 9));
    write(1, &c, 1);
    puts_raw("\n");
    return 0;
}
