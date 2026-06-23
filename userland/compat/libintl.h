/* SPDX-License-Identifier: Apache-2.0 */
/* libintl.h — minimal GNU gettext surface for swift-os.
 *
 * newlib ships no libintl and swift-os has no message-catalog/locale machinery.
 * GLib (and other ports) hard-require the gettext API at build time, so we
 * provide passthrough no-ops: translation functions return the original msgid.
 * Implementations live in userland/compat/stubs.c (weak). */
#ifndef _SWIFTOS_LIBINTL_H
#define _SWIFTOS_LIBINTL_H

#ifdef __cplusplus
extern "C" {
#endif

char *gettext(const char *msgid);
char *dgettext(const char *domainname, const char *msgid);
char *dcgettext(const char *domainname, const char *msgid, int category);
char *ngettext(const char *msgid1, const char *msgid2, unsigned long int n);
char *dngettext(const char *domainname, const char *msgid1, const char *msgid2,
                unsigned long int n);
char *dcngettext(const char *domainname, const char *msgid1, const char *msgid2,
                 unsigned long int n, int category);
char *textdomain(const char *domainname);
char *bindtextdomain(const char *domainname, const char *dirname);
char *bind_textdomain_codeset(const char *domainname, const char *codeset);

#ifdef __cplusplus
}
#endif

#endif /* _SWIFTOS_LIBINTL_H */
