#!/usr/bin/env bash
# build-openssl.sh - cross-build OpenSSL and publish a signed package repo.
#
# Produces:
#   build/openssl.swpkg
#   build/openssl-repo-root/aarch64/current/catalog.signed
#   build/openssl-repo-root.pub

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${OPENSSL_VERSION:-3.5.7}"
DISTFILES="${OPENSSL_DISTFILES:-$ROOT/build/swport-distfiles}"
WORK="$ROOT/build/openssl-port-work"
SRC="$WORK/openssl-${VERSION}"
RUNTIME="$ROOT/build/openssl-port-runtime"
STAGE="$ROOT/build/openssl-root"
PACKAGE="$ROOT/build/openssl.swpkg"
REPO_ROOT="$ROOT/build/openssl-repo-root"
REPO_PUB="$ROOT/build/openssl-repo-root.pub"
SYSROOT="${OPENSSL_SYSROOT:-$ROOT/sysroot/aarch64-elf}"
COMPAT="$ROOT/userland/compat"
CC="${OPENSSL_CC:-aarch64-elf-gcc}"
AR="${OPENSSL_AR:-aarch64-elf-ar}"
RANLIB="${OPENSSL_RANLIB:-aarch64-elf-ranlib}"
READELF="${OPENSSL_READELF:-aarch64-elf-readelf}"
NM="${OPENSSL_NM:-aarch64-elf-nm}"
STRIP="${OPENSSL_STRIP:-aarch64-elf-strip}"
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
require_exe perl
require_exe tar

[[ "$VERSION" == "3.5.7" ]] || fail "unexpected openssl version override: $VERSION"
[[ -x "$ROOT/build/swport" ]] || fail "missing build/swport; run make swport"
[[ -x "$ROOT/build/swpkg" ]] || fail "missing build/swpkg; run make swpkg"
[[ -x "$ROOT/build/pkgrepo" ]] || fail "missing build/pkgrepo; run make pkgrepo"
[[ -f "$SYSROOT/lib/libc.a" ]] || fail "newlib sysroot missing. Run: make newlib"

rm -rf "$RUNTIME"
mkdir -p "$DISTFILES" "$WORK" "$RUNTIME" "$ROOT/build"
"$ROOT/build/swport" recipe fetch security/openssl --cache "$DISTFILES"

rm -rf "$SRC"
tar xzf "$DISTFILES/openssl-${VERSION}.tar.gz" -C "$WORK"

inc_flags=(-isystem "$COMPAT" -isystem "$SYSROOT/include")
runtime_cflags=(-ffreestanding -Os "${inc_flags[@]}")

"$CC" "${runtime_cflags[@]}" -c "$ROOT/userland/lib/crt0_newlib.S" \
    -o "$RUNTIME/crt0_newlib.o"
"$CC" "${runtime_cflags[@]}" -c "$ROOT/userland/lib/newlib_syscalls.c" \
    -o "$RUNTIME/newlib_syscalls.o"
"$CC" "${runtime_cflags[@]}" -c "$ROOT/userland/compat/stubs.c" \
    -o "$RUNTIME/compat_stubs.o"

openssl_ldflags="-static -nostartfiles -nostdlib -T $ROOT/userland/user_newlib.ld -Wl,-z,max-page-size=4096 $RUNTIME/crt0_newlib.o $RUNTIME/newlib_syscalls.o $RUNTIME/compat_stubs.o -L$SYSROOT/lib"
openssl_libs="-Wl,--start-group -lc -lgcc -Wl,--end-group"

(
    cd "$SRC"
    export CC AR RANLIB
    export CFLAGS="-ffreestanding -Os -isystem $COMPAT -isystem $SYSROOT/include"
    export LDFLAGS="$openssl_ldflags"
    export LDLIBS="$openssl_libs"
    ./Configure BSD-generic64 \
        --prefix=/usr \
        --openssldir=/usr/etc/ssl \
        --libdir=lib \
        no-shared \
        no-dso \
        no-module \
        no-threads \
        no-async \
        no-engine \
        no-tests \
        no-docs \
        no-asm \
        no-makedepend \
        no-secure-memory \
        no-afalgeng \
        no-devcryptoeng
    make -j"$JOBS" build_sw
)

undefined="$("$NM" -u "$SRC/apps/openssl")"
[[ -z "$undefined" ]] || fail "openssl has undefined symbols: $undefined"
"$READELF" -h "$SRC/apps/openssl" | grep -q 'Machine:[[:space:]]*AArch64' ||
    fail "openssl is not an AArch64 ELF"
"$STRIP" "$SRC/apps/openssl"

rm -rf "$STAGE" "$PACKAGE" "$REPO_ROOT" "$REPO_PUB"
mkdir -p "$STAGE/usr/bin" "$STAGE/usr/share/openssl"
cp "$SRC/apps/openssl" "$STAGE/usr/bin/openssl"
printf 'openssl 3.5.7 swift-os static-no-dso-no-modules\n' \
    >"$STAGE/usr/share/openssl/swiftos-openssl.version"

chmod 0755 "$STAGE/usr/bin/openssl"
chmod 0644 "$STAGE/usr/share/openssl/swiftos-openssl.version"

"$ROOT/build/swport" recipe package security/openssl \
    --root "$STAGE" \
    --output "$PACKAGE" \
    --swpkg "$ROOT/build/swpkg"

"$ROOT/build/swport" recipe repo-fixture security/openssl \
    --root "$STAGE" \
    --output "$REPO_ROOT" \
    --pubkey "$REPO_PUB" \
    --swpkg "$ROOT/build/swpkg" \
    --pkgrepo "$ROOT/build/pkgrepo"

printf 'Built %s\n' "$PACKAGE"
printf 'Published signed repo fixture %s\n' "$REPO_ROOT/aarch64/current"
