#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# build-mc.sh — cross-build GNU Midnight Commander for swift-os (milestone MC1).
#
# Produces build/mc.elf (-> /bin/mc): the static MC file manager, ncurses screen
# backend, linked against the sysroot's libncurses.a (NC1) + libglib-2.0.a (GL1).
#
# Depends on `make ncurses` and `make glib` having populated the sysroot, plus
# build/zlib-root. Uses the same swiftos-cc CC-wrapper trick as build-nginx.sh
# (autotools link probes need the freestanding crt0/stubs + libc group appended
# on every link, which the wrapper guarantees regardless of how MC's macros
# rewrite LIBS). pkg-config is faked to answer only for glib (so ext2fs and other
# optional deps auto-disable). See docs/NOTES.md "MC1".

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/host-tools.sh
source "$ROOT/scripts/host-tools.sh"
VERSION="${MC_VERSION:-4.8.31}"
WORK="$ROOT/build/mc-port-work"
SRC="$WORK/mc-${VERSION}"
TARBALL="$WORK/mc-${VERSION}.tar.xz"
URL="${MC_URL:-http://ftp.midnight-commander.org/mc-${VERSION}.tar.xz}"
RT="$ROOT/build/glib-port-runtime"
SYSROOT="${MC_SYSROOT:-$ROOT/sysroot/aarch64-elf}"
ZLIBROOT="${MC_ZLIBROOT:-$ROOT/build/zlib-root/usr}"
COMPAT="$ROOT/userland/compat"
CC="${MC_CC:-aarch64-elf-gcc}"
NM="${MC_NM:-aarch64-elf-nm}"
READELF="${MC_READELF:-aarch64-elf-readelf}"
STRIP="${MC_STRIP:-aarch64-elf-strip}"
JOBS="${JOBS:-4}"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 2; }
require_exe() { command -v "$1" >/dev/null 2>&1 || fail "missing executable: $1"; }
require_exe "$CC"; require_exe make; require_exe tar; require_exe perl
[[ -f "$SYSROOT/lib/libncurses.a" ]] || fail "libncurses.a missing. Run: make ncurses"
[[ -f "$SYSROOT/lib/libglib-2.0.a" ]] || fail "libglib-2.0.a missing. Run: make glib"
[[ -f "$ZLIBROOT/lib/libz.a" ]] || fail "zlib missing. Run: scripts/build-zlib.sh"
# Runtime objects come from the glib build; rebuild if absent.
if [[ ! -f "$RT/stubs.o" ]]; then
    mkdir -p "$RT"
    FEAT0="-D_GNU_SOURCE -D_POSIX_THREADS -D_UNIX98_THREAD_MUTEX_ATTRIBUTES -D_POSIX_READER_WRITER_LOCKS -D_POSIX_SEMAPHORES -D_POSIX_BARRIERS -DSSIZE_MAX=__LONG_MAX__"
    $CC -ffreestanding -Os -isystem "$COMPAT" -isystem "$SYSROOT/include" -c "$ROOT/userland/lib/crt0_newlib.S"     -o "$RT/crt0.o"
    $CC -ffreestanding -Os -isystem "$COMPAT" -isystem "$SYSROOT/include" -c "$ROOT/userland/lib/newlib_syscalls.c" -o "$RT/sys.o"
    $CC -ffreestanding -std=gnu11 -Os $FEAT0 -isystem "$COMPAT" -isystem "$SYSROOT/include" -c "$ROOT/userland/compat/stubs.c" -o "$RT/stubs.o"
fi

mkdir -p "$WORK"
[[ -f "$TARBALL" ]] || { echo "Fetching mc ${VERSION}..."; curl -fsSL -o "$TARBALL" "$URL"; }
rm -rf "$SRC"
tar xf "$TARBALL" -C "$WORK"

# --- CC wrapper: freestanding compile + append runtime/libc group on link -----
WRAP="$WORK/swiftos-cc"
cat >"$WRAP" <<EOF
#!/usr/bin/env bash
real_cc="$CC"
pre=(-ffreestanding -std=gnu11 -Os -Wno-error
     -D_GNU_SOURCE -D_POSIX_THREADS -D_UNIX98_THREAD_MUTEX_ATTRIBUTES
     -D_POSIX_READER_WRITER_LOCKS -D_POSIX_SEMAPHORES -D_POSIX_BARRIERS -DSSIZE_MAX=__LONG_MAX__
     -isystem "$COMPAT" -isystem "$SYSROOT/include"
     -I"$SYSROOT/include/glib-2.0" -I"$SYSROOT/lib/glib-2.0/include" -I"$ZLIBROOT/include"
     -L"$SYSROOT/lib" -L"$ZLIBROOT/lib")
link=(-static -nostartfiles -nostdlib -T "$ROOT/userland/user_newlib.ld" -Wl,-z,max-page-size=4096
      "$RT/crt0.o" "$RT/sys.o" "$RT/stubs.o"
      -Wl,--start-group -lc -lm -lgcc -lz -Wl,--end-group)
mode=link
for a in "\$@"; do case "\$a" in -c|-E|-S) mode=compile ;; esac; done
if [[ "\$mode" = compile ]]; then exec "\$real_cc" "\${pre[@]}" "\$@"; fi
exec "\$real_cc" "\${pre[@]}" "\$@" "\${link[@]}"
EOF
chmod +x "$WRAP"

# --- fake pkg-config: answer only for glib, fail everything else --------------
PKGW="$WORK/fake-pkg-config"
cat >"$PKGW" <<EOF
#!/bin/sh
args="\$*"; glib=
for m in glib-2.0 gmodule-2.0 gmodule-no-export-2.0 gthread-2.0 gobject-2.0; do
  case " \$args " in *" \$m "*|*"\$m >"*|*"\$m>="*) glib=1;; esac
done
case "\$args" in
  *--version*) echo "0.29.2"; exit 0;;
  *--modversion*) [ -n "\$glib" ] && { echo "2.56.4"; exit 0; } || exit 1;;
  *--exists*|*--atleast-version*|*--max-version*) [ -n "\$glib" ] && exit 0 || exit 1;;
  *--cflags*) [ -n "\$glib" ] && echo "-I$SYSROOT/include/glib-2.0 -I$SYSROOT/lib/glib-2.0/include"; exit 0;;
  *--libs*) [ -n "\$glib" ] && echo "-L$SYSROOT/lib -lglib-2.0"; exit 0;;
  *--variable=*) echo ""; exit 0;;
  *) exit 1;;
esac
EOF
chmod +x "$PKGW"

# --- source patches (documented) ---------------------------------------------
# 1) Dialog drop-shadows need widec ncurses (cchar_t/getcchar); our NC1 ncurses
#    is 8-bit. Shadows are cosmetic — disable the unconditional define.
sed -i.bak -e 's|^#define ENABLE_SHADOWS 1|/* swift-os: dialog shadows need widec ncurses; disabled */|' \
    "$SRC/lib/tty/tty-ncurses.h" && rm -f "$SRC/lib/tty/tty-ncurses.h.bak"
# 2) Baked binaries inherit an empty environment (env does not yet propagate
#    through the login-exec path to the shell's children). Default TERM to
#    "linux" — the PC-text-console terminfo, which advertises 8 colours, so MC
#    emits colour SGR and the framebuffer console paints its blue skin; vt100
#    (the previous default) is monochrome. setenv overwrite=0 still respects an
#    inherited TERM once env propagation lands. HOME -> writable tmpfs (else
#    g_get_home_dir fails and MC cannot create its ~/.config/mc dir).
perl -0pi -e 's/(\n    GError \*mcerror = NULL;\n)/$1\n    setenv ("TERM", "linux", 0);  \/* swift-os: colour-capable default for a bare env *\/\n    setenv ("HOME", "\/tmp", 0);\n/' \
    "$SRC/src/main.c"

# --- configure (lean: ncurses, no subshell/x/vfs/editor/charset) -------------
(
    cd "$SRC"
    export CC="$WRAP" AR=aarch64-elf-ar RANLIB=aarch64-elf-ranlib
    export CFLAGS="" CPPFLAGS="" LDFLAGS="" LIBS=""
    export PKG_CONFIG="$PKGW"
    export GLIB_CFLAGS="-I$SYSROOT/include/glib-2.0 -I$SYSROOT/lib/glib-2.0/include" GLIB_LIBS="-L$SYSROOT/lib -lglib-2.0"
    export GMODULE_CFLAGS="$GLIB_CFLAGS" GMODULE_LIBS="-L$SYSROOT/lib -lglib-2.0"
    # --host alone leaves cross_compiling=maybe; AC_PROG_CC then runs a.out and
    # hangs on same-arch Linux CI. See scripts/host-tools.sh autoconf_cross_*.
    autoconf_cross_prepare
    ./configure --host=aarch64-elf "$(autoconf_cross_build_arg)" --prefix=/usr \
        --with-screen=ncurses --without-x --without-subshell --without-gpm-mouse \
        --disable-vfs --disable-nls --disable-charset \
        --without-internal-edit --disable-background --disable-tests \
        --disable-dependency-tracking
    make -j"$JOBS"
)

[[ -f "$SRC/src/mc" ]] || fail "mc binary not built"
undefined="$("$NM" -u "$SRC/src/mc")"
[[ -z "$undefined" ]] || fail "mc has undefined symbols: $undefined"
"$READELF" -h "$SRC/src/mc" | grep -q 'Machine:[[:space:]]*AArch64' || fail "mc is not an AArch64 ELF"
"$STRIP" "$SRC/src/mc" -o "$ROOT/build/mc.elf"

# Ship the standard blue skin (misc/skins/default.ini -> /usr/share/mc/skins).
# MC's compiled-in fallback skin is hardcoded black&white (lib/skin/ini-file.c
# mc_skin_hardcoded_blackwhite_colors), so colour requires the real skin file.
# The earlier NULL-deref crash was specific to a *monochrome* terminal; with a
# colour TERM (linux) at the login-exec path + an SGR-colour framebuffer console
# the parser takes the colour path. Installed as a stable build artifact so the
# base-image pack step (MC_PACK_CMD, gated by INCLUDE_MC) can find it.
mkdir -p "$ROOT/build/mc-skins"
cp "$SRC/misc/skins/default.ini" "$ROOT/build/mc-skins/default.ini"

# Content stamp so Makefile / CI refuse a binary whose tree-owned runtime
# inputs moved (mtimes alone are unreliable after Actions cache restore).
"$ROOT/scripts/artifact-inputs-hash.sh" mc >"$ROOT/build/mc.inputs-hash"

echo "Built $ROOT/build/mc.elf (mc ${VERSION}, ncurses + glib) + default skin"
echo "inputs-hash $(cat "$ROOT/build/mc.inputs-hash")"
"$READELF" -h "$ROOT/build/mc.elf" | grep -E 'Type:|Entry'
