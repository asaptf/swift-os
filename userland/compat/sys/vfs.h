/* SPDX-License-Identifier: Apache-2.0 */
/* sys/vfs.h — Linux-style alias for <sys/statfs.h> on swift-os.
 *
 * newlib has neither. GLib/Midnight Commander's filesystem-usage code includes
 * <sys/vfs.h> for `struct statfs` + statfs(); we forward to the compat
 * <sys/statfs.h> (statfs itself is an ENOSYS stub in stubs.c, so free-space
 * display is simply empty). */
#ifndef _SWIFTOS_SYS_VFS_H
#define _SWIFTOS_SYS_VFS_H
#include <sys/statfs.h>
#endif /* _SWIFTOS_SYS_VFS_H */
