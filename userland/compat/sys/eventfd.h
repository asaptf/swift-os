// eventfd.h - small newlib compatibility facade for swift-os event counters.

#ifndef SWIFTOS_COMPAT_SYS_EVENTFD_H
#define SWIFTOS_COMPAT_SYS_EVENTFD_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint64_t eventfd_t;

#ifndef EFD_SEMAPHORE
#define EFD_SEMAPHORE 1
#endif
#ifndef EFD_NONBLOCK
#define EFD_NONBLOCK 0x4000
#endif
#ifndef EFD_CLOEXEC
#define EFD_CLOEXEC 0x40000
#endif

int eventfd(unsigned int initval, int flags);
int eventfd_read(int fd, eventfd_t *value);
int eventfd_write(int fd, eventfd_t value);

#ifdef __cplusplus
}
#endif

#endif
