#!/usr/bin/env bash
# build-lua.sh - cross-build Lua and publish a signed local package repository.
#
# Produces:
#   build/lua.swpkg
#   build/lua-repo-root/aarch64/current/catalog.signed
#   build/lua-repo-root.pub
#
# Requires: `make newlib` first (sysroot), aarch64-elf-gcc/binutils, and
# build/swport + build/swpkg + build/pkgrepo.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${LUA_VERSION:-5.4.8}"
DISTFILES="${LUA_DISTFILES:-$ROOT/build/swport-distfiles}"
WORK="$ROOT/build/lua-port-work"
SRC="$WORK/lua-${VERSION}"
RUNTIME="$ROOT/build/lua-port-runtime"
STAGE="$ROOT/build/lua-root"
PACKAGE="$ROOT/build/lua.swpkg"
REPO_ROOT="$ROOT/build/lua-repo-root"
REPO_PUB="$ROOT/build/lua-repo-root.pub"
SYSROOT="${LUA_SYSROOT:-$ROOT/sysroot/aarch64-elf}"
COMPAT="$ROOT/userland/compat"
CC="${LUA_CC:-aarch64-elf-gcc}"
AR="${LUA_AR:-aarch64-elf-ar}"
RANLIB="${LUA_RANLIB:-aarch64-elf-ranlib}"
READELF="${LUA_READELF:-aarch64-elf-readelf}"
NM="${LUA_NM:-aarch64-elf-nm}"
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
require_exe make
require_exe tar

[[ -x "$ROOT/build/swport" ]] || fail "missing build/swport; run make swport"
[[ -x "$ROOT/build/swpkg" ]] || fail "missing build/swpkg; run make swpkg"
[[ -x "$ROOT/build/pkgrepo" ]] || fail "missing build/pkgrepo; run make pkgrepo"
[[ -f "$SYSROOT/lib/libc.a" ]] || fail "newlib sysroot missing. Run: make newlib"

mkdir -p "$DISTFILES" "$WORK" "$RUNTIME" "$ROOT/build"
"$ROOT/build/swport" recipe fetch lang/lua --cache "$DISTFILES"

rm -rf "$SRC"
tar xzf "$DISTFILES/lua-${VERSION}.tar.gz" -C "$WORK"

inc_flags=(-isystem "$COMPAT" -isystem "$SYSROOT/include")
runtime_cflags=(-ffreestanding -Os "${inc_flags[@]}")

"$CC" "${runtime_cflags[@]}" -c "$ROOT/userland/lib/crt0_newlib.S" \
    -o "$RUNTIME/crt0_newlib.o"
"$CC" "${runtime_cflags[@]}" -c "$ROOT/userland/lib/newlib_syscalls.c" \
    -o "$RUNTIME/newlib_syscalls.o"

make -C "$SRC/src" clean >/dev/null
make -C "$SRC/src" -j"$JOBS" generic \
    CC="$CC -std=gnu99" \
    AR="$AR rcu" \
    RANLIB="$RANLIB" \
    MYCFLAGS="-ffreestanding -Os -isystem $COMPAT -isystem $SYSROOT/include -DLUA_USE_C89" \
    MYLDFLAGS="-static -nostartfiles -nostdlib -T $ROOT/userland/user_newlib.ld -Wl,-z,max-page-size=4096 $RUNTIME/crt0_newlib.o $RUNTIME/newlib_syscalls.o -L$SYSROOT/lib" \
    MYLIBS="-Wl,--start-group -lc -lm -lgcc -Wl,--end-group"

for bin in lua luac; do
    undefined="$("$NM" -u "$SRC/src/$bin")"
    [[ -z "$undefined" ]] || fail "$bin has undefined symbols: $undefined"
    "$READELF" -h "$SRC/src/$bin" | grep -q 'Machine:[[:space:]]*AArch64' ||
        fail "$bin is not an AArch64 ELF"
done

rm -rf "$STAGE" "$PACKAGE" "$REPO_ROOT" "$REPO_PUB"
mkdir -p "$STAGE/usr/bin"
cp "$SRC/src/lua" "$STAGE/usr/bin/lua"
cp "$SRC/src/luac" "$STAGE/usr/bin/luac"
chmod 0755 "$STAGE/usr/bin/lua" "$STAGE/usr/bin/luac"

"$ROOT/build/swport" recipe package lang/lua \
    --root "$STAGE" \
    --output "$PACKAGE" \
    --swpkg "$ROOT/build/swpkg"

"$ROOT/build/swport" recipe repo-fixture lang/lua \
    --root "$STAGE" \
    --output "$REPO_ROOT" \
    --pubkey "$REPO_PUB" \
    --swpkg "$ROOT/build/swpkg" \
    --pkgrepo "$ROOT/build/pkgrepo"

printf 'Built %s\n' "$PACKAGE"
printf 'Published signed repo fixture %s\n' "$REPO_ROOT/aarch64/current"
