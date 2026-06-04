/* dirent.h — minimal POSIX directory API shim for busybox/newlib. */
#ifndef _SWIFTOS_DIRENT_H
#define _SWIFTOS_DIRENT_H

#include <sys/types.h>

#define DT_UNKNOWN 0
#define DT_DIR     4
#define DT_REG     8

struct dirent {
    unsigned long d_ino;
    unsigned long d_off;
    unsigned short d_reclen;
    unsigned char d_type;
    char d_name[256];
};

typedef struct DIR DIR;

DIR *opendir(const char *path);
DIR *fdopendir(int fd);
struct dirent *readdir(DIR *dir);
int closedir(DIR *dir);
void rewinddir(DIR *dir);
int dirfd(DIR *dir);

#endif
