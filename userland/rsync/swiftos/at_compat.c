// SPDX-License-Identifier: Apache-2.0
//
// rsync-local link shims (openat, execlp) — kept out of the shared
// userland/compat layer on purpose; see README.md in this directory.
//
// --- openat() ---
//
// rsync 3.4.x's secure_relative_open() (syscall.c) uses openat() whenever
// O_NOFOLLOW, O_DIRECTORY, and AT_FDCWD are all defined — which they are in the
// SwiftOS compat headers — even though config.h leaves HAVE_OPENAT undefined
// (the symbol is referenced via those O_* macros, not gated on HAVE_OPENAT).
// SwiftOS has no dirfd-relative (`*at`) syscalls, so the symbol is otherwise
// unresolved at link time.
//
// This shim is deliberately rsync-local rather than part of the shared
// userland/compat layer: dropping a broadly-detected openat() into the shared
// ABI would flip other ports' (e.g. nginx) configure detection toward the
// dirfd-relative path-walk that SwiftOS cannot service, regressing them. Here it
// only satisfies rsync's link. AT_FDCWD calls — the common case, and all that
// rsync's non-walk paths use — degrade to plain open(); a real directory fd
// (the symlink-safe path walk) returns ENOSYS until the VFS grows dirfd support.
// R1 ships `rsync --version`, which never reaches this code.

#include <fcntl.h>
#include <errno.h>
#include <stdarg.h>
#include <unistd.h>

__attribute__((weak))
int openat(int dirfd, const char *path, int flags, ...)
{
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }

    if (dirfd != AT_FDCWD) {
        // No dirfd-relative open support in the SwiftOS VFS yet.
        errno = ENOSYS;
        return -1;
    }

    if (flags & O_CREAT) {
        return open(path, flags, mode);
    }
    return open(path, flags);
}

// --- execlp() ---
//
// rsync's do_cmd()/shell exec (main.c) launches the remote-shell transport via
// execlp(), which newlib does not provide. It is a thin varargs wrapper over
// execvp() (which the shared compat layer does provide). Not reached by
// `rsync --version`; needed at link time and for the R2 transport work.

__attribute__((weak))
int execlp(const char *file, const char *arg, ...)
{
    // Two passes over the varargs: first count, then materialize argv on the
    // stack. The list is NULL-terminated, with `arg` as argv[0].
    int argc = 1;
    va_list ap;
    va_start(ap, arg);
    while (va_arg(ap, char *) != (char *)0)
        argc++;
    va_end(ap);

    char *argv[argc + 1];
    argv[0] = (char *)arg;
    va_start(ap, arg);
    for (int i = 1; i < argc; i++)
        argv[i] = va_arg(ap, char *);
    argv[argc] = (char *)0;
    va_end(ap);

    return execvp(file, argv);
}
