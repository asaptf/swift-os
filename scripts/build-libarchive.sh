#!/usr/bin/env bash
# build-libarchive.sh - cross-build libarchive/bsdtar and publish a signed repo.
#
# Produces:
#   build/libarchive.swpkg
#   build/libarchive-repo-root/aarch64/current/catalog.signed
#   build/libarchive-repo-root.pub

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/host-tools.sh
source "$ROOT/scripts/host-tools.sh"
VERSION="${LIBARCHIVE_VERSION:-3.8.7}"
DISTFILES="${LIBARCHIVE_DISTFILES:-$ROOT/build/swport-distfiles}"
WORK="$ROOT/build/libarchive-port-work"
SRC="$WORK/libarchive-${VERSION}"
RUNTIME="$ROOT/build/libarchive-port-runtime"
STAGE="$ROOT/build/libarchive-root"
PACKAGE="$ROOT/build/libarchive.swpkg"
REPO_ROOT="$ROOT/build/libarchive-repo-root"
REPO_PUB="$ROOT/build/libarchive-repo-root.pub"
SYSROOT="${LIBARCHIVE_SYSROOT:-$ROOT/sysroot/aarch64-elf}"
COMPAT="$ROOT/userland/compat"
CC="${LIBARCHIVE_CC:-aarch64-elf-gcc}"
AR="${LIBARCHIVE_AR:-aarch64-elf-ar}"
RANLIB="${LIBARCHIVE_RANLIB:-aarch64-elf-ranlib}"
READELF="${LIBARCHIVE_READELF:-aarch64-elf-readelf}"
NM="${LIBARCHIVE_NM:-aarch64-elf-nm}"
STRIP="${LIBARCHIVE_STRIP:-aarch64-elf-strip}"
JOBS="${JOBS:-4}"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 2
}

require_exe() {
    command -v "$1" >/dev/null 2>&1 || fail "missing executable: $1"
}

require_dep_root() {
    local path="$1"
    [[ -e "$path" ]] || fail "missing dependency artifact: $path. Run the dependency port targets first."
}

require_exe "$CC"
require_exe "$AR"
require_exe "$RANLIB"
require_exe "$READELF"
require_exe "$NM"
require_exe "$STRIP"
require_exe make
require_exe tar

[[ "$VERSION" == "3.8.7" ]] || fail "unexpected libarchive version override: $VERSION"
[[ -x "$ROOT/build/swport" ]] || fail "missing build/swport; run make swport"
[[ -x "$ROOT/build/swpkg" ]] || fail "missing build/swpkg; run make swpkg"
[[ -x "$ROOT/build/pkgrepo" ]] || fail "missing build/pkgrepo; run make pkgrepo"
[[ -f "$SYSROOT/lib/libc.a" ]] || fail "newlib sysroot missing. Run: make newlib"
require_dep_root "$ROOT/build/zlib-root/usr/lib/libz.a"
require_dep_root "$ROOT/build/bzip2-root/usr/lib/libbz2.a"
require_dep_root "$ROOT/build/zstd-root/usr/lib/libzstd.a"
require_dep_root "$ROOT/build/xz-root/usr/lib/liblzma.a"

rm -rf "$RUNTIME"
mkdir -p "$DISTFILES" "$WORK" "$RUNTIME" "$ROOT/build"
"$ROOT/build/swport" recipe fetch archivers/libarchive --cache "$DISTFILES"

rm -rf "$SRC"
tar xJf "$DISTFILES/libarchive-${VERSION}.tar.xz" -C "$WORK"

inc_flags=(-isystem "$COMPAT" -isystem "$SYSROOT/include")
runtime_cflags=(-ffreestanding -Os "${inc_flags[@]}")

"$CC" "${runtime_cflags[@]}" -c "$ROOT/userland/lib/crt0_newlib.S" \
    -o "$RUNTIME/crt0_newlib.o"
"$CC" "${runtime_cflags[@]}" -c "$ROOT/userland/lib/newlib_syscalls.c" \
    -o "$RUNTIME/newlib_syscalls.o"
"$CC" "${runtime_cflags[@]}" -c "$ROOT/userland/compat/stubs.c" \
    -o "$RUNTIME/compat_stubs.o"
cat >"$RUNTIME/swiftos_libarchive_compat.h" <<'EOF'
#include <unistd.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>
#include <utime.h>

int chflags(const char *path, unsigned long flags);
int fchdir(int fd);
int fchflags(int fd, unsigned long flags);
int lchflags(const char *path, unsigned long flags);
int lchmod(const char *path, mode_t mode);
int lutimes(const char *path, const struct timeval times[2]);
long pathconf(const char *path, int name);
int utime(const char *path, const struct utimbuf *times);
int __archive_create_child(const char *cmd, int *child_stdin, int *child_stdout, pid_t *out_child);
void __archive_check_child(int in, int out);
EOF
cat >"$RUNTIME/swiftos_libarchive_compat.c" <<'EOF'
#include <errno.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>
#include <utime.h>

int chflags(const char *path, unsigned long flags) {
    (void)path;
    (void)flags;
    return 0;
}

int fchdir(int fd) {
    (void)fd;
    return 0;
}

int fchflags(int fd, unsigned long flags) {
    (void)fd;
    (void)flags;
    return 0;
}

int lchflags(const char *path, unsigned long flags) {
    (void)path;
    (void)flags;
    return 0;
}

int lchmod(const char *path, mode_t mode) {
    return chmod(path, mode);
}

int lutimes(const char *path, const struct timeval times[2]) {
    (void)path;
    (void)times;
    return 0;
}

long pathconf(const char *path, int name) {
    (void)path;
    (void)name;
    errno = EINVAL;
    return -1;
}

int utime(const char *path, const struct utimbuf *times) {
    (void)path;
    (void)times;
    return 0;
}

int __archive_create_child(const char *cmd, int *child_stdin, int *child_stdout, pid_t *out_child) {
    (void)cmd;
    if (child_stdin) { *child_stdin = -1; }
    if (child_stdout) { *child_stdout = -1; }
    if (out_child) { *out_child = -1; }
    errno = ENOSYS;
    return -30;
}

void __archive_check_child(int in, int out) {
    (void)in;
    (void)out;
}
EOF
"$CC" "${runtime_cflags[@]}" -include "$RUNTIME/swiftos_libarchive_compat.h" \
    -c "$RUNTIME/swiftos_libarchive_compat.c" \
    -o "$RUNTIME/swiftos_libarchive_compat.o"

dep_cppflags="-I$ROOT/build/zlib-root/usr/include -I$ROOT/build/bzip2-root/usr/include -I$ROOT/build/zstd-root/usr/include -I$ROOT/build/xz-root/usr/include"
dep_ldflags="-L$ROOT/build/zlib-root/usr/lib -L$ROOT/build/bzip2-root/usr/lib -L$ROOT/build/zstd-root/usr/lib -L$ROOT/build/xz-root/usr/lib"
configure_ldflags="-static -nostartfiles -nostdlib -T $ROOT/userland/user_newlib.ld -Wl,-z,max-page-size=4096 $RUNTIME/crt0_newlib.o $RUNTIME/newlib_syscalls.o $RUNTIME/compat_stubs.o $RUNTIME/swiftos_libarchive_compat.o -L$SYSROOT/lib $dep_ldflags"
libtool_ldflags="-static -L$SYSROOT/lib $dep_ldflags"
libs="-Wl,--start-group -lzstd -llzma -lbz2 -lz -lc -lgcc -Wl,--end-group"

(
    cd "$SRC"
    export CC AR RANLIB
    export CFLAGS="-ffreestanding -Os -include $RUNTIME/swiftos_libarchive_compat.h -isystem $COMPAT -isystem $SYSROOT/include"
    export CPPFLAGS="-D_FORTIFY_SOURCE=0 $dep_cppflags"
    export LDFLAGS="$configure_ldflags"
    export LIBS="$libs"
    # pthread: freestanding port builds single-threaded; header presence would
    # pull optional code we do not want. fchdir: symbol exists (compat stub);
    # leave presence=yes so configure links, runtime is ENOSYS until real fchdir.
    export ac_cv_header_pthread_h=no
    export ac_cv_func_fchdir=yes
    # --host alone leaves cross_compiling=maybe; AC_PROG_CC then runs a.out and
    # hangs on same-arch Linux CI. See scripts/host-tools.sh autoconf_cross_*.
    autoconf_cross_prepare
    ./configure \
        --host=aarch64-elf \
        "$(autoconf_cross_build_arg)" \
        --prefix=/usr \
        --disable-shared \
        --enable-static \
        --enable-bsdtar=static \
        --disable-bsdcat \
        --disable-bsdcpio \
        --disable-bsdunzip \
        --disable-dependency-tracking \
        --disable-acl \
        --disable-xattr \
        --without-iconv \
        --without-lz4 \
        --without-lzo2 \
        --without-libb2 \
        --without-openssl \
        --without-xml2 \
        --without-expat \
        --disable-posix-regex-lib
    make -j"$JOBS" libarchive.la libarchive_fe.la \
        LDFLAGS="$libtool_ldflags" \
        LIBS=""
    make -j"$JOBS" bsdtar \
        LDFLAGS="$configure_ldflags" \
        LIBS="$libs"
)

undefined="$("$NM" -u "$SRC/bsdtar")"
[[ -z "$undefined" ]] || fail "bsdtar has undefined symbols: $undefined"
"$READELF" -h "$SRC/bsdtar" | grep -q 'Machine:[[:space:]]*AArch64' ||
    fail "bsdtar is not an AArch64 ELF"
"$STRIP" "$SRC/bsdtar"

rm -rf "$STAGE" "$PACKAGE" "$REPO_ROOT" "$REPO_PUB"
mkdir -p "$STAGE/usr/bin" "$STAGE/usr/include" \
    "$STAGE/usr/lib/pkgconfig" "$STAGE/usr/share/libarchive"
cp "$SRC/bsdtar" "$STAGE/usr/bin/bsdtar"
cp "$SRC/libarchive/archive.h" "$SRC/libarchive/archive_entry.h" \
    "$STAGE/usr/include/"
cp "$SRC/.libs/libarchive.a" "$STAGE/usr/lib/libarchive.a"
cat >"$STAGE/usr/lib/pkgconfig/libarchive.pc" <<EOF
prefix=/usr
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: libarchive
Description: library that can create and read streaming archive formats
Version: ${VERSION}
Cflags: -I\${includedir}
Cflags.private: -DLIBARCHIVE_STATIC
Libs: -L\${libdir} -larchive
Libs.private: -lzstd -llzma -lbz2 -lz
EOF
printf 'libarchive %s swift-os static-bsdtar-no-external-programs\n' "$VERSION" \
    >"$STAGE/usr/share/libarchive/swiftos-libarchive.version"
chmod 0755 "$STAGE/usr/bin/bsdtar"
chmod 0644 "$STAGE/usr/include/archive.h" "$STAGE/usr/include/archive_entry.h" \
    "$STAGE/usr/lib/libarchive.a" "$STAGE/usr/lib/pkgconfig/libarchive.pc" \
    "$STAGE/usr/share/libarchive/swiftos-libarchive.version"

"$ROOT/build/swport" recipe package archivers/libarchive \
    --root "$STAGE" \
    --output "$PACKAGE" \
    --swpkg "$ROOT/build/swpkg"

"$ROOT/build/swport" recipe repo-fixture archivers/libarchive \
    --root "$STAGE" \
    --output "$REPO_ROOT" \
    --pubkey "$REPO_PUB" \
    --swpkg "$ROOT/build/swpkg" \
    --pkgrepo "$ROOT/build/pkgrepo"

printf 'Built %s\n' "$PACKAGE"
printf 'Published signed repo fixture %s\n' "$REPO_ROOT/aarch64/current"
