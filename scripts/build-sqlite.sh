#!/usr/bin/env bash
# build-sqlite.sh - cross-build SQLite and publish a signed local package repo.
#
# Produces:
#   build/sqlite.swpkg
#   build/sqlite-repo-root/aarch64/current/catalog.signed
#   build/sqlite-repo-root.pub

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${SQLITE_VERSION:-3.53.2}"
DIST_VERSION="${SQLITE_DIST_VERSION:-3530200}"
DISTFILES="${SQLITE_DISTFILES:-$ROOT/build/swport-distfiles}"
WORK="$ROOT/build/sqlite-port-work"
SRC="$WORK/sqlite-autoconf-${DIST_VERSION}"
RUNTIME="$ROOT/build/sqlite-port-runtime"
STAGE="$ROOT/build/sqlite-root"
PACKAGE="$ROOT/build/sqlite.swpkg"
REPO_ROOT="$ROOT/build/sqlite-repo-root"
REPO_PUB="$ROOT/build/sqlite-repo-root.pub"
SYSROOT="${SQLITE_SYSROOT:-$ROOT/sysroot/aarch64-elf}"
COMPAT="$ROOT/userland/compat"
CC="${SQLITE_CC:-aarch64-elf-gcc}"
AR="${SQLITE_AR:-aarch64-elf-ar}"
RANLIB="${SQLITE_RANLIB:-aarch64-elf-ranlib}"
READELF="${SQLITE_READELF:-aarch64-elf-readelf}"
NM="${SQLITE_NM:-aarch64-elf-nm}"
STRIP="${SQLITE_STRIP:-aarch64-elf-strip}"

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

[[ "$VERSION" == "3.53.2" ]] || fail "unexpected sqlite version override: $VERSION"
[[ "$DIST_VERSION" == "3530200" ]] || fail "unexpected sqlite dist version override: $DIST_VERSION"
[[ -x "$ROOT/build/swport" ]] || fail "missing build/swport; run make swport"
[[ -x "$ROOT/build/swpkg" ]] || fail "missing build/swpkg; run make swpkg"
[[ -x "$ROOT/build/pkgrepo" ]] || fail "missing build/pkgrepo; run make pkgrepo"
[[ -f "$SYSROOT/lib/libc.a" ]] || fail "newlib sysroot missing. Run: make newlib"

mkdir -p "$DISTFILES" "$WORK" "$RUNTIME" "$ROOT/build"
"$ROOT/build/swport" recipe fetch databases/sqlite --cache "$DISTFILES"

rm -rf "$SRC"
tar xzf "$DISTFILES/sqlite-autoconf-${DIST_VERSION}.tar.gz" -C "$WORK"

inc_flags=(-isystem "$COMPAT" -isystem "$SYSROOT/include")
common_cflags=(-ffreestanding -Os "${inc_flags[@]}")
sqlite_cflags=(
    -D__minux
    -DSQLITE_THREADSAFE=0
    -DSQLITE_OMIT_LOAD_EXTENSION
    -DSQLITE_OMIT_SHARED_CACHE
    -DSQLITE_OMIT_WAL
    -DSQLITE_DEFAULT_MEMSTATUS=0
    -DSQLITE_TEMP_STORE=3
    -DSQLITE_DQS=0
    -DSQLITE_ENABLE_EXPLAIN_COMMENTS=0
)

"$CC" "${common_cflags[@]}" -c "$ROOT/userland/lib/crt0_newlib.S" \
    -o "$RUNTIME/crt0_newlib.o"
"$CC" "${common_cflags[@]}" -c "$ROOT/userland/lib/newlib_syscalls.c" \
    -o "$RUNTIME/newlib_syscalls.o"
"$CC" "${common_cflags[@]}" -c "$ROOT/userland/compat/stubs.c" \
    -o "$RUNTIME/compat_stubs.o"

"$CC" "${common_cflags[@]}" "${sqlite_cflags[@]}" -c "$SRC/sqlite3.c" \
    -o "$RUNTIME/sqlite3.o"
"$AR" rcs "$RUNTIME/libsqlite3.a" "$RUNTIME/sqlite3.o"
"$RANLIB" "$RUNTIME/libsqlite3.a"

"$CC" "${common_cflags[@]}" "${sqlite_cflags[@]}" \
    -static -nostartfiles -nostdlib -T "$ROOT/userland/user_newlib.ld" \
    -Wl,-z,max-page-size=4096 \
    "$RUNTIME/crt0_newlib.o" \
    "$RUNTIME/newlib_syscalls.o" \
    "$RUNTIME/compat_stubs.o" \
    "$SRC/shell.c" \
    "$RUNTIME/libsqlite3.a" \
    -L"$SYSROOT/lib" \
    -Wl,--start-group -lc -lm -lgcc -Wl,--end-group \
    -o "$RUNTIME/sqlite3"

undefined="$("$NM" -u "$RUNTIME/sqlite3")"
[[ -z "$undefined" ]] || fail "sqlite3 has undefined symbols: $undefined"
"$READELF" -h "$RUNTIME/sqlite3" | grep -q 'Machine:[[:space:]]*AArch64' ||
    fail "sqlite3 is not an AArch64 ELF"
"$STRIP" "$RUNTIME/sqlite3"

rm -rf "$STAGE" "$PACKAGE" "$REPO_ROOT" "$REPO_PUB"
mkdir -p "$STAGE/usr/bin" "$STAGE/usr/include" \
    "$STAGE/usr/lib/pkgconfig" "$STAGE/usr/share/sqlite"
cp "$RUNTIME/sqlite3" "$STAGE/usr/bin/sqlite3"
cp "$SRC/sqlite3.h" "$SRC/sqlite3ext.h" "$STAGE/usr/include/"
cp "$RUNTIME/libsqlite3.a" "$STAGE/usr/lib/libsqlite3.a"
cat >"$STAGE/usr/lib/pkgconfig/sqlite3.pc" <<EOF
prefix=/usr
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: SQLite
Description: SQL database engine
Version: ${VERSION}
Libs: -L\${libdir} -lsqlite3
Libs.private: -lm
Cflags: -I\${includedir}
EOF
printf 'sqlite %s swift-os static-shell\n' "$VERSION" \
    >"$STAGE/usr/share/sqlite/swiftos-sqlite.version"
chmod 0755 "$STAGE/usr/bin/sqlite3"
chmod 0644 "$STAGE/usr/include/sqlite3.h" "$STAGE/usr/include/sqlite3ext.h" \
    "$STAGE/usr/lib/libsqlite3.a" "$STAGE/usr/lib/pkgconfig/sqlite3.pc" \
    "$STAGE/usr/share/sqlite/swiftos-sqlite.version"

"$ROOT/build/swport" recipe package databases/sqlite \
    --root "$STAGE" \
    --output "$PACKAGE" \
    --swpkg "$ROOT/build/swpkg"

"$ROOT/build/swport" recipe repo-fixture databases/sqlite \
    --root "$STAGE" \
    --output "$REPO_ROOT" \
    --pubkey "$REPO_PUB" \
    --swpkg "$ROOT/build/swpkg" \
    --pkgrepo "$ROOT/build/pkgrepo"

# Content stamp so Makefile / CI refuse a root whose tree-owned runtime inputs
# moved (mtimes alone are unreliable after Actions cache restore).
"$ROOT/scripts/artifact-inputs-hash.sh" sqlite >"$ROOT/build/sqlite.inputs-hash"

printf 'Built %s\n' "$PACKAGE"
printf 'Published signed repo fixture %s\n' "$REPO_ROOT/aarch64/current"
printf 'inputs-hash %s\n' "$(cat "$ROOT/build/sqlite.inputs-hash")"
