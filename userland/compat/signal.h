/* signal.h — compat: newlib signal + missing sigaction flags/protos. */
#ifndef _SWIFTOS_COMPAT_SIGNAL_H
#define _SWIFTOS_COMPAT_SIGNAL_H

#define sigaction __swiftos_newlib_sigaction
#define siginfo_t __swiftos_newlib_siginfo_t
#include_next <signal.h>
#undef sigaction
#undef siginfo_t

#ifndef SA_RESTART
#define SA_RESTART 0x10000000
#endif
#ifndef SA_SIGINFO
#define SA_SIGINFO 0x00000004
#endif
#ifndef SA_NOCLDSTOP
#define SA_NOCLDSTOP 0x00000001
#endif
#ifndef SIG_BLOCK
#define SIG_BLOCK   0
#define SIG_UNBLOCK 1
#define SIG_SETMASK 2
#endif

typedef struct {
    int si_signo;
    int si_code;
    int si_pid;
    union sigval si_value;
} siginfo_t;

typedef void (*__swiftos_sa_handler_t)(int);
typedef void (*__swiftos_sa_sigaction_t)(int, siginfo_t *, void *);

struct sigaction {
    union {
        __swiftos_sa_handler_t sa_handler;
        __swiftos_sa_sigaction_t sa_sigaction;
    } __swiftos_handler;
    sigset_t sa_mask;
    int sa_flags;
};

#define sa_handler __swiftos_handler.sa_handler
#define sa_sigaction __swiftos_handler.sa_sigaction

int sigaction(int sig, const struct sigaction *act, struct sigaction *old);

#endif
