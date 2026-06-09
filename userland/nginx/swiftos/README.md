# swift-os nginx overlay

This directory contains nginx-local build scaffolding only.  It must not grow
the shared `userland/compat` ABI behind other workers' backs.

The default probe builds official nginx `1.30.2` with `--crossbuild=SwiftOS:0:aarch64`
and the upstream POSIX fallback OS path.  The patch only teaches nginx's
cross-build mode to keep the machine part (`aarch64`) instead of assuming i386.

The `include/` headers describe small source-level ABI shapes that newlib may
not provide yet, so the probe can reach link/syscall gaps such as vectored I/O
and socket options.  Any behavior needed at runtime still belongs in the main
kernel/newlib/compat work, not here.
