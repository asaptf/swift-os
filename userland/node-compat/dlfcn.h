// SPDX-License-Identifier: Apache-2.0
// dlfcn.h - dynamic-loader surface for the libuv linux masquerade.
//
// SwiftOS is static-linking only (no dynamic loader), so the companion
// implementation makes dlopen() fail with a clear error and dlsym() return
// NULL. libuv's uv_dlopen reports the failure to its caller; Node native
// addons are deferred until a dynamic-loading policy exists.
#ifndef _SWOS_NODE_COMPAT_DLFCN_H
#define _SWOS_NODE_COMPAT_DLFCN_H

#define RTLD_LAZY   0x0001
#define RTLD_NOW    0x0002
#define RTLD_GLOBAL 0x0100
#define RTLD_LOCAL  0x0000

void *dlopen(const char *filename, int flags);
void *dlsym(void *handle, const char *symbol);
int   dlclose(void *handle);
char *dlerror(void);

#endif /* _SWOS_NODE_COMPAT_DLFCN_H */
