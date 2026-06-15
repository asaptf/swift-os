// SPDX-License-Identifier: Apache-2.0
// sys/sendfile.h - sendfile surface for the libuv linux masquerade.
// The companion implementation returns -1/ENOSYS so libuv falls back to its
// portable read()/write() copy loop.
#ifndef _SWOS_NODE_COMPAT_SYS_SENDFILE_H
#define _SWOS_NODE_COMPAT_SYS_SENDFILE_H

#include <sys/types.h>

ssize_t sendfile(int out_fd, int in_fd, off_t *offset, size_t count);

#endif /* _SWOS_NODE_COMPAT_SYS_SENDFILE_H */
