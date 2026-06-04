// securitydemo.c — adversarial syscall smoke tests.
//
// This deliberately sends invalid-but-non-faulting arguments across the EL0/EL1
// boundary. Faulting user pointers belong in a later copyin/copyout harness; the
// regular boot test must remain deterministic and keep QEMU alive.

#include "lib/syscall.h"
#include "lib/fs.h"

int puts_raw(const char *s);

static int failures = 0;

static void expect_eq(const char *name, long got, long want) {
    if (got == want) {
        return;
    }
    failures += 1;
    puts_raw("security FAIL: ");
    puts_raw(name);
    puts_raw("\n");
}

int main(void) {
    char buf[64];
    struct stat st;

    expect_eq("open NULL path", open((const char *)0, O_RDONLY), -22);
    expect_eq("open kernel path", open((const char *)0x40000000, O_RDONLY), -22);
    expect_eq("open unmapped path", open((const char *)0x88000000, O_RDONLY), -22);
    expect_eq("read bad fd", read(-1, buf, 1), -9);
    expect_eq("write bad fd", write(-1, buf, 1), -9);
    expect_eq("close bad fd", close(-1), -9);
    expect_eq("stat NULL path", stat((const char *)0, &st), -22);
    expect_eq("stat NULL buf", stat("/etc/motd", (struct stat *)0), -22);
    expect_eq("stat kernel buf", stat("/etc/motd", (struct stat *)0x40000000), -22);
    expect_eq("stat unmapped buf", stat("/etc/motd", (struct stat *)0x88000000), -22);
    expect_eq("fstat bad fd", fstat(-1, &st), -9);
    expect_eq("getcwd NULL buf", getcwd((char *)0, sizeof(buf)), -22);
    expect_eq("getcwd kernel buf", getcwd((char *)0x40000000, sizeof(buf)), -22);
    expect_eq("getcwd unmapped buf", getcwd((char *)0x88000000, sizeof(buf)), -22);
    expect_eq("getcwd tiny buf", getcwd(buf, 1), -28);
    expect_eq("chdir file", chdir("/etc/motd"), -20);
    expect_eq("waitpid no child", __syscall3(SYS_WAITPID, -1, (long)&st, 0), -10);
    expect_eq("tcgetattr NULL", __syscall3(SYS_TCGETATTR, 0, 0, 0), -22);
    expect_eq("tcsetattr NULL", __syscall3(SYS_TCSETATTR, 0, 0, 0), -22);

    int fd = open("/etc/motd", O_RDONLY);
    if (fd < 0) {
        failures += 1;
        puts_raw("security FAIL: open motd\n");
    } else {
        expect_eq("read NULL buf", read(fd, (void *)0, 1), -22);
        expect_eq("read kernel buf", read(fd, (void *)0x40000000, 1), -22);
        expect_eq("read unmapped buf", read(fd, (void *)0x88000000, 1), -22);
        expect_eq("negative lseek", lseek(fd, -1, 0), -22);
        close(fd);
    }

    expect_eq("write unmapped stdout", write(1, (const void *)0x88000000, 1), -22);
    expect_eq("write kernel stdout", write(1, (const void *)0x40000000, 1), -22);

    fd = open("/etc/motd", O_WRONLY);
    if (fd < 0) {
        failures += 1;
        puts_raw("security FAIL: open readonly for write\n");
    } else {
        expect_eq("write readonly file", write(fd, "x", 1), -30);
        close(fd);
    }

    fd = open("/", O_RDONLY);
    if (fd < 0) {
        failures += 1;
        puts_raw("security FAIL: open root dir\n");
    } else {
        expect_eq("read directory", read(fd, buf, sizeof(buf)), -21);
        expect_eq("getdents NULL buf", getdents(fd, (void *)0, 32), -22);
        expect_eq("getdents kernel buf", getdents(fd, (void *)0x40000000, 32), -22);
        expect_eq("getdents unmapped buf", getdents(fd, (void *)0x88000000, 32), -22);
        close(fd);
    }

    void *heap = sbrk(0);
    if ((long)heap < 0) {
        failures += 1;
        puts_raw("security FAIL: sbrk query\n");
    }
    expect_eq("sbrk below base", (long)sbrk(-1), -1);

    if (failures == 0) {
        puts_raw("securitydemo: syscall abuse checks OK\n");
    }
    return failures == 0 ? 0 : 1;
}
