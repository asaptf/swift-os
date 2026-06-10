#!/usr/bin/env bash
# build-zlib.sh - cross-build zlib and publish a signed local package repository.
#
# Produces:
#   build/zlib.swpkg
#   build/zlib-repo-root/aarch64/current/catalog.signed
#   build/zlib-repo-root.pub
#
# Requires: `make newlib` first (sysroot), aarch64-elf-gcc/binutils, and
# build/swport + build/swpkg + build/pkgrepo.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${ZLIB_VERSION:-1.3.1}"
DISTFILES="${ZLIB_DISTFILES:-$ROOT/build/swport-distfiles}"
WORK="$ROOT/build/zlib-port-work"
SRC="$WORK/zlib-${VERSION}"
RUNTIME="$ROOT/build/zlib-port-runtime"
STAGE="$ROOT/build/zlib-root"
PACKAGE="$ROOT/build/zlib.swpkg"
REPO_ROOT="$ROOT/build/zlib-repo-root"
REPO_PUB="$ROOT/build/zlib-repo-root.pub"
SYSROOT="${ZLIB_SYSROOT:-$ROOT/sysroot/aarch64-elf}"
COMPAT="$ROOT/userland/compat"
CHOST="${ZLIB_CHOST:-aarch64-elf}"
CC="${ZLIB_CC:-aarch64-elf-gcc}"
READELF="${ZLIB_READELF:-aarch64-elf-readelf}"
NM="${ZLIB_NM:-aarch64-elf-nm}"
STRIP="${ZLIB_STRIP:-aarch64-elf-strip}"
JOBS="${JOBS:-4}"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 2
}

require_exe() {
    command -v "$1" >/dev/null 2>&1 || fail "missing executable: $1"
}

require_exe "$CC"
require_exe "$READELF"
require_exe "$NM"
require_exe "$STRIP"
require_exe make
require_exe tar

[[ -x "$ROOT/build/swport" ]] || fail "missing build/swport; run make swport"
[[ -x "$ROOT/build/swpkg" ]] || fail "missing build/swpkg; run make swpkg"
[[ -x "$ROOT/build/pkgrepo" ]] || fail "missing build/pkgrepo; run make pkgrepo"
[[ -f "$SYSROOT/lib/libc.a" ]] || fail "newlib sysroot missing. Run: make newlib"

mkdir -p "$DISTFILES" "$WORK" "$RUNTIME" "$ROOT/build"
"$ROOT/build/swport" recipe fetch archivers/zlib --cache "$DISTFILES"

rm -rf "$SRC"
tar xzf "$DISTFILES/zlib-${VERSION}.tar.gz" -C "$WORK"

inc_flags=(-isystem "$COMPAT" -isystem "$SYSROOT/include")
runtime_cflags=(-ffreestanding -Os "${inc_flags[@]}")

"$CC" "${runtime_cflags[@]}" -c "$ROOT/userland/lib/crt0_newlib.S" \
    -o "$RUNTIME/crt0_newlib.o"
"$CC" "${runtime_cflags[@]}" -c "$ROOT/userland/lib/newlib_syscalls.c" \
    -o "$RUNTIME/newlib_syscalls.o"

(
    cd "$SRC"
    export CHOST
    export CC
    export CFLAGS="-ffreestanding -Os -isystem $COMPAT -isystem $SYSROOT/include"
    export LDFLAGS="-static -nostartfiles -nostdlib -T $ROOT/userland/user_newlib.ld -Wl,-z,max-page-size=4096 $RUNTIME/crt0_newlib.o $RUNTIME/newlib_syscalls.o -L$SYSROOT/lib"
    ./configure --static --prefix=/usr
    make -j"$JOBS" libz.a minigzip \
        TEST_LIBS="-L. libz.a -Wl,--start-group -lc -lgcc -Wl,--end-group"
)

undefined="$("$NM" -u "$SRC/minigzip")"
[[ -z "$undefined" ]] || fail "minigzip has undefined symbols: $undefined"
"$READELF" -h "$SRC/minigzip" | grep -q 'Machine:[[:space:]]*AArch64' ||
    fail "minigzip is not an AArch64 ELF"
"$STRIP" "$SRC/minigzip"

rm -rf "$STAGE" "$PACKAGE" "$REPO_ROOT" "$REPO_PUB"
mkdir -p "$STAGE/usr/bin" "$STAGE/usr/include" "$STAGE/usr/lib/pkgconfig"
cp "$SRC/minigzip" "$STAGE/usr/bin/minigzip"
cp "$SRC/zconf.h" "$SRC/zlib.h" "$STAGE/usr/include/"
cp "$SRC/libz.a" "$STAGE/usr/lib/libz.a"
cp "$SRC/zlib.pc" "$STAGE/usr/lib/pkgconfig/zlib.pc"
chmod 0755 "$STAGE/usr/bin/minigzip"
chmod 0644 "$STAGE/usr/include/zconf.h" "$STAGE/usr/include/zlib.h" \
    "$STAGE/usr/lib/libz.a" "$STAGE/usr/lib/pkgconfig/zlib.pc"

"$ROOT/build/swport" recipe package archivers/zlib \
    --root "$STAGE" \
    --output "$PACKAGE" \
    --swpkg "$ROOT/build/swpkg"

"$ROOT/build/swport" recipe repo-fixture archivers/zlib \
    --root "$STAGE" \
    --output "$REPO_ROOT" \
    --pubkey "$REPO_PUB" \
    --swpkg "$ROOT/build/swpkg" \
    --pkgrepo "$ROOT/build/pkgrepo"

printf 'Built %s\n' "$PACKAGE"
printf 'Published signed repo fixture %s\n' "$REPO_ROOT/aarch64/current"
