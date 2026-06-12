// envchild.c - child-side environment handoff check for uvenvprobe.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern char **environ;

static int has_entry(char **envp, const char *needle) {
    if (!envp) {
        return 0;
    }
    for (int i = 0; envp[i]; i++) {
        if (strcmp(envp[i], needle) == 0) {
            return 1;
        }
    }
    return 0;
}

int main(int argc, char **argv, char **envp) {
    (void)argc;
    (void)argv;

    const char *alpha = getenv("SWOS_ENV_ALPHA");
    const char *beta = getenv("SWOS_ENV_BETA");
    const char *parent = getenv("SWOS_ENV_PARENT_ONLY");
    if (!alpha || strcmp(alpha, "alpha-child") != 0 ||
        !beta || strcmp(beta, "beta-child") != 0 ||
        parent != 0) {
        printf("envchild: FAIL: getenv alpha=%s beta=%s parent=%s\n",
               alpha ? alpha : "(null)",
               beta ? beta : "(null)",
               parent ? parent : "(null)");
        return 11;
    }
    printf("envchild: getenv inherited OK\n");

    if (environ != envp ||
        !has_entry(envp, "SWOS_ENV_ALPHA=alpha-child") ||
        !has_entry(environ, "SWOS_ENV_BETA=beta-child") ||
        has_entry(environ, "SWOS_ENV_PARENT_ONLY=parent-value")) {
        printf("envchild: FAIL: envp/environ mismatch\n");
        return 12;
    }
    printf("envchild: envp/environ pointers OK\n");

    printf("ENVCHILD-OK\n");
    return 7;
}
