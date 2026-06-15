/* stdlib.h — compat: rename newlib's nonstandard itoa/utoa so busybox's own
 * (different-signature) declarations don't conflict. */
#ifndef _SWIFTOS_COMPAT_STDLIB_H
#define _SWIFTOS_COMPAT_STDLIB_H
#define itoa __newlib_itoa
#define utoa __newlib_utoa
#include_next <stdlib.h>
#undef itoa
#undef utoa
#ifdef __cplusplus
extern "C" {
#endif
int clearenv(void);
int setenv(const char *, const char *, int);
int unsetenv(const char *);
void *memalign(size_t, size_t);
#ifdef __cplusplus
}
#endif
#endif
