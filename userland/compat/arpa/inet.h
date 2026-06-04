#ifndef _SWIFTOS_ARPA_INET_H
#define _SWIFTOS_ARPA_INET_H
#include <netinet/in.h>
in_addr_t inet_addr(const char *cp);
int inet_aton(const char *cp, struct in_addr *inp);
char *inet_ntoa(struct in_addr in);
int inet_pton(int af, const char *src, void *dst);
const char *inet_ntop(int af, const void *src, char *dst, socklen_t size);
#endif
