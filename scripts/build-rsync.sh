#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# build-rsync.sh - cross-build a static rsync CLI and publish a signed package repo.
#
# R1 scope: produce a static AArch64 rsync binary that runs `rsync --version`.
# Local-filesystem sync and rsync-over-TCP/ssh transport are follow-up packages.
#
# Produces:
#   build/rsync.swpkg
#   build/rsync-repo-root/aarch64/current/catalog.signed
#   build/rsync-repo-root.pub

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${RSYNC_VERSION:-3.4.1}"
DISTFILES="${RSYNC_DISTFILES:-$ROOT/build/swport-distfiles}"
WORK="$ROOT/build/rsync-port-work"
SRC="$WORK/rsync-${VERSION}"
RUNTIME="$ROOT/build/rsync-port-runtime"
STAGE="$ROOT/build/rsync-root"
PACKAGE="$ROOT/build/rsync.swpkg"
REPO_ROOT="$ROOT/build/rsync-repo-root"
REPO_PUB="$ROOT/build/rsync-repo-root.pub"
SYSROOT="${RSYNC_SYSROOT:-$ROOT/sysroot/aarch64-elf}"
COMPAT="$ROOT/userland/compat"
CC="${RSYNC_CC:-aarch64-elf-gcc}"
AR="${RSYNC_AR:-aarch64-elf-ar}"
RANLIB="${RSYNC_RANLIB:-aarch64-elf-ranlib}"
READELF="${RSYNC_READELF:-aarch64-elf-readelf}"
NM="${RSYNC_NM:-aarch64-elf-nm}"
STRIP="${RSYNC_STRIP:-aarch64-elf-strip}"
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

[[ "$VERSION" == "3.4.1" ]] || fail "unexpected rsync version override: $VERSION"
[[ -x "$ROOT/build/swport" ]] || fail "missing build/swport; run make swport"
[[ -x "$ROOT/build/swpkg" ]] || fail "missing build/swpkg; run make swpkg"
[[ -x "$ROOT/build/pkgrepo" ]] || fail "missing build/pkgrepo; run make pkgrepo"
[[ -f "$SYSROOT/lib/libc.a" ]] || fail "newlib sysroot missing. Run: make newlib"

rm -rf "$SRC" "$RUNTIME"
mkdir -p "$DISTFILES" "$WORK" "$RUNTIME" "$ROOT/build"
"$ROOT/build/swport" recipe fetch net/rsync --cache "$DISTFILES"
tar xzf "$DISTFILES/rsync-${VERSION}.tar.gz" -C "$WORK"

inc_flags=(-isystem "$COMPAT" -isystem "$SYSROOT/include")
runtime_cflags=(-ffreestanding -Os "${inc_flags[@]}")

"$CC" "${runtime_cflags[@]}" -c "$ROOT/userland/lib/crt0_newlib.S" \
    -o "$RUNTIME/crt0_newlib.o"
"$CC" "${runtime_cflags[@]}" -c "$ROOT/userland/lib/newlib_syscalls.c" \
    -o "$RUNTIME/newlib_syscalls.o"
"$CC" "${runtime_cflags[@]}" -c "$ROOT/userland/compat/stubs.c" \
    -o "$RUNTIME/compat_stubs.o"
# rsync-local openat() link shim (see userland/rsync/swiftos/at_compat.c).
"$CC" "${runtime_cflags[@]}" -c "$ROOT/userland/rsync/swiftos/at_compat.c" \
    -o "$RUNTIME/rsync_at_compat.o"

cc_wrapper="$RUNTIME/swiftos-cc"
cat >"$cc_wrapper" <<EOF
#!/usr/bin/env bash
real_cc="$CC"
root="$ROOT"
sysroot="$SYSROOT"
compat="$COMPAT"
runtime="$RUNTIME"
compile_flags=(-ffreestanding -Os -isystem "\$compat" -isystem "\$sysroot/include")
link_flags=(-static -nostartfiles -nostdlib -T "\$root/userland/user_newlib.ld" -Wl,-z,max-page-size=4096
            "\$runtime/crt0_newlib.o"
            "\$runtime/newlib_syscalls.o"
            "\$runtime/compat_stubs.o"
            "\$runtime/rsync_at_compat.o"
            -L"\$sysroot/lib"
            -Wl,--start-group -lc -lm -lgcc -Wl,--end-group)
mode=link
out=""
prev=""
for arg in "\$@"; do
    case "\$arg" in
        -c|-E|-S) mode=compile ;;
    esac
    if [[ "\$prev" = "-o" ]]; then out="\$arg"; fi
    prev="\$arg"
done
if [[ "\$mode" = compile ]]; then
    exec "\$real_cc" "\${compile_flags[@]}" "\$@"
fi
case "\$out" in
    *.la|*.lo|*.o) exec "\$real_cc" "\${compile_flags[@]}" "\$@" ;;
esac
exec "\$real_cc" "\${compile_flags[@]}" "\$@" "\${link_flags[@]}"
EOF
chmod +x "$cc_wrapper"

(
    cd "$SRC"
    export CC="$cc_wrapper" AR RANLIB
    export CFLAGS="-ffreestanding -Os"
    export CPPFLAGS="-isystem $COMPAT -isystem $SYSROOT/include"
    export LDFLAGS="-L$SYSROOT/lib"
    # Call configure.sh directly with an in-tree srcdir to bypass the upstream
    # ./configure stub's git-branch-based prep-auto-dir build-dir dance, which
    # assumes a git checkout (we build from an extracted tarball).
    ./configure.sh \
        --srcdir=. \
        --host=aarch64-elf \
        --build="$(./config.guess)" \
        --prefix=/usr \
        --with-included-popt \
        --with-included-zlib \
        --disable-openssl \
        --disable-xxhash \
        --disable-zstd \
        --disable-lz4 \
        --disable-md5-asm \
        --disable-roll-asm \
        --disable-roll-simd \
        --disable-acl-support \
        --disable-xattr-support \
        --disable-iconv \
        --disable-iconv-open \
        --disable-locale \
        --disable-ipv6 \
        --disable-md2man \
        --disable-debug \
        --with-nobody-user=nobody \
        --with-nobody-group=nogroup
    make -j"$JOBS"
)

undefined="$("$NM" -u "$SRC/rsync")"
[[ -z "$undefined" ]] || fail "rsync has undefined symbols: $undefined"
"$READELF" -h "$SRC/rsync" | grep -q 'Machine:[[:space:]]*AArch64' ||
    fail "rsync is not an AArch64 ELF"
"$STRIP" "$SRC/rsync"

rm -rf "$STAGE" "$PACKAGE" "$REPO_ROOT" "$REPO_PUB"
mkdir -p "$STAGE/usr/bin" "$STAGE/usr/share/rsync"
cp "$SRC/rsync" "$STAGE/usr/bin/rsync"
printf 'rsync %s swift-os static no-tls no-xattr no-acl\n' "$VERSION" \
    >"$STAGE/usr/share/rsync/swiftos-rsync.version"

chmod 0755 "$STAGE/usr/bin/rsync"
chmod 0644 "$STAGE/usr/share/rsync/swiftos-rsync.version"

"$ROOT/build/swport" recipe package net/rsync \
    --root "$STAGE" \
    --output "$PACKAGE" \
    --swpkg "$ROOT/build/swpkg"

"$ROOT/build/swport" recipe repo-fixture net/rsync \
    --root "$STAGE" \
    --output "$REPO_ROOT" \
    --pubkey "$REPO_PUB" \
    --swpkg "$ROOT/build/swpkg" \
    --pkgrepo "$ROOT/build/pkgrepo"

printf 'Built %s\n' "$PACKAGE"
printf 'Published signed repo fixture %s\n' "$REPO_ROOT/aarch64/current"
