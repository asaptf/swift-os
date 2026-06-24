/* SPDX-License-Identifier: Apache-2.0 */
/* utime.h — utime() prototype for swift-os.
 *
 * newlib's <utime.h> pulls in <sys/utime.h> for `struct utimbuf` but provides
 * no utime() prototype or symbol (it expects a per-arch implementation that our
 * port does not build). We reuse newlib's struct and declare utime(); the weak
 * implementation in userland/compat/stubs.c is a no-op (swift-os has no
 * file-time metadata to set yet). */
#ifndef _SWIFTOS_UTIME_H
#define _SWIFTOS_UTIME_H

#include <sys/types.h>
#include <sys/utime.h>

#ifdef __cplusplus
extern "C" {
#endif

int utime(const char *filename, const struct utimbuf *times);

#ifdef __cplusplus
}
#endif

#endif /* _SWIFTOS_UTIME_H */
