#ifndef _SWIFTOS_COMPAT_UNISTD_H
#define _SWIFTOS_COMPAT_UNISTD_H

#include_next <unistd.h>

int getpagesize(void);
int pipe2(int fds[2], int flags);
int execvpe(const char *file, char *const argv[], char *const envp[]);

#endif
