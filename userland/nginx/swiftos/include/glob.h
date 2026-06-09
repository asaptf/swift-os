#ifndef _SWIFTOS_NGINX_GLOB_H
#define _SWIFTOS_NGINX_GLOB_H

#include <stddef.h>

typedef struct {
    size_t gl_pathc;
    char **gl_pathv;
    size_t gl_offs;
} glob_t;

#define GLOB_NOMATCH 3

int glob(const char *pattern, int flags,
    int (*errfunc)(const char *epath, int eerrno), glob_t *pglob);
void globfree(glob_t *pglob);

#endif
