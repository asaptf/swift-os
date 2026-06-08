// spawndemo.c — M8a(2) spawn demo: an EL0 process launches another.
//
// Demonstrates the core shell capability: spawn a child program with arguments
// and receive its exit status. Here we run argvdemo, which prints its argv and
// exits with argc; we print the status we got back.

#include "lib/syscall.h"
#include "lib/fs.h"

int puts_raw(const char *s);

static void print_status(const char *prefix, long status) {
    puts_raw(prefix);
    char c = (char)('0' + (status >= 0 && status < 10 ? status : 9));
    write(1, &c, 1);
    puts_raw("\n");
}

int main(void) {
    puts_raw("spawndemo: spawning /bin/argvdemo\n");

    char *const argv[] = { "argvdemo", "isocheck", 0 };
    // C2: hold a non-stdio fd open (fd 3) before spawning, to prove the child
    // does NOT inherit it. Open a DIFFERENT file than the one being spawned.
    int motd = open("/etc/motd", 0); // O_RDONLY
    if (motd != 3) {
        puts_raw("SPAWN-ISO-SETUP-FAIL\n");
        return 1;
    }
    puts_raw("SPAWN-ISO-PARENT-FD3\n");

    long status = spawn("/bin/argvdemo", argv);
    print_status("spawndemo: child exit status ", status);
    if (status != 2) { return 1; }

    int root = open("/", O_RDONLY);
    if (root < 0) {
        puts_raw("SPAWN-EXPLICIT-FAIL\n");
        return 1;
    }

    struct swiftos_spawn_handle handles[] = {
        { 0, 0, SWIFTOS_RIGHT_ALL, 0 },
        { 1, 1, SWIFTOS_RIGHT_ALL, 0 },
        { 2, 2, SWIFTOS_RIGHT_ALL, 0 },
        { motd, 3, SWIFTOS_RIGHT_READ | SWIFTOS_RIGHT_GETATTR, 0 },
        { root, 4, SWIFTOS_RIGHT_GETATTR, 0 },
        { motd, 5, SWIFTOS_RIGHT_READ, 0 },
    };
    char *const inherit_argv[] = { "argvdemo", "inheritcheck", 0 };
    long inherit_status = spawn_handles("/bin/argvdemo", inherit_argv,
                                        handles, sizeof(handles) / sizeof(handles[0]));
    print_status("spawndemo: explicit child exit status ", inherit_status);
    if (inherit_status != 2) { return 1; }
    return 0;
}
