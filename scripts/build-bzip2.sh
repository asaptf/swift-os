#!/usr/bin/env bash
# build-bzip2.sh - cross-build bzip2 and publish a signed local package repo.
#
# Produces:
#   build/bzip2.swpkg
#   build/bzip2-repo-root/aarch64/current/catalog.signed
#   build/bzip2-repo-root.pub

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${BZIP2_VERSION:-1.0.8}"
DISTFILES="${BZIP2_DISTFILES:-$ROOT/build/swport-distfiles}"
WORK="$ROOT/build/bzip2-port-work"
SRC="$WORK/bzip2-${VERSION}"
RUNTIME="$ROOT/build/bzip2-port-runtime"
STAGE="$ROOT/build/bzip2-root"
PACKAGE="$ROOT/build/bzip2.swpkg"
REPO_ROOT="$ROOT/build/bzip2-repo-root"
REPO_PUB="$ROOT/build/bzip2-repo-root.pub"
SYSROOT="${BZIP2_SYSROOT:-$ROOT/sysroot/aarch64-elf}"
COMPAT="$ROOT/userland/compat"
CC="${BZIP2_CC:-aarch64-elf-gcc}"
AR="${BZIP2_AR:-aarch64-elf-ar}"
RANLIB="${BZIP2_RANLIB:-aarch64-elf-ranlib}"
READELF="${BZIP2_READELF:-aarch64-elf-readelf}"
NM="${BZIP2_NM:-aarch64-elf-nm}"
STRIP="${BZIP2_STRIP:-aarch64-elf-strip}"
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
require_exe tar

[[ "$VERSION" == "1.0.8" ]] || fail "unexpected bzip2 version override: $VERSION"
[[ -x "$ROOT/build/swport" ]] || fail "missing build/swport; run make swport"
[[ -x "$ROOT/build/swpkg" ]] || fail "missing build/swpkg; run make swpkg"
[[ -x "$ROOT/build/pkgrepo" ]] || fail "missing build/pkgrepo; run make pkgrepo"
[[ -f "$SYSROOT/lib/libc.a" ]] || fail "newlib sysroot missing. Run: make newlib"

rm -rf "$RUNTIME"
mkdir -p "$DISTFILES" "$WORK" "$RUNTIME" "$ROOT/build"
"$ROOT/build/swport" recipe fetch archivers/bzip2 --cache "$DISTFILES"

rm -rf "$SRC"
tar xzf "$DISTFILES/bzip2-${VERSION}.tar.gz" -C "$WORK"

inc_flags=(-isystem "$COMPAT" -isystem "$SYSROOT/include")
runtime_cflags=(-ffreestanding -Os "${inc_flags[@]}")

"$CC" "${runtime_cflags[@]}" -c "$ROOT/userland/lib/crt0_newlib.S" \
    -o "$RUNTIME/crt0_newlib.o"
"$CC" "${runtime_cflags[@]}" -c "$ROOT/userland/lib/newlib_syscalls.c" \
    -o "$RUNTIME/newlib_syscalls.o"
cat >"$RUNTIME/swiftos_bzip2_compat.h" <<'EOF'
#include <sys/stat.h>
#include <sys/types.h>
#include <utime.h>

int fchmod(int fd, mode_t mode);
int fchown(int fd, uid_t owner, gid_t group);
int lstat(const char *path, struct stat *st);
int utime(const char *path, const struct utimbuf *times);
EOF
cat >"$RUNTIME/swiftos_bzip2_compat.c" <<'EOF'
#include <errno.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <utime.h>

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
"$CC" "${runtime_cflags[@]}" -include "$RUNTIME/swiftos_bzip2_compat.h" \
    -c "$RUNTIME/swiftos_bzip2_compat.c" \
    -o "$RUNTIME/swiftos_bzip2_compat.o"

common_cflags=(
    -ffreestanding
    -Os
    -Wall
    -include "$RUNTIME/swiftos_bzip2_compat.h"
    "${inc_flags[@]}"
)
lib_objects=(
    blocksort
    huffman
    crctable
    randtable
    compress
    decompress
    bzlib
)
for object in "${lib_objects[@]}"; do
    "$CC" "${common_cflags[@]}" -c "$SRC/$object.c" -o "$RUNTIME/$object.o"
done
lib_object_paths=()
for object in "${lib_objects[@]}"; do
    lib_object_paths+=("$RUNTIME/$object.o")
done
"$AR" rcs "$RUNTIME/libbz2.a" "${lib_object_paths[@]}"
"$RANLIB" "$RUNTIME/libbz2.a"

"$CC" "${common_cflags[@]}" -c "$SRC/bzip2.c" -o "$RUNTIME/bzip2.o"
"$CC" "${common_cflags[@]}" -c "$SRC/bzip2recover.c" -o "$RUNTIME/bzip2recover.o"

link_flags=(
    -static
    -nostartfiles
    -nostdlib
    -T "$ROOT/userland/user_newlib.ld"
    -Wl,-z,max-page-size=4096
    "$RUNTIME/crt0_newlib.o"
    "$RUNTIME/newlib_syscalls.o"
    "$RUNTIME/swiftos_bzip2_compat.o"
)
libs=(-L"$SYSROOT/lib" -Wl,--start-group -lc -lgcc -Wl,--end-group)
"$CC" "${common_cflags[@]}" "${link_flags[@]}" "$RUNTIME/bzip2.o" \
    "$RUNTIME/libbz2.a" "${libs[@]}" -o "$RUNTIME/bzip2"
"$CC" "${common_cflags[@]}" "${link_flags[@]}" "$RUNTIME/bzip2recover.o" \
    "${libs[@]}" -o "$RUNTIME/bzip2recover"

for exe in bzip2 bzip2recover; do
    undefined="$("$NM" -u "$RUNTIME/$exe")"
    [[ -z "$undefined" ]] || fail "$exe has undefined symbols: $undefined"
    "$READELF" -h "$RUNTIME/$exe" | grep -q 'Machine:[[:space:]]*AArch64' ||
        fail "$exe is not an AArch64 ELF"
    "$STRIP" "$RUNTIME/$exe"
done

rm -rf "$STAGE" "$PACKAGE" "$REPO_ROOT" "$REPO_PUB"
mkdir -p "$STAGE/usr/bin" "$STAGE/usr/include" \
    "$STAGE/usr/lib/pkgconfig" "$STAGE/usr/share/bzip2"
cp "$RUNTIME/bzip2" "$STAGE/usr/bin/bzip2"
cp "$RUNTIME/bzip2" "$STAGE/usr/bin/bunzip2"
cp "$RUNTIME/bzip2" "$STAGE/usr/bin/bzcat"
cp "$RUNTIME/bzip2recover" "$STAGE/usr/bin/bzip2recover"
cp "$SRC/bzlib.h" "$STAGE/usr/include/bzlib.h"
cp "$RUNTIME/libbz2.a" "$STAGE/usr/lib/libbz2.a"
cat >"$STAGE/usr/lib/pkgconfig/bzip2.pc" <<EOF
prefix=/usr
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: bzip2
Description: Lossless block-sorting data compression library
Version: ${VERSION}
Libs: -L\${libdir} -lbz2
Cflags: -I\${includedir}
EOF
printf 'bzip2 %s swift-os static-tools\n' "$VERSION" \
    >"$STAGE/usr/share/bzip2/swiftos-bzip2.version"
chmod 0755 "$STAGE/usr/bin/bzip2" "$STAGE/usr/bin/bunzip2" \
    "$STAGE/usr/bin/bzcat" "$STAGE/usr/bin/bzip2recover"
chmod 0644 "$STAGE/usr/include/bzlib.h" "$STAGE/usr/lib/libbz2.a" \
    "$STAGE/usr/lib/pkgconfig/bzip2.pc" \
    "$STAGE/usr/share/bzip2/swiftos-bzip2.version"

"$ROOT/build/swport" recipe package archivers/bzip2 \
    --root "$STAGE" \
    --output "$PACKAGE" \
    --swpkg "$ROOT/build/swpkg"

"$ROOT/build/swport" recipe repo-fixture archivers/bzip2 \
    --root "$STAGE" \
    --output "$REPO_ROOT" \
    --pubkey "$REPO_PUB" \
    --swpkg "$ROOT/build/swpkg" \
    --pkgrepo "$ROOT/build/pkgrepo"

printf 'Built %s\n' "$PACKAGE"
printf 'Published signed repo fixture %s\n' "$REPO_ROOT/aarch64/current"
