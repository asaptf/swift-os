#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# build-bash.sh — cross-build GNU bash 5.2 for swift-os (milestone SH1).
#
# Produces build/bash.elf (→ /bin/bash): a static AArch64 bash with bundled
# readline + ncurses for line-editing, history, and completion. Job control is
# disabled (no SIGTSTP/SIGCONT/setpgid kernel support yet); all other
# interactive features work: command history, tab-completion, pipelines, here
# documents, arrays, arithmetic, pattern matching.
#
# Depends on `make ncurses` having populated the sysroot (libncurses.a).
# Uses the same swiftos-cc CC-wrapper trick as build-mc.sh: every link gets
# the freestanding crt0/stubs + libc group appended, regardless of how
# bash's autoconf macros rewrite LIBS. bash_cv_* variables override all
# AC_TRY_RUN tests that cannot execute during cross-compilation.
# See docs/NOTES.md "SH1".

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# NB: do not read $BASH_VERSION here — that is a bash builtin variable, which the
# shell running this script sets to its own version (e.g. macOS host bash
# 3.2.57), shadowing the intended default and breaking the fetch URL. Use a
# dedicated override name instead.
VERSION="${BASH_PORT_VERSION:-5.2.37}"
WORK="$ROOT/build/bash-port-work"
SRC="$WORK/bash-${VERSION}"
TARBALL="$WORK/bash-${VERSION}.tar.gz"
URL="${BASH_URL:-https://ftp.gnu.org/gnu/bash/bash-${VERSION}.tar.gz}"
RT="$ROOT/build/bash-port-runtime"
SYSROOT="${BASH_SYSROOT:-$ROOT/sysroot/aarch64-elf}"
COMPAT="$ROOT/userland/compat"
CC="${BASH_CC:-aarch64-elf-gcc}"
NM="${BASH_NM:-aarch64-elf-nm}"
READELF="${BASH_READELF:-aarch64-elf-readelf}"
STRIP="${BASH_STRIP:-aarch64-elf-strip}"
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
[[ -f "$TARBALL" ]] || { echo "Fetching bash ${VERSION}..."; curl -fsSL -o "$TARBALL" "$URL"; }
rm -rf "$SRC"
tar xf "$TARBALL" -C "$WORK"

# --- CC wrapper: compile flags + freestanding link group on every link -------
WRAP="$WORK/swiftos-cc"
cat >"$WRAP" <<EOF
#!/usr/bin/env bash
real_cc="$CC"
pre=(-ffreestanding -std=gnu11 -Os -Wno-error
     -D_GNU_SOURCE -D_POSIX_THREADS -D_UNIX98_THREAD_MUTEX_ATTRIBUTES
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

# --- source patch: bake TERM + HOME defaults into main() --------------------
# Baked binaries run with an empty environment. Without TERM, readline's
# setupterm() receives NULL and ncurses returns ERR (bash falls back to a dumb
# terminal). Without HOME, bash cannot write ~/.bash_history. Insert setenv()
# calls before set_default_locale(), which is the first call bash makes in
# main() — a stable anchor across all 5.x releases.
perl -i -pe '
    if (/^\s+set_default_locale\s*\(\s*\)\s*;/) {
        print "  setenv (\"TERM\", \"vt100\", 0);  /* swift-os: bare-env default */\n";
        print "  setenv (\"HOME\", \"/tmp\",  0);\n";
    }
' "$SRC/shell.c"
grep -q 'swift-os: bare-env default' "$SRC/shell.c" \
    || fail "shell.c patch did not apply — set_default_locale anchor not found"

# --- configure (cross-compile with bash_cv_ overrides for all TRY_RUN tests) -
(
    cd "$SRC"
    export CC="$WRAP" AR=aarch64-elf-ar RANLIB=aarch64-elf-ranlib
    export CFLAGS="" CPPFLAGS="" LDFLAGS="" LIBS=""

    # Override all AC_TRY_RUN tests that cannot run on the host when cross-compiling.
    # Values chosen for a static freestanding newlib target.
    export bash_cv_func_sigsetjmp=present
    export bash_cv_have_mbstate_t=yes
    export bash_cv_func_strcoll_works=yes
    export bash_cv_func_ctype_nonascii=no
    export bash_cv_wcwidth_broken=no
    export bash_cv_func_printf_a_format=yes
    export bash_cv_sys_named_pipes=absent      # no /dev/fd or /proc/self/fd
    export bash_cv_job_control_missing=present # consistent with --without-job-control
    export bash_cv_opendir_not_robust=no
    export bash_cv_getenv_redef=no
    export bash_cv_must_reinstall_sighandlers=no
    export bash_cv_func_setvbuf_reversed=no
    export bash_cv_ulimit_maxfds=no
    export bash_cv_type_rlimit=yes
    export bash_cv_decl_ioctl=yes
    export bash_cv_func_lstat_dereferences_slashed_symlink=yes
    export bash_cv_terminfo_lib=ncurses
    export bash_cv_dup2_broken=no
    export bash_cv_pgrp_pipe=no
    export bash_cv_unusable_rtsigs=yes         # no RT signal delivery
    export bash_cv_func_sbrk=no
    export bash_cv_dev_stdin=absent
    export bash_cv_dev_fd=absent

    ./configure --host=aarch64-elf --prefix=/usr \
        --with-included-readline \
        --with-curses \
        --without-job-control \
        --without-bash-malloc \
        --disable-nls \
        --disable-rpath \
        --without-gdbm \
        --without-libintl-prefix \
        --without-libiconv-prefix \
        --disable-dependency-tracking

    make -j"$JOBS"
)

[[ -f "$SRC/bash" ]] || fail "bash binary not built"
undefined="$("$NM" -u "$SRC/bash" 2>/dev/null)"
[[ -z "$undefined" ]] || fail "bash has undefined symbols: $undefined"
"$READELF" -h "$SRC/bash" | grep -q 'Machine:[[:space:]]*AArch64' || fail "bash is not an AArch64 ELF"
"$STRIP" "$SRC/bash" -o "$ROOT/build/bash.elf"

# Content stamp so Makefile / CI refuse a binary whose tree-owned runtime
# inputs moved (mtimes alone are unreliable after Actions cache restore).
"$ROOT/scripts/artifact-inputs-hash.sh" bash >"$ROOT/build/bash.inputs-hash"

echo "Built $ROOT/build/bash.elf (bash ${VERSION}, --without-job-control, bundled readline + ncurses)"
echo "inputs-hash $(cat "$ROOT/build/bash.inputs-hash")"
"$READELF" -h "$ROOT/build/bash.elf" | grep -E 'Type:|Entry|Size'
