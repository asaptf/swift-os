#ifndef _SWIFTOS_MNTENT_H
#define _SWIFTOS_MNTENT_H
#include <stdio.h>
/* swift-os has no /etc/mtab; gnulib mountlist (GLib/MC) needs these names to
 * compile its one-argument-getmntent path. The stubs report an empty list. */
#define MOUNTED "/etc/mtab"
#define MNTTYPE_IGNORE "ignore"
#define MNTTYPE_NFS    "nfs"
#define MNTTYPE_SWAP   "swap"
#define MNTOPT_RO      "ro"
#define MNTOPT_RW      "rw"
struct mntent { char *mnt_fsname, *mnt_dir, *mnt_type, *mnt_opts; int mnt_freq, mnt_passno; };
FILE *setmntent(const char *file, const char *mode);
struct mntent *getmntent(FILE *fp);
int addmntent(FILE *fp, const struct mntent *mnt);
int endmntent(FILE *fp);
char *hasmntopt(const struct mntent *mnt, const char *opt);
#endif
