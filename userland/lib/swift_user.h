// swift_user.h — C bridge used by Embedded Swift userland programs.

#ifndef SWIFTOS_USER_SWIFT_USER_H
#define SWIFTOS_USER_SWIFT_USER_H

#define SWIFTOS_PS_MAX 16

struct swiftos_ps_entry {
    unsigned int pid;
    unsigned int ppid;
    unsigned int state;
    char name[20];
};

int swiftos_ps_refresh(void);
unsigned int swiftos_ps_pid(int index);
unsigned int swiftos_ps_ppid(int index);
unsigned int swiftos_ps_state(int index);
const char *swiftos_ps_name(int index);

void swiftos_putc(unsigned char c);
void swiftos_puts(const char *s);
// Write count bytes to fd; returns bytes written (or negative errno).
long swiftos_write(int fd, const void *buf, unsigned long count);
// Current working directory into buf (size bytes); returns length or negative.
long swiftos_getcwd(char *buf, unsigned long size);
// Filesystem mutations (tmpfs only; the base is read-only). 0 on success, else
// a negative errno.
int swiftos_mkdir(const char *path);
int swiftos_rmdir(const char *path);
int swiftos_unlink(const char *path);
int swiftos_rename(const char *oldpath, const char *newpath);
int swiftos_chmod(const char *path, unsigned int mode);
int swiftos_chown(const char *path, unsigned int owner);
// Current wall-clock time in Unix seconds (0 if no RTC).
unsigned long swiftos_time(void);
// Current program break (sbrk(0)) — for reporting bounded heap growth.
unsigned long swiftos_heap_break(void);
// Format Unix seconds as UTC "YYYY-MM-DD HH:MM:SS" into out (>= 20 bytes).
void swiftos_fmt_time(unsigned long t, char *out);

// Thin syscall bridges for Swift userland (e.g. console-login).
int  swiftos_open(const char *path, int flags);
long swiftos_read(int fd, void *buf, unsigned long count);
int  swiftos_close(int fd);
// Read directory entries (kernel dirent layout) into buf; returns bytes used.
long swiftos_getdents(int fd, void *buf, unsigned long count);
// Stat a path. Fills the provided fields (any may be NULL). Returns 0 on success.
int  swiftos_stat(const char *path, unsigned int *mode, unsigned int *uid,
                  unsigned int *gid, unsigned int *nlink, unsigned long *size,
                  unsigned long *mtime);
int  swiftos_login(unsigned int principal, unsigned int session, unsigned long caps);
// Fetch the current security context; returns 0 on success.
int  swiftos_context(unsigned int *principal, unsigned int *session, unsigned long *caps);
// Replace this image with `path`, passing argv = { "sh", NULL }. Returns on error.
int  swiftos_exec_shell(const char *path);
// Toggle terminal echo on fd 0 (off while reading a password). Non-zero = on.
void swiftos_set_echo(int on);

// UDP sockets (net-b). IPv4 addresses are host order (e.g. 0x0A000202 = 10.0.2.2).
// swiftos_socket() opens a SOCK_DGRAM socket (needs the net capability) and
// returns an fd, or a negative errno.
int  swiftos_socket(void);
int  swiftos_bind(int fd, unsigned short port);
long swiftos_sendto(int fd, const void *buf, unsigned long len,
                    unsigned int ip, unsigned short port);
// Receive one datagram (blocking, bounded). Fills *ip/*port (may be NULL) with
// the sender. Returns the byte count or a negative errno.
long swiftos_recvfrom(int fd, void *buf, unsigned long cap,
                      unsigned int *ip, unsigned short *port);

// TCP (net-c2). swiftos_socket_stream() opens a SOCK_STREAM socket; data is read
// and written with swiftos_read/swiftos_write on the (accepted) connection fd.
int swiftos_socket_stream(void);
int swiftos_listen(int fd, int backlog);
int swiftos_accept(int fd);
// Active open to (ip, port) — ip is host order (e.g. 0x0A000202 = 10.0.2.2).
int swiftos_connect(int fd, unsigned int ip, unsigned short port);
// Wait for events on a set of fds. `fds` points at an array of pollfd records
// (fd:int32 @0, events:int16 @4, revents:int16 @6 — 8 bytes each). POLLIN=0x001,
// POLLOUT=0x004, POLLHUP=0x010. Returns the number of ready fds, 0 on timeout.
long swiftos_poll(void *fds, unsigned long nfds, long timeout_ms);

#endif // SWIFTOS_USER_SWIFT_USER_H
