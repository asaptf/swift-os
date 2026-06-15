// SPDX-License-Identifier: Apache-2.0
// dirent.h - add scandir()/alphasort() for the libuv masquerade, atop compat's.
#ifndef _SWOS_NODE_COMPAT_DIRENT_H
#define _SWOS_NODE_COMPAT_DIRENT_H

#include_next <dirent.h>

int scandir(const char *dirp, struct dirent ***namelist,
            int (*filter)(const struct dirent *),
            int (*compar)(const struct dirent **, const struct dirent **));
int alphasort(const struct dirent **a, const struct dirent **b);

#endif /* _SWOS_NODE_COMPAT_DIRENT_H */
