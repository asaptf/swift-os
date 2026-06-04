// execdemo.c — M8d process demo: replace current image with execve().

#include "lib/syscall.h"

int puts_raw(const char *s);

int main(void) {
    puts_raw("execdemo: before execve\n");
    char *argv[] = { "argvdemo", "exec-alpha", "exec-beta", 0 };
    execve("/bin/argvdemo", argv, 0);
    puts_raw("execdemo: execve returned unexpectedly\n");
    return 1;
}
