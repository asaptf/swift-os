// mprotectprobe.c - C/newlib compat proof for mmap/mprotect W^X behavior.

#include <errno.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

typedef int (*jit_fn_t)(void);

int main(void) {
    const size_t page = 4096;
    const unsigned char code[] = {
        0x40, 0x05, 0x80, 0x52,  /* mov w0, #42 */
        0xc0, 0x03, 0x5f, 0xd6   /* ret */
    };

    void *rw = mmap(0, page, PROT_READ | PROT_WRITE,
                    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (rw == MAP_FAILED) {
        printf("mprotectprobe: mmap RW failed errno=%d\n", errno);
        return 1;
    }

    unsigned char *bytes = (unsigned char *)rw;
    for (size_t i = 0; i < page; i++) {
        if (bytes[i] != 0) {
            printf("mprotectprobe: fresh mmap not zero-filled at %lu\n", (unsigned long)i);
            munmap(rw, page);
            return 2;
        }
    }
    memcpy(rw, code, sizeof(code));

    if (mprotect(rw, page, PROT_READ | PROT_EXEC) != 0) {
        printf("mprotectprobe: mprotect RW->RX failed errno=%d\n", errno);
        munmap(rw, page);
        return 3;
    }

    int result = ((jit_fn_t)(uintptr_t)rw)();
    if (result != 42) {
        printf("mprotectprobe: RX call returned %d\n", result);
        munmap(rw, page);
        return 4;
    }
    printf("mprotectprobe: RW-RX-CALL-OK result=%d\n", result);

    if (mprotect(rw, page, PROT_READ | PROT_WRITE | PROT_EXEC) == 0) {
        printf("mprotectprobe: W^X breach: mprotect RWX allowed\n");
        munmap(rw, page);
        return 5;
    }
    printf("mprotectprobe: WX-OK mprotect RWX rejected errno=%d\n", errno);

    if (munmap(rw, page) != 0) {
        printf("mprotectprobe: munmap RX failed errno=%d\n", errno);
        return 6;
    }

    void *rwx = mmap(0, page, PROT_READ | PROT_WRITE | PROT_EXEC,
                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (rwx != MAP_FAILED) {
        printf("mprotectprobe: W^X breach: mmap RWX allowed\n");
        munmap(rwx, page);
        return 7;
    }
    printf("mprotectprobe: WX-OK mmap RWX rejected errno=%d\n", errno);
    printf("MPROTECTPROBE-OK\n");
    return 0;
}
