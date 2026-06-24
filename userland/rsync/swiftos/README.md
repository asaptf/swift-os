# swift-os rsync overlay

This directory contains rsync-local build scaffolding only. It must not grow
the shared `userland/compat` ABI behind other workers' backs.

`scripts/build-rsync.sh` cross-builds official rsync `3.4.1` as a static AArch64
ELF against newlib + `userland/compat`, with bundled popt and zlib. OpenSSL,
xxhash/zstd/lz4, iconv, locale, IPv6, ACLs, xattrs, and the SIMD/asm
accelerators are disabled for the first package.

`at_compat.c` is a link-only shim for `openat()`. rsync 3.4.x references
`openat` in `secure_relative_open()` whenever `O_NOFOLLOW`, `O_DIRECTORY`, and
`AT_FDCWD` are all defined (they are, in the compat headers), independent of
`HAVE_OPENAT`. SwiftOS has no dirfd-relative (`*at`) syscalls, so the symbol is
otherwise unresolved. The shim stays rsync-local on purpose: a broadly-detected
`openat` in the shared compat layer would flip other ports' (e.g. nginx)
configure detection toward a path-walk SwiftOS cannot service. `AT_FDCWD` calls
degrade to plain `open()`; a real directory fd returns `ENOSYS` until the VFS
grows dirfd support.

Known runtime gaps (R1 ships build + `rsync --version` only): symlinks are
unsupported (no `symlink`/`readlink` syscalls), hardlinks degrade (`link()` ->
`EMLINK`), and mtime preservation is a no-op (`utimes`). Local-filesystem sync
and rsync-over-TCP/ssh transport are follow-up packages. Any behavior needed at
runtime beyond this link shim belongs in the main kernel/newlib/compat work, not
here.
