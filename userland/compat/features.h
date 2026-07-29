/* SPDX-License-Identifier: Apache-2.0
 *
 * features.h — glibc-style feature-test surface for freestanding newlib.
 *
 * newlib's <sys/features.h> defines _POSIX_VERSION only for RTEMS/Cygwin/XMK,
 * not bare aarch64-elf. Ports that key off _POSIX_VERSION (bash posixwait.h
 * WAIT typedef, etc.) otherwise take the non-POSIX union-wait path and fail
 * with "field 'status' has incomplete type". Advertise a POSIX.1-2008
 * baseline consistent with our POSIX-like syscall surface.
 *
 * Visibility macros (__POSIX_VISIBLE etc.) still come from newlib
 * <sys/cdefs.h>; this only sets the public _POSIX_VERSION advertisement.
 */
#ifndef _SWIFTOS_FEATURES_H
#define _SWIFTOS_FEATURES_H

#ifndef _POSIX_VERSION
#define _POSIX_VERSION 200809L
#endif

#ifndef _POSIX2_VERSION
#define _POSIX2_VERSION 200809L
#endif

#endif /* _SWIFTOS_FEATURES_H */
