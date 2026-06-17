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
/* Pseudo-handles for dlsym; static-only OS resolves nothing through them. */
#define RTLD_DEFAULT ((void *)0)
#define RTLD_NEXT    ((void *)-1l)

#ifdef __cplusplus
extern "C" {
#endif
void *dlopen(const char *filename, int flags);
void *dlsym(void *handle, const char *symbol);
int   dlclose(void *handle);
char *dlerror(void);

/* dladdr: bundled OpenSSL's dso_dlfcn.c references it. No dynamic symbols on a
 * static-only OS, so the companion returns 0 (failure) and callers degrade. */
typedef struct {
    const char *dli_fname;
    void       *dli_fbase;
    const char *dli_sname;
    void       *dli_saddr;
} Dl_info;
int dladdr(const void *addr, Dl_info *info);
#ifdef __cplusplus
}
#endif

#endif /* _SWOS_NODE_COMPAT_DLFCN_H */
