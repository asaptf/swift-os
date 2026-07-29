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
# shellcheck source=scripts/host-tools.sh
source "$ROOT/scripts/host-tools.sh"
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

# Runtime objects (crt0 + newlib syscalls + compat stubs). Always rebuild
# stubs.o so mkfifo and other recent stubs land in the configure link set.
FEAT="-D_GNU_SOURCE -D_POSIX_THREADS -D_UNIX98_THREAD_MUTEX_ATTRIBUTES \
      -D_POSIX_READER_WRITER_LOCKS -D_POSIX_SEMAPHORES -D_POSIX_BARRIERS \
      -DSSIZE_MAX=__LONG_MAX__"
mkdir -p "$RT"
$CC -ffreestanding -Os -isystem "$COMPAT" -isystem "$SYSROOT/include" \
    -c "$ROOT/userland/lib/crt0_newlib.S"     -o "$RT/crt0.o"
$CC -ffreestanding -Os -isystem "$COMPAT" -isystem "$SYSROOT/include" \
    -c "$ROOT/userland/lib/newlib_syscalls.c" -o "$RT/sys.o"
$CC -ffreestanding -std=gnu11 -Os $FEAT \
    -isystem "$COMPAT" -isystem "$SYSROOT/include" \
    -c "$ROOT/userland/compat/stubs.c"        -o "$RT/stubs.o"

mkdir -p "$WORK"
[[ -f "$TARBALL" ]] || { echo "Fetching bash ${VERSION}..."; curl -fsSL -o "$TARBALL" "$URL"; }
rm -rf "$SRC"
tar xf "$TARBALL" -C "$WORK"

# --- CC wrapper: compile flags + freestanding link group on every link -------
WRAP="$WORK/swiftos-cc"
cat >"$WRAP" <<EOF
#!/usr/bin/env bash
real_cc="$CC"
# _POSIX_VERSION: newlib aarch64-elf leaves it undefined (RTEMS/Cygwin only).
# bash's posixwait.h needs it for `typedef int WAIT` (else incomplete union wait).
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

# --- source patch: declare count_all_jobs when job control is off ------------
# parse.y / y.tab.c use count_all_jobs() for prompt \j. With
# --without-job-control the jobs.h include is skipped and only
# cleanup_dead_jobs is declared; nojobs.c still provides count_all_jobs
# (returns 0). GCC 14+ treats the implicit declaration as an error.
# Patch the pregenerated y.tab.c (and parse.y for consistency) — do NOT
# regenerate with host bison: macOS bison 2.3 chokes on YYEOF in bash 5.2.
for f in "$SRC/y.tab.c" "$SRC/parse.y"; do
    [[ -f "$f" ]] || continue
    perl -i -pe '
        if (/extern int cleanup_dead_jobs PARAMS\(\(void\)\);/ && !/count_all_jobs/) {
            $_ .= "extern int count_all_jobs PARAMS((void));  /* swift-os: nojobs.c; GCC 14 */\n";
        }
    ' "$f"
done
grep -q 'swift-os: nojobs.c' "$SRC/y.tab.c" \
    || fail "y.tab.c patch did not apply — cleanup_dead_jobs anchor not found"
# Keep shipped y.tab.c newer than parse.y so make does not invoke host bison.
touch "$SRC/y.tab.c" "$SRC/y.tab.h"

# --- configure ----------------------------------------------------------------
# Principle (see host-tools.sh autoconf_cross_prepare): prevent running guest
# binaries; do not answer compile-time type/capability probes. Only override
# AC_RUN_IFELSE cache vars whose cross-compile *default* is wrong for newlib
# freestanding, each with a why/what comment.
#
# Deliberately NOT set:
#   bash_cv_type_rlimit — AC_COMPILE_IFELSE for rlim_t (compat has rlim_t).
#     Exporting `yes` produced `#define RLIMTYPE yes` → unknown type name 'yes'.
#   bash_cv_have_mbstate_t, bash_cv_decl_ioctl, bash_cv_terminfo_lib — compile
#     / link probes; leave to the cross CC + our headers/libs.
(
    cd "$SRC"
    export CC="$WRAP" AR=aarch64-elf-ar RANLIB=aarch64-elf-ranlib
    export CFLAGS="" CPPFLAGS="" LDFLAGS="" LIBS=""

    # newlib has setjmp/longjmp but no sigjmp_buf / sigsetjmp / siglongjmp
    # (headers + libc). Cross default would claim "present" when
    # bash_cv_posix_signals=yes, which fabricates HAVE_POSIX_SIGSETJMP and
    # fails in include/posixjmp.h. Fall back to plain jmp_buf.
    export bash_cv_func_sigsetjmp=missing
    # Runtime behaviour probes (cannot compile-answer): freestanding newlib facts.
    export bash_cv_func_strcoll_works=yes          # newlib strcoll is strcmp-class
    export bash_cv_func_ctype_nonascii=no
    export bash_cv_wcwidth_broken=no
    export bash_cv_func_printf_a_format=yes        # %a/%A supported enough for bash
    export bash_cv_sys_named_pipes=absent          # no /dev/fd or /proc/self/fd
    # "missing" = job-control facilities absent (setpgid/tcsetpgrp not real yet).
    # Matches --without-job-control; do not claim present.
    export bash_cv_job_control_missing=missing
    export bash_cv_opendir_not_robust=no
    export bash_cv_getenv_redef=no
    export bash_cv_must_reinstall_sighandlers=no
    export bash_cv_func_setvbuf_reversed=no
    export bash_cv_ulimit_maxfds=no
    export bash_cv_func_lstat_dereferences_slashed_symlink=yes
    export bash_cv_dup2_broken=no
    export bash_cv_pgrp_pipe=no
    export bash_cv_unusable_rtsigs=yes             # no RT signal delivery
    export bash_cv_func_sbrk=no                    # freestanding heap is not sbrk
    export bash_cv_dev_stdin=absent
    export bash_cv_dev_fd=absent

    # --host alone leaves cross_compiling=maybe; AC_PROG_CC then runs a.out and
    # hangs on same-arch Linux CI. See scripts/host-tools.sh autoconf_cross_*.
    autoconf_cross_prepare
    ./configure --host=aarch64-elf "$(autoconf_cross_build_arg)" --prefix=/usr \
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
