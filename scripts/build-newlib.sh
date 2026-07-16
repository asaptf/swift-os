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
# Primary + mirror: sourceware is occasionally unreachable from GitHub runners.
URLS=(
    "https://sourceware.org/pub/newlib/newlib-${VERSION}.tar.gz"
    "https://mirrors.kernel.org/sourceware/newlib/newlib-${VERSION}.tar.gz"
)

# Fast path when CI cache restored a complete sysroot (or a prior local build).
if [[ -f "$SYSROOT/aarch64-elf/lib/libc.a" && "${NEWLIB_FORCE:-0}" != "1" ]]; then
    echo "newlib already installed at $SYSROOT/aarch64-elf (set NEWLIB_FORCE=1 to rebuild)"
    ls -la "$SYSROOT/aarch64-elf/lib/libc.a"
    exit 0
fi

mkdir -p "$WORK"
cd "$WORK"

if [[ ! -d "newlib-${VERSION}" ]]; then
    tarball="newlib-${VERSION}.tar.gz"
    fetched=0
    for URL in "${URLS[@]}"; do
        echo "Fetching $URL ..."
        if curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors \
            --connect-timeout 30 --max-time 600 \
            -o "$tarball" "$URL"; then
            fetched=1
            break
        fi
        echo "warn: fetch failed for $URL" >&2
        rm -f "$tarball"
    done
    if [[ "$fetched" -ne 1 ]]; then
        echo "FAIL: could not download newlib ${VERSION} from any mirror" >&2
        exit 28
    fi
    tar xzf "$tarball"
fi

rm -rf build && mkdir build && cd build
"../newlib-${VERSION}/configure" \
    --target=aarch64-elf \
    --prefix="$SYSROOT" \
    --disable-newlib-supplied-syscalls \
    CFLAGS_FOR_TARGET="-D__DYNAMIC_REENT__" \
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
