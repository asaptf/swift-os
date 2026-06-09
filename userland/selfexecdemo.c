// SPDX-License-Identifier: Apache-2.0
// selfexecdemo.c - regression for user pointers that must not panic EL1.

#include "lib/syscall.h"

int puts_raw(const char *s);

#define PAGE 4096

int main(void) {
    int fd = open("/bin/argvdemo", 0);
    if (fd < 0) {
        puts_raw("selfexec FAIL: open /bin/argvdemo\n");
        return 1;
    }

    char *const argv[] = { "argvdemo", 0 };
    long s1 = spawn("/bin/argvdemo", argv);
    close(fd);
    if (s1 != 1) {
        puts_raw("selfexec FAIL: open+exec same file\n");
        return 1;
    }
    puts_raw("selfexec: open+exec same file OK\n");

    char *const bad_ptr_argv[] = { "argvdemo", (char *)-1L, 0 };
    (void)spawn("/bin/argvdemo", bad_ptr_argv);
    puts_raw("selfexec: garbage-argv-pointer survived\n");

    long old = (long)sbrk(2 * PAGE);
    if (old >= 0) {
        unsigned long top = ((unsigned long)old + 2 * PAGE + (PAGE - 1)) & ~(unsigned long)(PAGE - 1);
        char **unterminated = (char **)(top - sizeof(char *));
        unterminated[0] = "argvdemo";
        (void)spawn("/bin/argvdemo", unterminated);
        puts_raw("selfexec: unterminated-argv survived\n");
    }

    puts_raw("selfexec OK: open+exec same file and malformed argv handled\n");
    return 0;
}
