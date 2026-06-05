// fs.h — swift-os userland filesystem ABI (our own, not Linux).
//
// Struct layouts must match kernel/vfs/vfs.swift.

#ifndef SWIFTOS_FS_H
#define SWIFTOS_FS_H

#include "syscall.h"

#define O_RDONLY 0
#define O_WRONLY 1
#define O_RDWR   2
#define O_CREAT  0x40

#define S_IFMT  0xF000
#define S_IFREG 0x8000
#define S_IFDIR 0x4000
#define S_ISDIR(m) (((m) & S_IFMT) == S_IFDIR)
#define S_ISREG(m) (((m) & S_IFMT) == S_IFREG)

// Mirrors the kernel kstat record (kernel/vfs/vfs.swift writeStatMode), 24 bytes.
struct stat {
    unsigned int st_mode;
    unsigned int st_uid;
    unsigned long st_size;
    unsigned int st_gid;
    unsigned int st_nlink;
};

struct dirent {
    unsigned long d_ino;
    unsigned long d_off;
    unsigned short d_reclen;
    unsigned char d_type;
    char d_name[]; // NUL-terminated
};

static inline int stat(const char *path, struct stat *st) {
    return (int)__syscall3(SYS_STAT, (long)path, (long)st, 0);
}

static inline int fstat(int fd, struct stat *st) {
    return (int)__syscall3(SYS_FSTAT, fd, (long)st, 0);
}

static inline long getdents(int fd, void *buf, unsigned long count) {
    return __syscall3(SYS_GETDENTS, fd, (long)buf, (long)count);
}

static inline int chdir(const char *path) {
    return (int)__syscall3(SYS_CHDIR, (long)path, 0, 0);
}

static inline long getcwd(char *buf, unsigned long size) {
    return __syscall3(SYS_GETCWD, (long)buf, (long)size, 0);
}

#endif // SWIFTOS_FS_H
