#ifndef _SWIFTOS_STATFS_H
#define _SWIFTOS_STATFS_H
#include <sys/types.h>
struct statfs {
    long f_type, f_bsize, f_blocks, f_bfree, f_bavail;
    long f_files, f_ffree, f_namelen, f_frsize, f_flags;
    long f_spare[4];
};
int statfs(const char *path, struct statfs *buf);
int fstatfs(int fd, struct statfs *buf);
#endif
