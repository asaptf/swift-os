#ifndef _SWIFTOS_NETDB_H
#define _SWIFTOS_NETDB_H
#include <netinet/in.h>
struct hostent { char *h_name; char **h_aliases; int h_addrtype; int h_length; char **h_addr_list; };
#define h_addr h_addr_list[0]
struct servent { char *s_name; char **s_aliases; int s_port; char *s_proto; };
struct addrinfo { int ai_flags, ai_family, ai_socktype, ai_protocol; socklen_t ai_addrlen;
                  struct sockaddr *ai_addr; char *ai_canonname; struct addrinfo *ai_next; };
struct hostent *gethostbyname(const char *name);
int getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res);
void freeaddrinfo(struct addrinfo *res);
const char *gai_strerror(int errcode);
#define AI_PASSIVE     0x01
#define AI_CANONNAME   0x02
#define AI_NUMERICHOST 0x04
#define AI_NUMERICSERV 0x08
#define AI_V4MAPPED    0x10
#define AI_ALL         0x20
#define AI_ADDRCONFIG  0x40
#define NI_NUMERICHOST 0x01
#define NI_NUMERICSERV 0x02
#define NI_NOFQDN      0x04
#define NI_NAMEREQD    0x08
#define NI_DGRAM       0x10
#define NI_NUMERICSCOPE 0x20
#define NI_MAXHOST     1025
#define NI_MAXSERV     32
#define EAI_BADFLAGS   -1
#define EAI_NONAME     -2
#define EAI_AGAIN      -3
#define EAI_FAIL       -4
#define EAI_FAMILY     -6
#define EAI_MEMORY     -10
#define EAI_SERVICE    -8
#define EAI_SOCKTYPE   -7
int getnameinfo(const struct sockaddr *, socklen_t, char *, socklen_t, char *, socklen_t, int);
struct hostent *gethostbyaddr(const void *, socklen_t, int);

extern int h_errno;
#define HOST_NOT_FOUND 1
#define TRY_AGAIN      2
#define NO_RECOVERY    3
#define NO_DATA        4
#define NO_ADDRESS     NO_DATA
const char *hstrerror(int err);
#endif
