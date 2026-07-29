#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# build-zsh.sh — cross-build zsh 5.9 for swift-os (milestone SH2).
#
# Produces build/zsh.elf (→ /bin/zsh): a static AArch64 zsh with built-in ZLE
# (line editor, history, completion), arrays, extended parameter expansion, and
# arithmetic. Job control is compiled in but limited — setpgid/tcsetpgrp are
# no-op stubs until the kernel signals follow-up lands.
#
# Depends on `make ncurses` having populated the sysroot (libncurses.a for ZLE).
# Uses the same swiftos-cc CC-wrapper pattern as build-bash.sh / build-mc.sh.
# zsh_cv_* variables override AC_TRY_RUN configure probes for cross-compilation.
# See docs/NOTES.md "SH2".

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/host-tools.sh
source "$ROOT/scripts/host-tools.sh"
VERSION="${ZSH_VERSION:-5.9}"
WORK="$ROOT/build/zsh-port-work"
SRC="$WORK/zsh-${VERSION}"
TARBALL="$WORK/zsh-${VERSION}.tar.xz"
# www.zsh.org/pub/ 404s for current releases; use the SourceForge mirror (curl
# follows the /download redirect). Override with ZSH_URL if a closer mirror exists.
URL="${ZSH_URL:-https://sourceforge.net/projects/zsh/files/zsh/${VERSION}/zsh-${VERSION}.tar.xz/download}"
RT="$ROOT/build/zsh-port-runtime"
SYSROOT="${ZSH_SYSROOT:-$ROOT/sysroot/aarch64-elf}"
COMPAT="$ROOT/userland/compat"
CC="${ZSH_CC:-aarch64-elf-gcc}"
NM="${ZSH_NM:-aarch64-elf-nm}"
READELF="${ZSH_READELF:-aarch64-elf-readelf}"
STRIP="${ZSH_STRIP:-aarch64-elf-strip}"
JOBS="${JOBS:-4}"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 2; }
require_exe() { command -v "$1" >/dev/null 2>&1 || fail "missing executable: $1"; }
require_exe "$CC"; require_exe make; require_exe tar
[[ -f "$SYSROOT/lib/libncurses.a" ]] || fail "libncurses.a missing. Run: make ncurses"

# Runtime objects (crt0 + newlib syscalls + compat stubs).
FEAT="-D_GNU_SOURCE -D_POSIX_THREADS -D_UNIX98_THREAD_MUTEX_ATTRIBUTES \
      -D_POSIX_READER_WRITER_LOCKS -D_POSIX_SEMAPHORES -D_POSIX_BARRIERS \
      -DSSIZE_MAX=__LONG_MAX__"
if [[ ! -f "$RT/stubs.o" ]]; then
    mkdir -p "$RT"
    $CC -ffreestanding -Os -isystem "$COMPAT" -isystem "$SYSROOT/include" \
        -c "$ROOT/userland/lib/crt0_newlib.S"     -o "$RT/crt0.o"
    $CC -ffreestanding -Os -isystem "$COMPAT" -isystem "$SYSROOT/include" \
        -c "$ROOT/userland/lib/newlib_syscalls.c" -o "$RT/sys.o"
    $CC -ffreestanding -std=gnu11 -Os $FEAT \
        -isystem "$COMPAT" -isystem "$SYSROOT/include" \
        -c "$ROOT/userland/compat/stubs.c"        -o "$RT/stubs.o"
fi

mkdir -p "$WORK"
[[ -f "$TARBALL" ]] || { echo "Fetching zsh ${VERSION}..."; curl -fsSL -o "$TARBALL" "$URL"; }
rm -rf "$SRC"
tar xf "$TARBALL" -C "$WORK"

# --- CC wrapper: compile flags + freestanding link group on every link -------
WRAP="$WORK/swiftos-cc"
cat >"$WRAP" <<EOF
#!/usr/bin/env bash
real_cc="$CC"
pre=(-ffreestanding -std=gnu11 -Os -Wno-error
     -D_GNU_SOURCE -D_POSIX_VERSION=200809L
     -D_POSIX_THREADS -D_UNIX98_THREAD_MUTEX_ATTRIBUTES
     -D_POSIX_READER_WRITER_LOCKS -D_POSIX_SEMAPHORES -D_POSIX_BARRIERS
     -DSSIZE_MAX=__LONG_MAX__
     -isystem "$COMPAT" -isystem "$SYSROOT/include"
     -I"$SYSROOT/include/ncurses"
     -L"$SYSROOT/lib")
link=(-static -nostartfiles -nostdlib -T "$ROOT/userland/user_newlib.ld"
      -Wl,-z,max-page-size=4096
      "$RT/crt0.o" "$RT/sys.o" "$RT/stubs.o"
      -Wl,--start-group -lc -lm -lgcc -lncurses -Wl,--end-group)
mode=link
for a in "\$@"; do case "\$a" in -c|-E|-S) mode=compile ;; esac; done
if [[ "\$mode" = compile ]]; then exec "\$real_cc" "\${pre[@]}" "\$@"; fi
exec "\$real_cc" "\${pre[@]}" "\$@" "\${link[@]}"
EOF
chmod +x "$WRAP"

# --- source patch: bake TERM + HOME + ZDOTDIR into Src/main.c ---------------
# Baked binaries run with an empty environment. Insert setenv() calls before
# the return-to-zsh_main line — a stable anchor in every zsh 5.x release.
# ZDOTDIR points to /tmp (writable tmpfs) so rc/history files go there.
perl -i -pe '
    if (/^\s+return\s*\(?\s*zsh_main\b/) {
        print "    setenv(\"TERM\",    \"vt100\", 0);  /* swift-os: bare-env default */\n";
        print "    setenv(\"HOME\",    \"/tmp\",  0);\n";
        print "    setenv(\"ZDOTDIR\", \"/tmp\",  0);\n";
    }
' "$SRC/Src/main.c"
grep -q 'swift-os: bare-env default' "$SRC/Src/main.c" \
    || fail "Src/main.c patch did not apply — 'return zsh_main' anchor not found"

# --- configure ---------------------------------------------------------------
# Only override probes that cannot be answered by compiling, or whose compile
# probe is known-wrong under freestanding newlib (see host-tools.sh principle).
(
    cd "$SRC"
    export CC="$WRAP" AR=aarch64-elf-ar RANLIB=aarch64-elf-ranlib
    export CFLAGS="" CPPFLAGS="" LDFLAGS="" LIBS=""

    # Data-model run-ifelse probes (AArch64 LP64: long/off_t/ino_t are 64-bit).
    export zsh_cv_c_have_union_init=yes
    export zsh_cv_c_variable_length_arrays=yes
    export zsh_cv_long_is_64_bit=yes
    export zsh_cv_off_t_is_64_bit=yes
    export zsh_cv_ino_t_is_64_bit=yes
    # TIOCGWINSZ is defined in our compat/termios.h; no need to check sys/ioctl.h.
    export zsh_cv_header_termios_h_tiocgwinsz=yes
    export zsh_cv_header_sys_ioctl_h_tiocgwinsz=no
    # Use ncurses for ZLE terminal operations (tgetent etc.).
    export zsh_cv_term_lib=ncurses
    # Compile probe mis-detects under cross CC: newlib's <sys/time.h> already
    # defines struct timezone; without this zsh redefines it and the build dies.
    export zsh_cv_type_exists_struct_timezone=yes
    # getrusage: leave to the link probe. userland/compat/sys/resource.h now
    # provides timeval-based struct rusage (was long[2], which broke zsh/bash).
    # Stub returns zeros; enough for configure + compile.
    # Also add _POSIX_VERSION so wait-status paths match bash (bare newlib
    # leaves it undefined outside RTEMS/Cygwin).

    # --host alone leaves cross_compiling=maybe; AC_PROG_CC then runs a.out and
    # hangs on same-arch Linux CI. See scripts/host-tools.sh autoconf_cross_*.
    autoconf_cross_prepare
    ./configure --host=aarch64-elf "$(autoconf_cross_build_arg)" --prefix=/usr \
        --disable-dynamic \
        --disable-multibyte \
        --disable-pcre \
        --disable-cap \
        --disable-gdbm \
        --with-term-lib=ncurses \
        --with-fndir=no \
        --with-site-fndir=no \
        --disable-dependency-tracking

    # Post-configure: force-disable modules that use network/system APIs beyond
    # what our stubs cover, or that clash with ncurses headers under GCC 14.
    # zsh/termcap redefines boolcodes/numcodes when the const-pointer link probe
    # fails (GCC 14 -Wincompatible-pointer-types); ZLE uses ncurses + terminfo.
    if [[ -f "$SRC/config.modules" ]]; then
        for mod in zsh/net/socket zsh/net/tcp zsh/langinfo zsh/system zsh/termcap; do
            if grep -q "^name=$mod " "$SRC/config.modules" 2>/dev/null; then
                # perl -i (not `sed -i`, whose -i needs a backup-suffix arg on
                # BSD/macOS sed) so the in-place edit is portable.
                perl -i -pe "s|^(name=\Q$mod\E ).*|\${1}link=no load=no|" "$SRC/config.modules"
            fi
        done
    fi

    make -j"$JOBS"
)

[[ -f "$SRC/Src/zsh" ]] || fail "zsh binary not built"
undefined="$("$NM" -u "$SRC/Src/zsh" 2>/dev/null)"
[[ -z "$undefined" ]] || fail "zsh has undefined symbols: $undefined"
"$READELF" -h "$SRC/Src/zsh" | grep -q 'Machine:[[:space:]]*AArch64' || fail "zsh is not an AArch64 ELF"
"$STRIP" "$SRC/Src/zsh" -o "$ROOT/build/zsh.elf"

# Content stamp so Makefile / CI refuse a binary whose tree-owned runtime
# inputs moved (mtimes alone are unreliable after Actions cache restore).
"$ROOT/scripts/artifact-inputs-hash.sh" zsh >"$ROOT/build/zsh.inputs-hash"

echo "Built $ROOT/build/zsh.elf (zsh ${VERSION}, --disable-dynamic --disable-multibyte, ZLE + ncurses)"
echo "inputs-hash $(cat "$ROOT/build/zsh.inputs-hash")"
"$READELF" -h "$ROOT/build/zsh.elf" | grep -E 'Type:|Entry|Size'
