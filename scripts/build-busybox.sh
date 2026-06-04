#!/usr/bin/env bash
# build-busybox.sh — cross-build a minimal static busybox for swift-os.
#
# Produces build/busybox.elf: busybox (ash + ls/cat/echo/pwd, standalone shell)
# cross-compiled with aarch64-elf-gcc against ./sysroot (newlib) + our POSIX
# compat layer (userland/compat), then linked with our crt0/syscall stubs and
# user linker script. Embedded into the kernel image (kernel/user/user_blob.S).
#
# Requires: `make newlib` first (sysroot), aarch64-elf-gcc/binutils, network.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${BUSYBOX_VERSION:-1.38.0}"
WORK="$ROOT/userland/busybox"
SRC="$WORK/busybox-${VERSION}"
TARBALL="$WORK/busybox-${VERSION}.tar.bz2"
URL="https://busybox.net/downloads/busybox-${VERSION}.tar.bz2"
SYSROOT="$ROOT/sysroot/aarch64-elf"
COMPAT="$ROOT/userland/compat"
GCC=aarch64-elf-gcc
JOBS="${JOBS:-4}"

if [[ ! -f "$SYSROOT/lib/libc.a" ]]; then
    echo "FAIL: newlib sysroot missing. Run: make newlib" >&2
    exit 2
fi

mkdir -p "$WORK" "$ROOT/build"
[[ -f "$TARBALL" ]] || { echo "Fetching busybox ${VERSION}..."; curl -fsSL -o "$TARBALL" "$URL"; }
[[ -d "$SRC" ]] || tar -xjf "$TARBALL" -C "$WORK"

cd "$SRC"

# --- configuration -----------------------------------------------------------
# busybox ships no scripts/config; set symbols by editing .config, then let
# oldconfig settle dependencies (</dev/null keeps existing choices).
make allnoconfig >/dev/null 2>&1
set_sym() {
    local s="CONFIG_$1"
    if grep -qE "^# $s is not set|^$s=" .config; then
        sed -i.bak -E "s/^# $s is not set/$s=y/; s/^$s=.*/$s=y/" .config && rm -f .config.bak
    else
        echo "$s=y" >>.config
    fi
}
for sym in STATIC SHELL_ASH SH_IS_ASH FEATURE_SH_STANDALONE FEATURE_PREFER_APPLETS \
           ASH_BUILTIN_ECHO ASH_BUILTIN_TEST ASH_BUILTIN_PRINTF \
           LS CAT ECHO PWD; do
    set_sym "$sym"
done
make oldconfig </dev/null >/dev/null 2>&1

# --- compile busybox objects against newlib + compat -------------------------
make -j"$JOBS" ARCH=arm64 CROSS_COMPILE=aarch64-elf- \
    CONFIG_EXTRA_CFLAGS="-isystem $COMPAT -isystem $SYSROOT/include -ffreestanding -Wno-error" \
    >/dev/null 2>&1 || true  # busybox's own link fails (no crt0/-lc); objects are what we need

# --- our runtime objects -----------------------------------------------------
INC="-isystem $COMPAT -isystem $SYSROOT/include"
$GCC -ffreestanding -Os $INC -c "$ROOT/userland/lib/crt0_newlib.S"    -o "$ROOT/build/bb_crt0.o"
$GCC -ffreestanding -Os $INC -c "$ROOT/userland/lib/newlib_syscalls.c" -o "$ROOT/build/bb_sys.o"
$GCC -ffreestanding -Os $INC -c "$ROOT/userland/compat/stubs.c"        -o "$ROOT/build/bb_stubs.o"

# --- final link with our crt0 + script + newlib ------------------------------
BBOBJS=$(find "$SRC" -name built-in.o -o -name lib.a)
# shellcheck disable=SC2086
$GCC -nostartfiles -nostdlib -T "$ROOT/userland/user_newlib.ld" -Wl,-z,max-page-size=4096 \
    "$ROOT/build/bb_crt0.o" \
    -Wl,--start-group $BBOBJS "$ROOT/build/bb_sys.o" "$ROOT/build/bb_stubs.o" \
        -L "$SYSROOT/lib" -lc -lm -lgcc -Wl,--end-group \
    -o "$ROOT/build/busybox.elf"

echo "Built $ROOT/build/busybox.elf"
aarch64-elf-readelf -h "$ROOT/build/busybox.elf" | grep -E 'Type:|Entry'
