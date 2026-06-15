// SPDX-License-Identifier: Apache-2.0
// sys/ioctl.h - add FIONBIO / TIOCGPTN for the libuv masquerade, atop compat's.
// SwiftOS does not implement these ioctls; libuv has fcntl-based fallbacks for
// nonblocking and reports errors for pty queries.
#ifndef _SWOS_NODE_COMPAT_SYS_IOCTL_H
#define _SWOS_NODE_COMPAT_SYS_IOCTL_H

#include_next <sys/ioctl.h>

#ifndef FIONBIO
#define FIONBIO 0x5421
#endif
#ifndef TIOCGPTN
#define TIOCGPTN 0x80045430
#endif

/* _IOC encoding macros (libuv's fs.c builds FS_IOC_* requests). Values only
 * need to compile; SwiftOS ioctl returns an error for these at runtime. */
#ifndef _IOC
#define _IOC(dir, type, nr, size) \
    (((dir) << 30) | ((type) << 8) | (nr) | ((size) << 16))
#define _IOC_NONE  0u
#define _IOC_WRITE 1u
#define _IOC_READ  2u
#define _IO(type, nr)         _IOC(_IOC_NONE, (type), (nr), 0)
#define _IOR(type, nr, t)     _IOC(_IOC_READ, (type), (nr), sizeof(t))
#define _IOW(type, nr, t)     _IOC(_IOC_WRITE, (type), (nr), sizeof(t))
#define _IOWR(type, nr, t)    _IOC(_IOC_READ | _IOC_WRITE, (type), (nr), sizeof(t))
#endif

#endif /* _SWOS_NODE_COMPAT_SYS_IOCTL_H */
