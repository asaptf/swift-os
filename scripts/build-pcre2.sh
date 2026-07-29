#!/usr/bin/env bash
# build-pcre2.sh - cross-build PCRE2 and publish a signed local package repository.
#
# Produces:
#   build/pcre2.swpkg
#   build/pcre2-repo-root/aarch64/current/catalog.signed
#   build/pcre2-repo-root.pub
#
# Requires: `make newlib` first (sysroot), aarch64-elf-gcc/binutils, and
# build/swport + build/swpkg + build/pkgrepo.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/host-tools.sh
source "$ROOT/scripts/host-tools.sh"
VERSION="${PCRE2_VERSION:-10.47}"
DISTFILES="${PCRE2_DISTFILES:-$ROOT/build/swport-distfiles}"
WORK="$ROOT/build/pcre2-port-work"
SRC="$WORK/pcre2-${VERSION}"
RUNTIME="$ROOT/build/pcre2-port-runtime"
STAGE="$ROOT/build/pcre2-root"
PACKAGE="$ROOT/build/pcre2.swpkg"
REPO_ROOT="$ROOT/build/pcre2-repo-root"
REPO_PUB="$ROOT/build/pcre2-repo-root.pub"
SYSROOT="${PCRE2_SYSROOT:-$ROOT/sysroot/aarch64-elf}"
COMPAT="$ROOT/userland/compat"
CC="${PCRE2_CC:-aarch64-elf-gcc}"
AR="${PCRE2_AR:-aarch64-elf-ar}"
RANLIB="${PCRE2_RANLIB:-aarch64-elf-ranlib}"
READELF="${PCRE2_READELF:-aarch64-elf-readelf}"
NM="${PCRE2_NM:-aarch64-elf-nm}"
STRIP="${PCRE2_STRIP:-aarch64-elf-strip}"
JOBS="${JOBS:-4}"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 2
}

require_exe() {
    command -v "$1" >/dev/null 2>&1 || fail "missing executable: $1"
}

require_exe "$CC"
require_exe "$AR"
require_exe "$RANLIB"
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
"$ROOT/build/swport" recipe fetch devel/pcre2 --cache "$DISTFILES"

rm -rf "$SRC"
tar xzf "$DISTFILES/pcre2-${VERSION}.tar.gz" -C "$WORK"

inc_flags=(-isystem "$COMPAT" -isystem "$SYSROOT/include")
runtime_cflags=(-ffreestanding -Os "${inc_flags[@]}")

"$CC" "${runtime_cflags[@]}" -c "$ROOT/userland/lib/crt0_newlib.S" \
    -o "$RUNTIME/crt0_newlib.o"
"$CC" "${runtime_cflags[@]}" -c "$ROOT/userland/lib/newlib_syscalls.c" \
    -o "$RUNTIME/newlib_syscalls.o"

configure_ldflags="-static -nostartfiles -nostdlib -T $ROOT/userland/user_newlib.ld -Wl,-z,max-page-size=4096 $RUNTIME/crt0_newlib.o $RUNTIME/newlib_syscalls.o -L$SYSROOT/lib"
program_ldflags="$configure_ldflags"
libtool_ldflags="-static -L$SYSROOT/lib"
libs="-Wl,--start-group -lc -lgcc -Wl,--end-group"

(
    cd "$SRC"
    export CC AR RANLIB
    export CFLAGS="-ffreestanding -Os -isystem $COMPAT -isystem $SYSROOT/include"
    export LDFLAGS="$configure_ldflags"
    export LIBS="$libs"
    # newlib dirent is incomplete for PCRE2's probe set; disable rather than
    # claim a full POSIX dirent (compile would partially succeed then fail later).
    export ac_cv_header_dirent_h=no
    # --host alone leaves cross_compiling=maybe; AC_PROG_CC then runs a.out and
    # hangs on same-arch Linux CI. See scripts/host-tools.sh autoconf_cross_*.
    autoconf_cross_prepare
    ./configure \
        --host=aarch64-elf \
        "$(autoconf_cross_build_arg)" \
        --prefix=/usr \
        --disable-shared \
        --enable-static \
        --disable-jit \
        --disable-pcre2-16 \
        --disable-pcre2-32 \
        --disable-pcre2grep-jit \
        --disable-pcre2grep-callout \
        --disable-pcre2grep-callout-fork \
        --disable-pcre2test-libreadline \
        --disable-pcre2test-libedit \
        --disable-dependency-tracking
    make -j"$JOBS" libpcre2-8.la libpcre2-posix.la \
        LDFLAGS="$libtool_ldflags" \
        LIBS=""
    make -j"$JOBS" pcre2grep \
        LDFLAGS="$program_ldflags" \
        LIBS="$libs"
)

undefined="$("$NM" -u "$SRC/pcre2grep")"
[[ -z "$undefined" ]] || fail "pcre2grep has undefined symbols: $undefined"
"$READELF" -h "$SRC/pcre2grep" | grep -q 'Machine:[[:space:]]*AArch64' ||
    fail "pcre2grep is not an AArch64 ELF"
"$STRIP" "$SRC/pcre2grep"

rm -rf "$STAGE" "$PACKAGE" "$REPO_ROOT" "$REPO_PUB"
mkdir -p "$STAGE/usr/bin" "$STAGE/usr/include" "$STAGE/usr/lib/pkgconfig"
cp "$SRC/pcre2grep" "$STAGE/usr/bin/pcre2grep"
cp "$SRC/src/pcre2.h" "$SRC/src/pcre2posix.h" "$STAGE/usr/include/"
cp "$SRC/.libs/libpcre2-8.a" "$STAGE/usr/lib/libpcre2-8.a"
cp "$SRC/.libs/libpcre2-posix.a" "$STAGE/usr/lib/libpcre2-posix.a"
cp "$SRC/libpcre2-8.pc" "$SRC/libpcre2-posix.pc" "$STAGE/usr/lib/pkgconfig/"
chmod 0755 "$STAGE/usr/bin/pcre2grep"
chmod 0644 "$STAGE/usr/include/pcre2.h" "$STAGE/usr/include/pcre2posix.h" \
    "$STAGE/usr/lib/libpcre2-8.a" "$STAGE/usr/lib/libpcre2-posix.a" \
    "$STAGE/usr/lib/pkgconfig/libpcre2-8.pc" "$STAGE/usr/lib/pkgconfig/libpcre2-posix.pc"

"$ROOT/build/swport" recipe package devel/pcre2 \
    --root "$STAGE" \
    --output "$PACKAGE" \
    --swpkg "$ROOT/build/swpkg"

"$ROOT/build/swport" recipe repo-fixture devel/pcre2 \
    --root "$STAGE" \
    --output "$REPO_ROOT" \
    --pubkey "$REPO_PUB" \
    --swpkg "$ROOT/build/swpkg" \
    --pkgrepo "$ROOT/build/pkgrepo"

printf 'Built %s\n' "$PACKAGE"
printf 'Published signed repo fixture %s\n' "$REPO_ROOT/aarch64/current"
