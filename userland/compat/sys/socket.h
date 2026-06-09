#ifndef _SWIFTOS_SOCKET_H
#define _SWIFTOS_SOCKET_H
#include <stddef.h>
#include <sys/types.h>
typedef unsigned int socklen_t;
typedef unsigned short sa_family_t;
struct sockaddr { sa_family_t sa_family; char sa_data[14]; };
struct sockaddr_storage { sa_family_t ss_family; char __pad[126]; };
struct linger { int l_onoff; int l_linger; };
struct cmsghdr { socklen_t cmsg_len; int cmsg_level; int cmsg_type; };
struct msghdr { void *msg_name; socklen_t msg_namelen; void *msg_iov; int msg_iovlen;
                void *msg_control; socklen_t msg_controllen; int msg_flags; };
#define AF_UNSPEC 0
#define AF_INET   2
#define AF_INET6  10
#define AF_UNIX   1
#define PF_UNSPEC AF_UNSPEC
#define PF_INET   AF_INET
#define PF_INET6  AF_INET6
#define PF_UNIX   AF_UNIX
#define SOCK_STREAM 1
#define SOCK_DGRAM  2
#define SOCK_RAW    3
#define SOCK_RDM    4
#define SOCK_SEQPACKET 5
#define SOCK_NONBLOCK 0x4000
#define SOCK_CLOEXEC  0x80000
#define SOL_SOCKET  1
#define SO_REUSEADDR 2
#define SO_REUSEPORT 15
#define SO_KEEPALIVE 9
#define SO_BROADCAST 6
#define SO_LINGER    13
#define SO_RCVBUF    8
#define SO_SNDBUF    7
#define SO_RCVLOWAT  18
#define SO_SNDLOWAT  19
#define SO_ERROR     4
#define SO_TYPE      3
#define SO_BINDTODEVICE 25
#define SOMAXCONN    128
#define IPPROTO_IP   0
#define IPPROTO_TCP  6
#define IPPROTO_UDP  17
#define MSG_PEEK     2
#define MSG_DONTWAIT 0x40
#define MSG_TRUNC    0x20
#define MSG_CTRUNC   0x08
#define MSG_NOSIGNAL 0x4000
#define SCM_RIGHTS   1
#define CMSG_ALIGN(n) (((n) + sizeof(size_t) - 1) & ~(sizeof(size_t) - 1))
#define CMSG_SPACE(n) (CMSG_ALIGN(sizeof(struct cmsghdr)) + CMSG_ALIGN(n))
#define CMSG_LEN(n)   (CMSG_ALIGN(sizeof(struct cmsghdr)) + (n))
#define CMSG_DATA(c)  ((unsigned char *)(c) + CMSG_ALIGN(sizeof(struct cmsghdr)))
#define SHUT_RD 0
#define SHUT_WR 1
#define SHUT_RDWR 2
long sendto(int, const void *, size_t, int, const struct sockaddr *, socklen_t);
long recvfrom(int, void *, size_t, int, struct sockaddr *, socklen_t *);
long sendmsg(int, const struct msghdr *, int);
long recvmsg(int, struct msghdr *, int);
int shutdown(int, int);
int socketpair(int, int, int, int[2]);

int socket(int domain, int type, int protocol);
int bind(int fd, const struct sockaddr *addr, socklen_t len);
int connect(int fd, const struct sockaddr *addr, socklen_t len);
int listen(int fd, int backlog);
int accept(int fd, struct sockaddr *addr, socklen_t *len);
long send(int fd, const void *buf, size_t n, int flags);
long recv(int fd, void *buf, size_t n, int flags);
int setsockopt(int fd, int level, int opt, const void *val, socklen_t len);
int getsockopt(int fd, int level, int opt, void *val, socklen_t *len);
int getsockname(int fd, struct sockaddr *addr, socklen_t *len);
int getpeername(int fd, struct sockaddr *addr, socklen_t *len);
#endif
