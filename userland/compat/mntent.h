#ifndef _SWIFTOS_MNTENT_H
#define _SWIFTOS_MNTENT_H
#include <stdio.h>
struct mntent { char *mnt_fsname, *mnt_dir, *mnt_type, *mnt_opts; int mnt_freq, mnt_passno; };
FILE *setmntent(const char *file, const char *mode);
struct mntent *getmntent(FILE *fp);
int addmntent(FILE *fp, const struct mntent *mnt);
int endmntent(FILE *fp);
char *hasmntopt(const struct mntent *mnt, const char *opt);
#endif
