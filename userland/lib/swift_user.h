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

#endif // SWIFTOS_USER_SWIFT_USER_H
