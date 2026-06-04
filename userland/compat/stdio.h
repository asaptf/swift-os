/* stdio.h — add POSIX getline prototype missing from bare-metal newlib. */
#ifndef _SWIFTOS_COMPAT_STDIO_H
#define _SWIFTOS_COMPAT_STDIO_H

#include_next <stdio.h>

ssize_t getline(char **lineptr, size_t *n, FILE *stream);

#endif
