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
#define INADDR_ANY 0
#define htons(x) __builtin_bswap16(x)
#define ntohs(x) __builtin_bswap16(x)
#define htonl(x) __builtin_bswap32(x)
#define ntohl(x) __builtin_bswap32(x)
#endif
