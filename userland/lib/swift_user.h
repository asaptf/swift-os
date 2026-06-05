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

// Thin syscall bridges for Swift userland (e.g. console-login).
int  swiftos_open(const char *path, int flags);
long swiftos_read(int fd, void *buf, unsigned long count);
int  swiftos_close(int fd);
int  swiftos_login(unsigned int principal, unsigned int session, unsigned long caps);
// Fetch the current security context; returns 0 on success.
int  swiftos_context(unsigned int *principal, unsigned int *session, unsigned long *caps);
// Replace this image with `path`, passing argv = { "sh", NULL }. Returns on error.
int  swiftos_exec_shell(const char *path);
// Toggle terminal echo on fd 0 (off while reading a password). Non-zero = on.
void swiftos_set_echo(int on);

#endif // SWIFTOS_USER_SWIFT_USER_H
