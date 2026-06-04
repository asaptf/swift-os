#ifndef _SWIFTOS_SHADOW_H
#define _SWIFTOS_SHADOW_H
struct spwd { char *sp_namp; char *sp_pwdp; long sp_lstchg, sp_min, sp_max, sp_warn, sp_inact, sp_expire; unsigned long sp_flag; };
struct spwd *getspnam(const char *name);
#endif
