#!/usr/bin/env bash
# build-xz.sh - cross-build XZ Utils and publish a signed local package repo.
#
# Produces:
#   build/xz.swpkg
#   build/xz-repo-root/aarch64/current/catalog.signed
#   build/xz-repo-root.pub

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/host-tools.sh
source "$ROOT/scripts/host-tools.sh"
VERSION="${XZ_VERSION:-5.8.3}"
DISTFILES="${XZ_DISTFILES:-$ROOT/build/swport-distfiles}"
WORK="$ROOT/build/xz-port-work"
SRC="$WORK/xz-${VERSION}"
RUNTIME="$ROOT/build/xz-port-runtime"
STAGE="$ROOT/build/xz-root"
PACKAGE="$ROOT/build/xz.swpkg"
REPO_ROOT="$ROOT/build/xz-repo-root"
REPO_PUB="$ROOT/build/xz-repo-root.pub"
SYSROOT="${XZ_SYSROOT:-$ROOT/sysroot/aarch64-elf}"
COMPAT="$ROOT/userland/compat"
CC="${XZ_CC:-aarch64-elf-gcc}"
AR="${XZ_AR:-aarch64-elf-ar}"
RANLIB="${XZ_RANLIB:-aarch64-elf-ranlib}"
READELF="${XZ_READELF:-aarch64-elf-readelf}"
NM="${XZ_NM:-aarch64-elf-nm}"
STRIP="${XZ_STRIP:-aarch64-elf-strip}"
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

[[ "$VERSION" == "5.8.3" ]] || fail "unexpected xz version override: $VERSION"
[[ -x "$ROOT/build/swport" ]] || fail "missing build/swport; run make swport"
[[ -x "$ROOT/build/swpkg" ]] || fail "missing build/swpkg; run make swpkg"
[[ -x "$ROOT/build/pkgrepo" ]] || fail "missing build/pkgrepo; run make pkgrepo"
[[ -f "$SYSROOT/lib/libc.a" ]] || fail "newlib sysroot missing. Run: make newlib"

rm -rf "$RUNTIME"
mkdir -p "$DISTFILES" "$WORK" "$RUNTIME" "$ROOT/build"
"$ROOT/build/swport" recipe fetch archivers/xz --cache "$DISTFILES"

rm -rf "$SRC"
tar xzf "$DISTFILES/xz-${VERSION}.tar.gz" -C "$WORK"

inc_flags=(-isystem "$COMPAT" -isystem "$SYSROOT/include")
runtime_cflags=(-ffreestanding -Os "${inc_flags[@]}")

"$CC" "${runtime_cflags[@]}" -c "$ROOT/userland/lib/crt0_newlib.S" \
    -o "$RUNTIME/crt0_newlib.o"
"$CC" "${runtime_cflags[@]}" -c "$ROOT/userland/lib/newlib_syscalls.c" \
    -o "$RUNTIME/newlib_syscalls.o"
"$CC" "${runtime_cflags[@]}" -c "$ROOT/userland/compat/stubs.c" \
    -o "$RUNTIME/compat_stubs.o"
cat >"$RUNTIME/swiftos_xz_compat.h" <<'EOF'
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <utime.h>

unsigned int alarm(unsigned int seconds);
char *dirname(char *path);
int fchmod(int fd, mode_t mode);
int fchown(int fd, uid_t owner, gid_t group);
int lstat(const char *path, struct stat *st);
int utime(const char *path, const struct utimbuf *times);
EOF
cat >"$RUNTIME/swiftos_xz_compat.c" <<'EOF'
#include <errno.h>
#include <stddef.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <utime.h>

unsigned int alarm(unsigned int seconds) {
    (void)seconds;
    return 0;
}

char *dirname(char *path) {
    static char dot[] = ".";
    static char slash[] = "/";
    if (!path || path[0] == '\0') {
        return dot;
    }

    char *last = NULL;
    for (char *p = path; *p; ++p) {
        if (*p == '/') {
            last = p;
        }
    }
    if (!last) {
        return dot;
    }

    while (last > path && *last == '/') {
        --last;
    }
    if (last == path && *last == '/') {
        path[1] = '\0';
        return slash;
    }

    char *end = last;
    while (end > path && *end != '/') {
        --end;
    }
    if (end == path && *end != '/') {
        return dot;
    }
    while (end > path && *end == '/') {
        --end;
    }
    end[1] = '\0';
    return path;
}

int fchmod(int fd, mode_t mode) {
    (void)fd;
    (void)mode;
    return 0;
}

int fchown(int fd, uid_t owner, gid_t group) {
    (void)fd;
    (void)owner;
    (void)group;
    errno = EPERM;
    return -1;
}

int lstat(const char *path, struct stat *st) {
    return stat(path, st);
}

int utime(const char *path, const struct utimbuf *times) {
    (void)path;
    (void)times;
    return 0;
}
EOF
"$CC" "${runtime_cflags[@]}" -include "$RUNTIME/swiftos_xz_compat.h" \
    -c "$RUNTIME/swiftos_xz_compat.c" \
    -o "$RUNTIME/swiftos_xz_compat.o"

configure_ldflags="-static -nostartfiles -nostdlib -T $ROOT/userland/user_newlib.ld -Wl,-z,max-page-size=4096 $RUNTIME/crt0_newlib.o $RUNTIME/newlib_syscalls.o $RUNTIME/compat_stubs.o $RUNTIME/swiftos_xz_compat.o -L$SYSROOT/lib"
libtool_ldflags="-static -L$SYSROOT/lib"
libs="-lc -lgcc"

(
    cd "$SRC"
    export CC AR RANLIB
    export CFLAGS="-ffreestanding -Os -include $RUNTIME/swiftos_xz_compat.h -isystem $COMPAT -isystem $SYSROOT/include"
    export CPPFLAGS="-D_FORTIFY_SOURCE=0"
    export LDFLAGS="$configure_ldflags"
    export LIBS="$libs"
    # Disable optional APIs that are missing or stub-only under freestanding
    # newlib (honest "no", not fabricated "yes"). getrlimit exists as a weak
    # stub but xz expects real limits; vasprintf/wcwidth are not provided.
    export ac_cv_func_getrlimit=no
    export ac_cv_func_vasprintf=no
    export ac_cv_func_wcwidth=no
    # --host alone leaves cross_compiling=maybe; AC_PROG_CC then runs a.out and
    # hangs on same-arch Linux CI. See scripts/host-tools.sh autoconf_cross_*.
    autoconf_cross_prepare
    ./configure \
        --host=aarch64-elf \
        "$(autoconf_cross_build_arg)" \
        --prefix=/usr \
        --disable-shared \
        --enable-static \
        --disable-nls \
        --disable-scripts \
        --disable-doc \
        --disable-xzdec \
        --disable-lzmadec \
        --disable-lzmainfo \
        --disable-lzma-links \
        --disable-sandbox \
        --disable-assembler \
        --disable-clmul-crc \
        --disable-arm64-crc32 \
        --disable-symbol-versions \
        --enable-threads=no \
        --disable-dependency-tracking \
        --enable-small \
        --enable-assume-ram=128
    make -C src/liblzma -j"$JOBS" \
        LDFLAGS="$libtool_ldflags" \
        LIBS=""
    make -C src/xz -j"$JOBS" \
        LDFLAGS="$configure_ldflags" \
        LIBS="$libs"
)

undefined="$("$NM" -u "$SRC/src/xz/xz")"
[[ -z "$undefined" ]] || fail "xz has undefined symbols: $undefined"
"$READELF" -h "$SRC/src/xz/xz" | grep -q 'Machine:[[:space:]]*AArch64' ||
    fail "xz is not an AArch64 ELF"
"$STRIP" "$SRC/src/xz/xz"

rm -rf "$STAGE" "$PACKAGE" "$REPO_ROOT" "$REPO_PUB"
mkdir -p "$STAGE/usr/bin" "$STAGE/usr/include/lzma" \
    "$STAGE/usr/lib/pkgconfig" "$STAGE/usr/share/xz"
cp "$SRC/src/xz/xz" "$STAGE/usr/bin/xz"
cp "$SRC/src/xz/xz" "$STAGE/usr/bin/unxz"
cp "$SRC/src/xz/xz" "$STAGE/usr/bin/xzcat"
cp "$SRC/src/liblzma/api/lzma.h" "$STAGE/usr/include/lzma.h"
cp "$SRC/src/liblzma/api/lzma/"*.h "$STAGE/usr/include/lzma/"
cp "$SRC/src/liblzma/.libs/liblzma.a" "$STAGE/usr/lib/liblzma.a"
cp "$SRC/src/liblzma/liblzma.pc" "$STAGE/usr/lib/pkgconfig/liblzma.pc"
printf 'xz %s swift-os static-small-no-threads\n' "$VERSION" \
    >"$STAGE/usr/share/xz/swiftos-xz.version"
chmod 0755 "$STAGE/usr/bin/xz" "$STAGE/usr/bin/unxz" "$STAGE/usr/bin/xzcat"
chmod 0644 "$STAGE/usr/include/lzma.h" "$STAGE/usr/include/lzma/"*.h \
    "$STAGE/usr/lib/liblzma.a" "$STAGE/usr/lib/pkgconfig/liblzma.pc" \
    "$STAGE/usr/share/xz/swiftos-xz.version"

"$ROOT/build/swport" recipe package archivers/xz \
    --root "$STAGE" \
    --output "$PACKAGE" \
    --swpkg "$ROOT/build/swpkg"

"$ROOT/build/swport" recipe repo-fixture archivers/xz \
    --root "$STAGE" \
    --output "$REPO_ROOT" \
    --pubkey "$REPO_PUB" \
    --swpkg "$ROOT/build/swpkg" \
    --pkgrepo "$ROOT/build/pkgrepo"

printf 'Built %s\n' "$PACKAGE"
printf 'Published signed repo fixture %s\n' "$REPO_ROOT/aarch64/current"
