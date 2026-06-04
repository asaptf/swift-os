#!/usr/bin/env bash
# build-newlib.sh — cross-build newlib for aarch64-elf into ./sysroot.
#
# One-time setup for the userland C library (see docs/NOTES.md). Requires the
# aarch64-elf GNU toolchain (brew install aarch64-elf-gcc aarch64-elf-binutils)
# and network access to fetch the newlib release. Installs libc.a/libm.a +
# headers under sysroot/aarch64-elf/. libgloss is intentionally not installed —
# swift-os provides its own syscall stubs (userland/lib/newlib_syscalls.c).

set -euo pipefail

VERSION="${NEWLIB_VERSION:-4.6.0.20260123}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYSROOT="$ROOT/sysroot"
WORK="${TMPDIR:-/tmp}/swiftos-newlib"
URL="https://sourceware.org/pub/newlib/newlib-${VERSION}.tar.gz"

mkdir -p "$WORK"
cd "$WORK"

if [[ ! -d "newlib-${VERSION}" ]]; then
    echo "Fetching $URL ..."
    curl -fsSL -o "newlib-${VERSION}.tar.gz" "$URL"
    tar xzf "newlib-${VERSION}.tar.gz"
fi

rm -rf build && mkdir build && cd build
"../newlib-${VERSION}/configure" \
    --target=aarch64-elf \
    --prefix="$SYSROOT" \
    --disable-newlib-supplied-syscalls \
    CC_FOR_TARGET=aarch64-elf-gcc \
    AS_FOR_TARGET=aarch64-elf-as \
    AR_FOR_TARGET=aarch64-elf-ar \
    RANLIB_FOR_TARGET=aarch64-elf-ranlib \
    LD_FOR_TARGET=aarch64-elf-ld

# Build only the target C library (libgloss docs need makeinfo we don't have,
# and we don't use libgloss anyway).
make all-target-newlib
make install-target-newlib

echo "newlib installed into $SYSROOT/aarch64-elf"
ls -la "$SYSROOT/aarch64-elf/lib/libc.a"
