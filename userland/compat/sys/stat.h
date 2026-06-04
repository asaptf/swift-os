/* sys/stat.h — compat: add lstat/mknod that newlib lacks. */
#ifndef _SWIFTOS_COMPAT_SYS_STAT_H
#define _SWIFTOS_COMPAT_SYS_STAT_H
#include_next <sys/stat.h>
int lstat(const char *path, struct stat *buf);
int mknod(const char *path, mode_t mode, dev_t dev);
#endif
