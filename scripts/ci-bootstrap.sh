#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# ci-bootstrap.sh — one-shot Linux CI bootstrap for swift-os.
#
# Installs apt dependencies and pinned toolchains, exports PATH/Makefile
# overrides for Ubuntu runners, then builds newlib, busybox, and fetches test
# models. Idempotent where the underlying steps are (skip installed toolchains,
# skip present artifacts).
#
# Signing keys (P0): CI uses auto-generated dev keys under models/ (gitignored).
# Production releases override via environment variables passed to make:
#   SWOS_IMG_SIGNING_SEED   — base image / kernel trust root
#   SWOS_SIGNING_SEED       — model bundle signing
#   SWOS_SITE_SIGNING_SEED  — static site (SWSITE) bundles
#   SWOS_SIGNING_PROFILE=prod — recorded in build/release-manifest.json

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=ci/toolchain.env
source "$ROOT/ci/toolchain.env"

echo "==> ci-bootstrap: installing apt dependencies"
"$ROOT/scripts/ci-install-deps.sh"

echo "==> ci-bootstrap: installing Swift + ARM GNU toolchains"
"$ROOT/scripts/ci-install-toolchain.sh"

SWIFT_DIR="${SWIFT_INSTALL_DIR:-$HOME/.swift/toolchains/swift-$SWIFT_VERSION}"
ARM_GNU_DIR="${ARM_GNU_INSTALL_DIR:-$HOME/.local/arm-gnu-toolchain}"
LOCAL_BIN="${LOCAL_BIN_DIR:-$HOME/.local/bin}"

export PATH="$SWIFT_DIR/usr/bin:$ARM_GNU_DIR/bin:$LOCAL_BIN:$PATH"

# Linux CI overrides (Makefile defaults target macOS/Homebrew paths).
export TOOLCHAIN="$SWIFT_DIR"
export SWIFTC="$SWIFT_DIR/usr/bin/swiftc"
export HOST_SWIFTC="${HOST_SWIFTC:-$SWIFT_DIR/usr/bin/swiftc}"
export LLVM="${LLVM:-/usr/lib/llvm-18/bin}"
if [[ ! -x "$LLVM/clang" ]]; then
    LLVM=/usr/bin
fi
export CLANG="${CLANG:-$LLVM/clang}"
export LDBIN="${LDBIN:-$(command -v ld.lld)}"
export OBJCOPY="${OBJCOPY:-$(command -v llvm-objcopy)}"
export QEMU="${QEMU:-$(command -v qemu-system-aarch64)}"
export GDB="${GDB:-$(command -v aarch64-elf-gdb)}"

echo "==> ci-bootstrap: toolchain check"
"$SWIFTC" --version | head -1
command -v aarch64-elf-gcc >/dev/null
aarch64-elf-gcc --version | head -1

# Skip rebuilds when Actions cache restored sysroot / busybox.elf — avoids a
# fragile sourceware.org fetch on every job when the artifact is already good.
if [[ -f "$ROOT/sysroot/aarch64-elf/lib/libc.a" ]]; then
    echo "==> ci-bootstrap: newlib already present (sysroot), skipping"
else
    echo "==> ci-bootstrap: make newlib"
    make -C "$ROOT" newlib \
        NEWLIB_VERSION="$NEWLIB_VERSION"
fi

if [[ -f "$ROOT/build/busybox.elf" ]]; then
    echo "==> ci-bootstrap: busybox.elf already present, skipping"
else
    echo "==> ci-bootstrap: make busybox"
    make -C "$ROOT" busybox \
        BUSYBOX_VERSION="$BUSYBOX_VERSION"
fi

echo "==> ci-bootstrap: fetch test models"
"$ROOT/scripts/fetch-model.sh"

echo "==> ci-bootstrap: prefetch base-image port distfiles"
make -C "$ROOT" swport
mkdir -p "$ROOT/build/swport-distfiles"
for port in databases/sqlite www/nginx security/openssl; do
    "$ROOT/build/swport" recipe fetch "$port" --cache "$ROOT/build/swport-distfiles"
done

echo "ci-bootstrap: OK"