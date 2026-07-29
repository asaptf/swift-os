#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# build-glib.sh — cross-build static GLib 2.56 core for swift-os (milestone GL1).
#
# Produces:
#   sysroot/aarch64-elf/lib/libglib-2.0.a            — static GLib core (for MC)
#   sysroot/aarch64-elf/include/glib-2.0/...         — GLib headers
#   sysroot/aarch64-elf/lib/glib-2.0/include/glibconfig.h
#   build/glibdemo.elf                               — proof-of-port (-> /bin/glibdemo)
#
# GLib 2.56 is the last clean autotools series; we build glib-core only (no
# gobject -> no libffi; no gio library; gmodule not needed). The cross-build
# mirrors build-pcre2.sh's env/cache-var pattern. Notable swift-os specifics
# (see docs/NOTES.md "GL1"):
#   - pkg-config is absent on the host: PKG_CHECK_MODULES is bypassed by setting
#     ZLIB_CFLAGS/LIBS and LIBFFI_CFLAGS/LIBS directly (libffi is never linked).
#   - newlib lacks iconv/gettext/nl_langinfo/resolver: provided as weak stubs in
#     userland/compat (stubs.c + libintl.h/utime.h/arpa/nameser.h/resolv.h).
#   - newlib gates pthread rwlock/barrier types behind feature macros and GCC 16
#     defaults to C23 (where 'bool' is a keyword): hence -std=gnu11 + the _POSIX_*
#     / _GNU_SOURCE defines, plus -DSSIZE_MAX (newlib omits it).
#   - zlib is consumed from build/zlib-root (run scripts/build-zlib.sh first).
#
# Requires: `make newlib` (sysroot), scripts/build-zlib.sh output, host
# aarch64-elf-gcc/binutils, network for the tarball.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/host-tools.sh
source "$ROOT/scripts/host-tools.sh"
VERSION="${GLIB_VERSION:-2.56.4}"
SERIES="${GLIB_SERIES:-2.56}"
WORK="$ROOT/build/glib-port-work"
SRC="$WORK/glib-${VERSION}"
TARBALL="$WORK/glib-${VERSION}.tar.xz"
URL="${GLIB_URL:-https://download.gnome.org/sources/glib/${SERIES}/glib-${VERSION}.tar.xz}"
RUNTIME="$ROOT/build/glib-port-runtime"
STAGE="$ROOT/build/glib-root"
SYSROOT="${GLIB_SYSROOT:-$ROOT/sysroot/aarch64-elf}"
ZLIBROOT="${GLIB_ZLIBROOT:-$ROOT/build/zlib-root/usr}"
COMPAT="$ROOT/userland/compat"
CC="${GLIB_CC:-aarch64-elf-gcc}"
AR="${GLIB_AR:-aarch64-elf-ar}"
RANLIB="${GLIB_RANLIB:-aarch64-elf-ranlib}"
READELF="${GLIB_READELF:-aarch64-elf-readelf}"
NM="${GLIB_NM:-aarch64-elf-nm}"
STRIP="${GLIB_STRIP:-aarch64-elf-strip}"
JOBS="${JOBS:-4}"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 2; }
require_exe() { command -v "$1" >/dev/null 2>&1 || fail "missing executable: $1"; }

require_exe "$CC"; require_exe "$AR"; require_exe "$RANLIB"
require_exe "$READELF"; require_exe "$NM"; require_exe "$STRIP"
require_exe make; require_exe tar
[[ -f "$SYSROOT/lib/libc.a" ]] || fail "newlib sysroot missing. Run: make newlib"
[[ -f "$ZLIBROOT/lib/libz.a" ]] || fail "zlib missing. Run: scripts/build-zlib.sh (build/zlib-root)"

# Feature defines: enable newlib's pthread rwlock/barrier types, force gnu11
# (GCC 16 defaults to C23 where GLib 2.56's `bool` identifier is illegal), and
# supply SSIZE_MAX (newlib omits it; giochannel needs it).
FEAT="-D_GNU_SOURCE -D_POSIX_THREADS -D_UNIX98_THREAD_MUTEX_ATTRIBUTES -D_POSIX_READER_WRITER_LOCKS -D_POSIX_SEMAPHORES -D_POSIX_BARRIERS -DSSIZE_MAX=__LONG_MAX__"
INCS="-isystem $COMPAT -isystem $SYSROOT/include -I$ZLIBROOT/include"

mkdir -p "$WORK" "$RUNTIME" "$ROOT/build"
[[ -f "$TARBALL" ]] || { echo "Fetching glib ${VERSION}..."; curl -fsSL -o "$TARBALL" "$URL"; }
rm -rf "$SRC"
tar xf "$TARBALL" -C "$WORK"

# --- runtime objects ---------------------------------------------------------
$CC -ffreestanding -Os -isystem "$COMPAT" -isystem "$SYSROOT/include" -c "$ROOT/userland/lib/crt0_newlib.S"     -o "$RUNTIME/crt0.o"
$CC -ffreestanding -Os -isystem "$COMPAT" -isystem "$SYSROOT/include" -c "$ROOT/userland/lib/newlib_syscalls.c" -o "$RUNTIME/sys.o"
$CC -ffreestanding -std=gnu11 -Os $FEAT -isystem "$COMPAT" -isystem "$SYSROOT/include" -c "$ROOT/userland/compat/stubs.c" -o "$RUNTIME/stubs.o"

# --- configure ---------------------------------------------------------------
# LDFLAGS for configure's link probes include the runtime objects; the library
# `make` overrides LDFLAGS (libtool rejects raw .o in a convenience-lib build).
(
    cd "$SRC"
    export CC AR RANLIB
    export CFLAGS="-ffreestanding -std=gnu11 -Os $FEAT $INCS"
    export CPPFLAGS="$FEAT $INCS"
    export LDFLAGS="-static -nostartfiles -nostdlib -T $ROOT/userland/user_newlib.ld -Wl,-z,max-page-size=4096 $RUNTIME/crt0.o $RUNTIME/sys.o $RUNTIME/stubs.o -L$SYSROOT/lib -L$ZLIBROOT/lib"
    export LIBS="-Wl,--start-group -lc -lm -lgcc -Wl,--end-group"
    export ZLIB_CFLAGS="-I$ZLIBROOT/include" ZLIB_LIBS="-L$ZLIBROOT/lib -lz"
    export LIBFFI_CFLAGS=" " LIBFFI_LIBS="-lffi"   # satisfies PKG_CHECK_MODULES; gobject/libffi never built
    export PKG_CONFIG=true
    # cross compile-AND-run probe answers for the swift-os target
    export glib_cv_stack_grows=no glib_cv_uscore=no glib_cv_va_copy=yes glib_cv___va_copy=yes \
        glib_cv_va_val_copy=yes glib_cv_rtldglobal_broken=no glib_cv_long_long_format=ll \
        ac_cv_func_posix_getpwuid_r=no ac_cv_func_posix_getgrgid_r=no \
        ac_cv_func_printf_unix98=yes glib_cv_have_qsort_r=no \
        gt_cv_func_gnugettext1_libc=yes gt_cv_func_gnugettext2_libc=yes
    # --host alone leaves cross_compiling=maybe; AC_PROG_CC then runs a.out and
    # hangs on same-arch Linux CI. See scripts/host-tools.sh autoconf_cross_*.
    autoconf_cross_prepare
    ./configure \
        --host=aarch64-elf "$(autoconf_cross_build_arg)" --prefix=/usr \
        --disable-shared --enable-static \
        --with-pcre=internal --disable-libmount --disable-selinux \
        --disable-dtrace --disable-systemtap --disable-fam --disable-xattr \
        --with-threads=posix --disable-dependency-tracking --disable-installed-tests

    # --- build glib core (libtool-friendly LDFLAGS: no raw .o) ---------------
    LT="-static -L$SYSROOT/lib -L$ZLIBROOT/lib"
    BCFLAGS="-ffreestanding -std=gnu11 -Os $FEAT $INCS"
    for d in libcharset gnulib pcre; do
        [[ -d "glib/$d" ]] && make -C "glib/$d" -j"$JOBS" LDFLAGS="$LT" LIBS=""
    done
    make -C glib -j"$JOBS" libglib-2.0.la CFLAGS="$BCFLAGS" LDFLAGS="$LT" LIBS=""

    # --- install headers; copy lib + glibconfig.h ---------------------------
    rm -rf "$STAGE"
    make -C glib install-data DESTDIR="$STAGE"
)

[[ -f "$SRC/glib/.libs/libglib-2.0.a" ]] || fail "libglib-2.0.a not built"
cp -a "$STAGE/usr/include/glib-2.0" "$SYSROOT/include/glib-2.0"
mkdir -p "$SYSROOT/lib/glib-2.0/include"
cp "$SRC/glib/glibconfig.h" "$SYSROOT/lib/glib-2.0/include/glibconfig.h"
cp "$SRC/glib/.libs/libglib-2.0.a" "$SYSROOT/lib/libglib-2.0.a"
"$RANLIB" "$SYSROOT/lib/libglib-2.0.a"

# --- proof-of-port demo ------------------------------------------------------
$CC -ffreestanding -std=gnu11 -Os $FEAT \
    -isystem "$COMPAT" -isystem "$SYSROOT/include" \
    -I"$SYSROOT/include/glib-2.0" -I"$SYSROOT/lib/glib-2.0/include" \
    -static -nostartfiles -nostdlib -T "$ROOT/userland/user_newlib.ld" -Wl,-z,max-page-size=4096 \
    "$RUNTIME/crt0.o" "$RUNTIME/sys.o" "$RUNTIME/stubs.o" \
    "$ROOT/userland/glib/glibdemo.c" "$SYSROOT/lib/libglib-2.0.a" \
    -L"$SYSROOT/lib" -L"$ZLIBROOT/lib" \
    -Wl,--start-group -lc -lm -lgcc -lz -Wl,--end-group \
    -o "$ROOT/build/glibdemo.elf"

undefined="$("$NM" -u "$ROOT/build/glibdemo.elf")"
[[ -z "$undefined" ]] || fail "glibdemo.elf has undefined symbols: $undefined"
"$READELF" -h "$ROOT/build/glibdemo.elf" | grep -q 'Machine:[[:space:]]*AArch64' ||
    fail "glibdemo.elf is not an AArch64 ELF"
"$STRIP" "$ROOT/build/glibdemo.elf"

# Content stamp so Makefile / CI refuse a binary whose tree-owned runtime
# inputs moved (mtimes alone are unreliable after Actions cache restore).
"$ROOT/scripts/artifact-inputs-hash.sh" glib >"$ROOT/build/glib.inputs-hash"

echo "Built $ROOT/build/glibdemo.elf"
echo "Installed $SYSROOT/lib/libglib-2.0.a + headers (glib ${VERSION})"
echo "inputs-hash $(cat "$ROOT/build/glib.inputs-hash")"
"$READELF" -h "$ROOT/build/glibdemo.elf" | grep -E 'Type:|Entry'
