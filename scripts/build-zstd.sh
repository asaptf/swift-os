#!/usr/bin/env bash
# build-zstd.sh - cross-build zstd and publish a signed local package repo.
#
# Produces:
#   build/zstd.swpkg
#   build/zstd-repo-root/aarch64/current/catalog.signed
#   build/zstd-repo-root.pub

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${ZSTD_VERSION:-1.5.7}"
DISTFILES="${ZSTD_DISTFILES:-$ROOT/build/swport-distfiles}"
WORK="$ROOT/build/zstd-port-work"
SRC="$WORK/zstd-${VERSION}"
RUNTIME="$ROOT/build/zstd-port-runtime"
STAGE="$ROOT/build/zstd-root"
PACKAGE="$ROOT/build/zstd.swpkg"
REPO_ROOT="$ROOT/build/zstd-repo-root"
REPO_PUB="$ROOT/build/zstd-repo-root.pub"
SYSROOT="${ZSTD_SYSROOT:-$ROOT/sysroot/aarch64-elf}"
COMPAT="$ROOT/userland/compat"
CC="${ZSTD_CC:-aarch64-elf-gcc}"
AR="${ZSTD_AR:-aarch64-elf-ar}"
RANLIB="${ZSTD_RANLIB:-aarch64-elf-ranlib}"
READELF="${ZSTD_READELF:-aarch64-elf-readelf}"
NM="${ZSTD_NM:-aarch64-elf-nm}"
STRIP="${ZSTD_STRIP:-aarch64-elf-strip}"
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

[[ "$VERSION" == "1.5.7" ]] || fail "unexpected zstd version override: $VERSION"
[[ -x "$ROOT/build/swport" ]] || fail "missing build/swport; run make swport"
[[ -x "$ROOT/build/swpkg" ]] || fail "missing build/swpkg; run make swpkg"
[[ -x "$ROOT/build/pkgrepo" ]] || fail "missing build/pkgrepo; run make pkgrepo"
[[ -f "$SYSROOT/lib/libc.a" ]] || fail "newlib sysroot missing. Run: make newlib"

rm -rf "$RUNTIME"
mkdir -p "$DISTFILES" "$WORK" "$RUNTIME" "$ROOT/build"
"$ROOT/build/swport" recipe fetch archivers/zstd --cache "$DISTFILES"

rm -rf "$SRC"
tar xzf "$DISTFILES/zstd-${VERSION}.tar.gz" -C "$WORK"

inc_flags=(-isystem "$COMPAT" -isystem "$SYSROOT/include")
runtime_cflags=(-ffreestanding -Os "${inc_flags[@]}")

"$CC" "${runtime_cflags[@]}" -c "$ROOT/userland/lib/crt0_newlib.S" \
    -o "$RUNTIME/crt0_newlib.o"
"$CC" "${runtime_cflags[@]}" -c "$ROOT/userland/lib/newlib_syscalls.c" \
    -o "$RUNTIME/newlib_syscalls.o"
"$CC" "${runtime_cflags[@]}" -c "$ROOT/userland/compat/stubs.c" \
    -o "$RUNTIME/compat_stubs.o"
cat >"$RUNTIME/swiftos_zstd_compat.h" <<'EOF'
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <utime.h>

#ifndef TIME_UTC
#define TIME_UTC 1
#endif

int timespec_get(struct timespec *ts, int base);
int utime(const char *path, const struct utimbuf *times);
EOF
cat >"$RUNTIME/swiftos_zstd_compat.c" <<'EOF'
#include <sys/types.h>
#include <time.h>
#include <utime.h>

#ifndef TIME_UTC
#define TIME_UTC 1
#endif

int timespec_get(struct timespec *ts, int base) {
    if (!ts || base != TIME_UTC) {
        return 0;
    }
    ts->tv_sec = time(NULL);
    ts->tv_nsec = 0;
    return base;
}

int utime(const char *path, const struct utimbuf *times) {
    (void)path;
    (void)times;
    return 0;
}
EOF
"$CC" "${runtime_cflags[@]}" -include "$RUNTIME/swiftos_zstd_compat.h" \
    -c "$RUNTIME/swiftos_zstd_compat.c" \
    -o "$RUNTIME/swiftos_zstd_compat.o"

common_cflags="-ffreestanding -Os -isystem $COMPAT -isystem $SYSROOT/include"
common_cppflags="-include $RUNTIME/swiftos_zstd_compat.h -DPLATFORM_POSIX_VERSION=1 -DZSTD_NO_ASM=1"
link_flags="-static -nostartfiles -nostdlib -T $ROOT/userland/user_newlib.ld -Wl,-z,max-page-size=4096 $RUNTIME/crt0_newlib.o $RUNTIME/newlib_syscalls.o $RUNTIME/compat_stubs.o $RUNTIME/swiftos_zstd_compat.o -L$SYSROOT/lib"
link_libs="-Wl,--start-group -lc -lgcc -Wl,--end-group"

(
    cd "$SRC"
    export CC AR RANLIB
    make -C lib -j"$JOBS" libzstd.a \
        CC="$CC" \
        AR="$AR" \
        RANLIB="$RANLIB" \
        CFLAGS="$common_cflags" \
        CPPFLAGS="$common_cppflags" \
        ZSTD_LEGACY_SUPPORT=0 \
        ZSTD_NO_ASM=1
    make -C programs -j"$JOBS" zstd \
        CC="$CC" \
        AR="$AR" \
        RANLIB="$RANLIB" \
        CFLAGS="$common_cflags" \
        CPPFLAGS="$common_cppflags" \
        LDFLAGS="$link_flags" \
        LDLIBS="$link_libs" \
        ZSTD_LEGACY_SUPPORT=0 \
        ZSTD_NO_ASM=1 \
        HAVE_THREAD=0 \
        HAVE_PTHREAD=0 \
        HAVE_ZLIB=0 \
        HAVE_LZMA=0 \
        HAVE_LZ4=0 \
        BACKTRACE=0
)

undefined="$("$NM" -u "$SRC/programs/zstd")"
[[ -z "$undefined" ]] || fail "zstd has undefined symbols: $undefined"
"$READELF" -h "$SRC/programs/zstd" | grep -q 'Machine:[[:space:]]*AArch64' ||
    fail "zstd is not an AArch64 ELF"
"$STRIP" "$SRC/programs/zstd"

rm -rf "$STAGE" "$PACKAGE" "$REPO_ROOT" "$REPO_PUB"
mkdir -p "$STAGE/usr/bin" "$STAGE/usr/include" \
    "$STAGE/usr/lib/pkgconfig" "$STAGE/usr/share/zstd"
cp "$SRC/programs/zstd" "$STAGE/usr/bin/zstd"
cp "$SRC/programs/zstd" "$STAGE/usr/bin/unzstd"
cp "$SRC/programs/zstd" "$STAGE/usr/bin/zstdcat"
cp "$SRC/lib/zstd.h" "$SRC/lib/zstd_errors.h" "$SRC/lib/zdict.h" \
    "$STAGE/usr/include/"
cp "$SRC/lib/libzstd.a" "$STAGE/usr/lib/libzstd.a"
cat >"$STAGE/usr/lib/pkgconfig/libzstd.pc" <<EOF
prefix=/usr
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: zstd
Description: fast lossless compression algorithm library
Version: ${VERSION}
Libs: -L\${libdir} -lzstd
Cflags: -I\${includedir}
EOF
printf 'zstd %s swift-os static-single-thread\n' "$VERSION" \
    >"$STAGE/usr/share/zstd/swiftos-zstd.version"
chmod 0755 "$STAGE/usr/bin/zstd" "$STAGE/usr/bin/unzstd" \
    "$STAGE/usr/bin/zstdcat"
chmod 0644 "$STAGE/usr/include/zstd.h" "$STAGE/usr/include/zstd_errors.h" \
    "$STAGE/usr/include/zdict.h" "$STAGE/usr/lib/libzstd.a" \
    "$STAGE/usr/lib/pkgconfig/libzstd.pc" \
    "$STAGE/usr/share/zstd/swiftos-zstd.version"

"$ROOT/build/swport" recipe package archivers/zstd \
    --root "$STAGE" \
    --output "$PACKAGE" \
    --swpkg "$ROOT/build/swpkg"

"$ROOT/build/swport" recipe repo-fixture archivers/zstd \
    --root "$STAGE" \
    --output "$REPO_ROOT" \
    --pubkey "$REPO_PUB" \
    --swpkg "$ROOT/build/swpkg" \
    --pkgrepo "$ROOT/build/pkgrepo"

printf 'Built %s\n' "$PACKAGE"
printf 'Published signed repo fixture %s\n' "$REPO_ROOT/aarch64/current"
