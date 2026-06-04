/* signal.h — compat: newlib signal + missing sigaction flags/protos. */
#ifndef _SWIFTOS_COMPAT_SIGNAL_H
#define _SWIFTOS_COMPAT_SIGNAL_H
#include_next <signal.h>
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
#endif
