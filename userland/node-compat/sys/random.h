// SPDX-License-Identifier: Apache-2.0
// sys/random.h - getrandom() for the masquerade. c-ares (and others) use it for
// seed entropy. Backed by SwiftOS virtio-rng via the companion implementation.
#ifndef _SWOS_NODE_COMPAT_SYS_RANDOM_H
#define _SWOS_NODE_COMPAT_SYS_RANDOM_H

#include <stddef.h>
#include <sys/types.h>

#ifndef GRND_NONBLOCK
#define GRND_NONBLOCK 0x0001
#define GRND_RANDOM   0x0002
#define GRND_INSECURE 0x0004
#endif

ssize_t getrandom(void *buf, size_t buflen, unsigned int flags);

#endif /* _SWOS_NODE_COMPAT_SYS_RANDOM_H */
