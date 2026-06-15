// SPDX-License-Identifier: Apache-2.0
// sys/socket.h - add the AF_PACKET/PF_PACKET family atop the real header.
//
// libuv identifies the link-layer ifaddr entry by PF_PACKET. SwiftOS does not
// implement packet sockets; the value only needs to match what the companion
// getifaddrs() stamps on link-layer entries, so it is internally consistent.
#ifndef _SWOS_NODE_COMPAT_SYS_SOCKET_H
#define _SWOS_NODE_COMPAT_SYS_SOCKET_H

#include_next <sys/socket.h>

#ifndef AF_PACKET
#define AF_PACKET 17
#endif
#ifndef PF_PACKET
#define PF_PACKET AF_PACKET
#endif

/* Control-message iteration macros libuv uses (compat provides the rest:
 * struct cmsghdr/msghdr, CMSG_ALIGN/SPACE/LEN/DATA). */
#ifndef CMSG_FIRSTHDR
#define CMSG_FIRSTHDR(mhdr) \
    ((size_t)(mhdr)->msg_controllen >= sizeof(struct cmsghdr) \
        ? (struct cmsghdr *)(mhdr)->msg_control : (struct cmsghdr *)0)
#endif
#ifndef CMSG_NXTHDR
#define CMSG_NXTHDR(mhdr, cmsg) \
    ((cmsg) == (struct cmsghdr *)0 ? CMSG_FIRSTHDR(mhdr) : \
     (((unsigned char *)(cmsg) + CMSG_ALIGN((cmsg)->cmsg_len) \
        + sizeof(struct cmsghdr)) > \
       ((unsigned char *)(mhdr)->msg_control + (mhdr)->msg_controllen)) \
        ? (struct cmsghdr *)0 \
        : (struct cmsghdr *)((unsigned char *)(cmsg) + CMSG_ALIGN((cmsg)->cmsg_len)))
#endif

#ifndef MSG_CMSG_CLOEXEC
#define MSG_CMSG_CLOEXEC 0
#endif
#ifndef MSG_ERRQUEUE
#define MSG_ERRQUEUE 0x2000
#endif

/* Batched message I/O (libuv's recvmmsg/sendmmsg fast path). The companion
 * implementation returns -ENOSYS so libuv falls back to recvmsg/sendmsg. */
struct mmsghdr {
    struct msghdr msg_hdr;
    unsigned int  msg_len;
};
int recvmmsg(int fd, struct mmsghdr *msgvec, unsigned int vlen, int flags,
             struct timespec *timeout);
int sendmmsg(int fd, struct mmsghdr *msgvec, unsigned int vlen, int flags);

#endif /* _SWOS_NODE_COMPAT_SYS_SOCKET_H */
