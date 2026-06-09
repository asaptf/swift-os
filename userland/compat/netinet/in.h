#ifndef _SWIFTOS_NETINET_IN_H
#define _SWIFTOS_NETINET_IN_H
#include <sys/socket.h>
typedef unsigned short in_port_t;
typedef unsigned int in_addr_t;
struct in_addr { in_addr_t s_addr; };
struct sockaddr_in { sa_family_t sin_family; in_port_t sin_port; struct in_addr sin_addr; char sin_zero[8]; };
struct in6_addr { unsigned char s6_addr[16]; };
struct sockaddr_in6 { sa_family_t sin6_family; in_port_t sin6_port; unsigned int sin6_flowinfo;
                      struct in6_addr sin6_addr; unsigned int sin6_scope_id; };
static inline int IN6_IS_ADDR_UNSPECIFIED(const struct in6_addr *addr) {
    for (int i = 0; i < 16; i++) {
        if (addr->s6_addr[i] != 0) { return 0; }
    }
    return 1;
}
static inline int IN6_IS_ADDR_V4MAPPED(const struct in6_addr *addr) {
    for (int i = 0; i < 10; i++) {
        if (addr->s6_addr[i] != 0) { return 0; }
    }
    return addr->s6_addr[10] == 0xff && addr->s6_addr[11] == 0xff;
}
#define INADDR_ANY       ((in_addr_t)0x00000000UL)
#define INADDR_LOOPBACK  ((in_addr_t)0x7f000001UL)
#define INADDR_BROADCAST ((in_addr_t)0xffffffffUL)
#define INADDR_NONE      ((in_addr_t)0xffffffffUL)
#define INET_ADDRSTRLEN  16
#define INET6_ADDRSTRLEN 46
#define TCP_NODELAY      1
#define htons(x) ((unsigned short)__builtin_bswap16((unsigned short)(x)))
#define ntohs(x) ((unsigned short)__builtin_bswap16((unsigned short)(x)))
#define htonl(x) ((unsigned int)__builtin_bswap32((unsigned int)(x)))
#define ntohl(x) ((unsigned int)__builtin_bswap32((unsigned int)(x)))
#endif
