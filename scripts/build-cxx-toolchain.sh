#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# build-cxx-toolchain.sh — build an aarch64-elf GCC with C++ + a newlib-targeted
# libstdc++, the prerequisite for the V8/Node.js port (NPM33).
#
# The Homebrew aarch64-elf-gcc is bare-metal and ships no libstdc++, so V8
# (overwhelmingly C++) cannot compile. This rebuilds GCC from source — matching
# the Homebrew version (16.1.0) — with --enable-languages=c,c++ --with-newlib,
# building libstdc++ against the newlib already installed in ./sysroot, and
# installs the c,c++ compilers + libstdc++ into the same ./sysroot prefix
# (gitignored, like the newlib sysroot). After it finishes, the V8 build can use
# sysroot/bin/aarch64-elf-g++.
#
# Long build (tens of minutes). Requires: ./sysroot newlib present (make newlib),
# aarch64-elf binutils on PATH, a host C/C++ compiler, network access.

set -euo pipefail

VERSION="${GCC_VERSION:-16.1.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYSROOT="$ROOT/sysroot"
WORK="${GCC_WORK:-${TMPDIR:-/tmp}/swiftos-gcc}"
URL="https://ftp.gnu.org/gnu/gcc/gcc-${VERSION}/gcc-${VERSION}.tar.xz"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

[[ -f "$SYSROOT/aarch64-elf/lib/libc.a" ]] || {
    echo "FAIL: newlib sysroot missing; run 'make newlib' first." >&2; exit 2; }
command -v aarch64-elf-as >/dev/null 2>&1 || {
    echo "FAIL: aarch64-elf binutils not on PATH." >&2; exit 2; }

mkdir -p "$WORK"
cd "$WORK"

if [[ ! -d "gcc-${VERSION}" ]]; then
    echo "Fetching $URL ..."
    curl -fsSL -o "gcc-${VERSION}.tar.xz" "$URL"
    tar xf "gcc-${VERSION}.tar.xz"
fi

# Pull in gmp/mpfr/mpc/isl in-tree (robust across host package layouts).
( cd "gcc-${VERSION}" && [[ -d gmp ]] || ./contrib/download_prerequisites )

rm -rf build && mkdir build && cd build
"../gcc-${VERSION}/configure" \
    --target=aarch64-elf \
    --prefix="$SYSROOT" \
    --with-newlib \
    --enable-languages=c,c++ \
    --disable-shared \
    --disable-threads \
    --disable-libssp \
    --disable-libstdcxx-verbose \
    --disable-libstdcxx-pch \
    --disable-nls \
    --disable-libgomp \
    --disable-libquadmath \
    --with-gnu-as \
    --with-gnu-ld

# gcc + target libgcc + target libstdc++ only (skip the rest of the runtime).
make -j"$JOBS" all-gcc
make -j"$JOBS" all-target-libgcc
make -j"$JOBS" all-target-libstdc++-v3
make install-gcc install-target-libgcc install-target-libstdc++-v3

# The installed compilers look for their assembler/linker in
# $prefix/aarch64-elf/bin; the binutils live in a separate (Homebrew) prefix, so
# symlink them into place. Without this the driver falls back to the host `as`
# and miscompiles target assembly.
mkdir -p "$SYSROOT/aarch64-elf/bin"
for t in as ld ar nm ranlib strip objcopy objdump; do
    src="$(command -v "aarch64-elf-$t" 2>/dev/null || true)"
    [[ -n "$src" ]] && ln -sf "$src" "$SYSROOT/aarch64-elf/bin/$t"
done

echo "Installed C++ toolchain into $SYSROOT"
echo "  g++:        $SYSROOT/bin/aarch64-elf-g++"
"$SYSROOT/bin/aarch64-elf-g++" -print-file-name=libstdc++.a
