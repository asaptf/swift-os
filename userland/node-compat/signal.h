// SPDX-License-Identifier: Apache-2.0
// signal.h - add SA_RESETHAND for the libuv masquerade, atop compat's signal.h.
#ifndef _SWOS_NODE_COMPAT_SIGNAL_H
#define _SWOS_NODE_COMPAT_SIGNAL_H

#include_next <signal.h>

#ifndef SA_RESETHAND
#define SA_RESETHAND 0x80000000
#endif
#ifndef SA_ONSTACK
#define SA_ONSTACK 0x08000000
#endif
#ifndef SA_NODEFER
#define SA_NODEFER 0x40000000
#endif
#ifndef SA_RESTART
#define SA_RESTART 0x10000000
#endif

/* siginfo si_code values V8's stack_trace_posix.cc maps for crash reports.
 * Standard Linux values; newlib's <signal.h> omits most of them. */
#ifndef SEGV_MAPERR
#define SEGV_MAPERR 1
#define SEGV_ACCERR 2
#endif
#ifndef BUS_ADRALN
#define BUS_ADRALN 1
#define BUS_ADRERR 2
#define BUS_OBJERR 3
#endif
#ifndef FPE_INTDIV
#define FPE_INTDIV 1
#define FPE_INTOVF 2
#define FPE_FLTDIV 3
#define FPE_FLTOVF 4
#define FPE_FLTUND 5
#define FPE_FLTRES 6
#define FPE_FLTINV 7
#define FPE_FLTSUB 8
#endif
#ifndef ILL_ILLOPC
#define ILL_ILLOPC 1
#define ILL_ILLOPN 2
#define ILL_ILLADR 3
#define ILL_ILLTRP 4
#define ILL_PRVOPC 5
#define ILL_PRVREG 6
#define ILL_COPROC 7
#define ILL_BADSTK 8
#endif
#ifndef TRAP_BRKPT
#define TRAP_BRKPT 1
#define TRAP_TRACE 2
#endif
#ifndef CLD_EXITED
#define CLD_EXITED    1
#define CLD_KILLED    2
#define CLD_DUMPED    3
#define CLD_TRAPPED   4
#define CLD_STOPPED   5
#define CLD_CONTINUED 6
#endif

#endif /* _SWOS_NODE_COMPAT_SIGNAL_H */
