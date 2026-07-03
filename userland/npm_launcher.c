// SPDX-License-Identifier: Apache-2.0
// npm_launcher.c — exec busybox ash on the SwiftOS npm shim script.
//
// SwiftOS exec loads ELF only (no kernel shebang). /bin/npm is this tiny
// launcher; the install/--version fast paths live in /usr/lib/npm-swos.sh.

#include <unistd.h>

extern char **environ;

static const char script[] = "/usr/lib/npm-swos.sh";

int main(int argc, char **argv) {
    char *nargv[64];
    int i;
    int j = 0;

    if (argc < 1 || argc + 2 >= 64) {
        return 127;
    }

    nargv[j++] = "busybox";
    nargv[j++] = "sh";
    nargv[j++] = (char *)script;
    for (i = 1; i < argc; i++) {
        nargv[j++] = argv[i];
    }
    nargv[j] = 0;

    execve("/bin/busybox", nargv, environ);
    return 127;
}