# swift-os nginx overlay

This directory contains nginx-local build scaffolding only.  It must not grow
the shared `userland/compat` ABI behind other workers' backs.

The default probe builds official nginx `1.30.2` with `--crossbuild=SwiftOS:0:aarch64`
and the upstream POSIX fallback OS path.  The patch:

- keeps the machine part (`aarch64`) instead of assuming i386;
- hardcodes type sizes and little-endian for the freestanding target;
- never executes configure feature probes on the build host.

That last point matters on aarch64 Linux CI: freestanding `aarch64-elf`
`autotest` binaries are loadable by the host kernel and hang forever (no Linux
ABI), which previously stalled `make base-image` / nightly ops gates for hours.

The `include/` headers describe small source-level ABI shapes that newlib may
not provide yet, so the probe can reach link/syscall gaps such as vectored I/O
and socket options.  Any behavior needed at runtime still belongs in the main
kernel/newlib/compat work, not here.
