/* SPDX-License-Identifier: Apache-2.0 */
/* resolv.h — minimal BIND resolver surface for swift-os.
 *
 * newlib ships no resolver. swift-os has no in-process DNS resolver, but GLib's
 * gio (and other ports) probe for res_query() at configure time. We declare the
 * classic resolver entry points here; the implementations in
 * userland/compat/stubs.c fail with ENOSYS (gio name resolution is unused). */
#ifndef _SWIFTOS_RESOLV_H
#define _SWIFTOS_RESOLV_H

#include <sys/types.h>
#include <arpa/nameser.h>

#ifdef __cplusplus
extern "C" {
#endif

int res_init(void);
int res_query(const char *dname, int klass, int type,
              unsigned char *answer, int anslen);
int res_search(const char *dname, int klass, int type,
               unsigned char *answer, int anslen);
int dn_expand(const unsigned char *msg, const unsigned char *eom,
              const unsigned char *comp_dn, char *exp_dn, int length);

#ifdef __cplusplus
}
#endif

#endif /* _SWIFTOS_RESOLV_H */
