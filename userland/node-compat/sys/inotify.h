// SPDX-License-Identifier: Apache-2.0
// sys/inotify.h - inotify surface for the Node.js/libuv linux masquerade.
//
// SwiftOS has no inotify; these declarations let libuv's fs-event path compile.
// The companion implementation returns ENOSYS so libuv degrades to no
// filesystem watching (an accepted first-pass limitation).
#ifndef _SWOS_NODE_COMPAT_SYS_INOTIFY_H
#define _SWOS_NODE_COMPAT_SYS_INOTIFY_H

#include <stdint.h>

struct inotify_event {
    int      wd;
    uint32_t mask;
    uint32_t cookie;
    uint32_t len;
    char     name[];
};

/* Watch / event mask bits used by libuv. */
#define IN_ATTRIB      0x00000004
#define IN_MODIFY      0x00000002
#define IN_CREATE      0x00000100
#define IN_DELETE      0x00000200
#define IN_DELETE_SELF 0x00000400
#define IN_MOVE_SELF   0x00000800
#define IN_MOVED_FROM  0x00000040
#define IN_MOVED_TO    0x00000080

/* inotify_init1 flags. */
#define IN_CLOEXEC  02000000
#define IN_NONBLOCK 00004000

int inotify_init1(int flags);
int inotify_add_watch(int fd, const char *pathname, uint32_t mask);
int inotify_rm_watch(int fd, int wd);

#endif /* _SWOS_NODE_COMPAT_SYS_INOTIFY_H */
