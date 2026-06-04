#ifndef _SWIFTOS_UTMPX_H
#define _SWIFTOS_UTMPX_H
#include <sys/types.h>
struct utmpx { short ut_type; pid_t ut_pid; char ut_line[32]; char ut_id[4];
               char ut_user[32]; char ut_host[256]; long ut_tv; };
#define EMPTY 0
#define RUN_LVL 1
#define BOOT_TIME 2
#define USER_PROCESS 7
#define DEAD_PROCESS 8
void setutxent(void); void endutxent(void);
struct utmpx *getutxent(void); struct utmpx *pututxline(const struct utmpx *u);
#endif
