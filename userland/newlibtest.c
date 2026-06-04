// newlibtest.c — M8c(2) acceptance: a real C program against newlib's libc.
//
// Exercises printf (varargs/stdio), malloc/free (heap via _sbrk), and
// fopen/fgets (file I/O via _open/_read/_fstat) on top of our syscall port.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    printf("newlib: hello, argc=%d argv0=%s\n", argc, argv[0]);

    char *p = malloc(128);
    strcpy(p, "malloc works");
    printf("newlib: %s\n", p);
    free(p);

    FILE *f = fopen("/etc/motd", "r");
    if (f != NULL) {
        char buf[64];
        if (fgets(buf, sizeof(buf), f) != NULL) {
            printf("newlib motd: %s", buf);
        }
        fclose(f);
    } else {
        printf("newlib: fopen failed\n");
    }

    printf("newlib: done\n");
    return 0;
}
