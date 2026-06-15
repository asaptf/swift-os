#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# build-node.sh - cross-build entry point for the SwiftOS Node.js port.
#
# This is the growing build driver for `ports/lang/nodejs`. Node.js is a Tier-4
# XL runtime; bringing it up is a multi-wall porting effort, so this script
# advances one wall at a time and *asserts the current frontier* the same way
# the NPM* libuv/newlib probes do.
#
# Walls cleared so far:
#   NPM26 - Node's `configure.py` only accepts a fixed `valid_os` tuple, so the
#           scaffolded `--dest-os=swiftos` is rejected outright; and the recipe
#           also carried two flags (`--without-dtrace`, `--without-etw`) that
#           Node 24.16 no longer defines, which configure forwards to GYP and
#           which abort the run ("gyp: --without-etw not found").
#   NPM27 - First-pass strategy: masquerade as `linux` (NODE_DEST_OS, default
#           `linux`) instead of standing up a first-class `swiftos` platform
#           across configure+GYP+libuv+V8. With the dead flags dropped, configure
#           now COMPLETES. The frontier moves into the build.
#   NPM28 - libuv's linux backend (`deps/uv/src/unix/linux.c`) is monolithic
#           (epoll event loop + inotify fs-events + procfs cpu/mem), so steering
#           to libuv's posix-poll backend would drop those non-event functions;
#           instead we keep OS==linux and supply the missing Linux headers as
#           isolated shims under `userland/node-compat` (kept separate from
#           userland/compat so other ports' feature detection is unaffected).
#           With those shims + `-D__linux__` + the newlib pthread feature-test
#           macros, linux.c now compiles to an object. SwiftOS has poll/eventfd/
#           futex but no epoll, so epoll is emulated over poll in the companion
#           implementation (NPM30), not shimmed 1:1.
#   NPM29 - Closed the Linux constant/type long-tail in libuv's other unix
#           sources (cpu_set_t/CPU_* + affinity, CMSG_FIRSTHDR/NXTHDR, sendfile,
#           errqueue, full struct rusage, UTIME_*, _IOC macros, scandir, IPv4/
#           IPv6 multicast + source-membership structs, struct mmsghdr) via more
#           userland/node-compat shims. ALL libuv unix sources now compile to
#           objects; what remains is the external shim *implementation* (NPM30).
#   NPM30 - Implemented the shim surface in userland/node-compat/node_compat.c:
#           epoll emulated over poll()/eventfd (a real eventfd backs each epoll
#           instance; a dynamic interest list is turned into a pollfd[] each
#           wait), ENOSYS fallbacks for inotify/sendfile/recvmmsg/sendmmsg/raw
#           syscall, clean dlopen-family failures, getifaddrs empty list,
#           in6addr_any, and the POSIX functions newlib lacks (pread/pwrite via
#           lseek, dup3, scandir via readdir, sched_*/affinity/schedparam no-ops,
#           pathconf, getpwuid_r/getgrgid_r/lchown/utimens ENOSYS). libuv now
#           archives to libuv.a and links a minimal uv program into a static
#           AArch64 ELF with no undefined symbols.
#
# This probe asserts the NPM30 frontier: configure SUCCEEDS, every libuv unix
# source COMPILES, and libuv LINKS into a static AArch64 ELF (uvhello.elf).
#
# Run via: make node-configure-probe
#
# Env overrides: NODE_VERSION, NODE_DISTFILES, NODE_CC, NODE_CXX, NODE_DEST_OS.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${NODE_VERSION:-24.16.0}"
PORT_JSON="$ROOT/ports/lang/nodejs/Port.json"
DISTFILES="${NODE_DISTFILES:-$ROOT/build/swport-distfiles}"
WORK="$ROOT/build/node-port-work"
SRC="$WORK/node-v${VERSION}"
TARBALL="$DISTFILES/node-v${VERSION}.tar.gz"
LOG="$ROOT/build/node-configure.log"
CC="${NODE_CC:-aarch64-elf-gcc}"
CXX="${NODE_CXX:-aarch64-elf-g++}"
# First-pass platform strategy (NPM27): build as if targeting linux and close
# the gaps in newlib/compat, rather than porting a first-class swiftos platform.
DEST_OS="${NODE_DEST_OS:-linux}"

if [[ -f "$ROOT/sysroot/newlib/aarch64-elf/lib/libc.a" ]]; then
    SYSROOT="$ROOT/sysroot/newlib/aarch64-elf"
else
    SYSROOT="$ROOT/sysroot/aarch64-elf"
fi
COMPAT="$ROOT/userland/compat"

log()  { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 2; }

require_exe() { command -v "$1" >/dev/null 2>&1 || fail "missing executable: $1"; }

# --- toolchain + inputs -----------------------------------------------------
require_exe "$CC"
require_exe "$CXX"
require_exe python3
require_exe tar
require_exe curl
require_exe shasum
[[ -f "$PORT_JSON" ]] || fail "missing recipe: $PORT_JSON"
[[ -f "$SYSROOT/lib/libc.a" ]] || fail "newlib sysroot missing. Run: make newlib"

# Pull the pinned source URL + sha256 straight from the recipe so the script and
# Port.json can never drift.
read_json_field() {
    grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$PORT_JSON" | head -1 |
        sed -E "s/\"$1\"[[:space:]]*:[[:space:]]*\"([^\"]*)\"/\1/"
}
URL="$(read_json_field url)"
SHA256_EXPECTED="$(read_json_field sha256)"
[[ -n "$URL" && -n "$SHA256_EXPECTED" ]] || fail "could not read source url/sha256 from $PORT_JSON"

mkdir -p "$DISTFILES" "$WORK" "$ROOT/build"

if [[ ! -f "$TARBALL" ]]; then
    log "Fetching $URL"
    curl -fsSL "$URL" -o "$TARBALL" || fail "download failed"
fi
SHA256_GOT="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
[[ "$SHA256_GOT" == "$SHA256_EXPECTED" ]] ||
    fail "sha256 mismatch: got $SHA256_GOT expected $SHA256_EXPECTED"
log "Distfile verified: node-v${VERSION}.tar.gz ($SHA256_GOT)"

if [[ ! -d "$SRC" ]]; then
    log "Extracting node-v${VERSION}.tar.gz"
    tar xzf "$TARBALL" -C "$WORK" || fail "extract failed"
fi

# --- configure (NPM27: must now succeed under the linux masquerade) ---------
# Mirror the recipe args, but drop flags Node 24.16 no longer defines
# (--without-dtrace/--without-etw) and map the eventual swiftos target to
# DEST_OS for the first build pass.
CONFIGURE_ARGS=(
    --dest-cpu=arm64
    "--dest-os=${DEST_OS}"
    --cross-compiling
    --fully-static
    --without-npm
    --without-corepack
    --v8-lite-mode
)

log "Running configure (CC=$CC CXX=$CXX) ${CONFIGURE_ARGS[*]}"
( cd "$SRC" && CC="$CC" CXX="$CXX" python3 configure.py "${CONFIGURE_ARGS[@]}" ) \
    >"$LOG" 2>&1
CONFIGURE_RC=$?

if [[ "$CONFIGURE_RC" -ne 0 ]]; then
    log "--- last 40 lines of $LOG ---"
    tail -40 "$LOG" >&2 || true
    fail "configure failed (rc=$CONFIGURE_RC); expected success under DEST_OS=$DEST_OS. Frontier regressed."
fi
log "configure completed successfully (DEST_OS=$DEST_OS)."

# --- assert the NPM29 frontier: all of libuv's unix layer compiles ----------
# With the userland/node-compat shims on the include path ahead of
# userland/compat, plus -D__linux__ and the newlib pthread feature-test macros,
# every libuv unix source (not just the linux backend) must compile to an
# object. This proves the Linux *header/constant* surface is complete; the
# remaining work (NPM30) is the *implementation* of the shim functions, after
# which libuv can link.
UV="$SRC/deps/uv"
NODE_COMPAT="$ROOT/userland/node-compat"
OBJ_DIR="$ROOT/build/node-uv-obj"
[[ -d "$UV/src/unix" ]] || fail "libuv source not found at $UV"
mkdir -p "$OBJ_DIR"

UV_CFLAGS=(
    -I "$UV/include" -I "$UV/src"
    -D_GNU_SOURCE -D__linux__
    -D_POSIX_READER_WRITER_LOCKS=1 -D_POSIX_SEMAPHORES=1 -D_POSIX_BARRIERS=1
    -D_UNIX98_THREAD_MUTEX_ATTRIBUTES=1
    -isystem "$NODE_COMPAT" -isystem "$COMPAT" -isystem "$SYSROOT/include"
)

# The unix sources GYP compiles for OS==linux, plus the portable src/*.c core.
UV_SRCS=(
    src/unix/async.c src/unix/core.c src/unix/dl.c src/unix/fs.c
    src/unix/getaddrinfo.c src/unix/getnameinfo.c src/unix/loop-watcher.c
    src/unix/loop.c src/unix/pipe.c src/unix/poll.c src/unix/process.c
    src/unix/random-devurandom.c src/unix/random-getrandom.c
    src/unix/random-sysctl-linux.c src/unix/signal.c src/unix/stream.c
    src/unix/tcp.c src/unix/thread.c src/unix/tty.c src/unix/udp.c
    src/unix/linux.c src/unix/procfs-exepath.c src/unix/proctitle.c
    src/fs-poll.c src/idna.c src/inet.c src/random.c src/strscpy.c
    src/strtok.c src/threadpool.c src/timer.c src/uv-common.c
    src/uv-data-getter-setters.c src/version.c
)

uv_fail=0
for f in "${UV_SRCS[@]}"; do
    o="$OBJ_DIR/$(printf '%s' "$f" | tr '/' '_').o"
    if ! ( cd "$UV" && "$CC" "${UV_CFLAGS[@]}" -c "$f" -o "$o" ) 2>"$o.err"; then
        log "COMPILE FAIL: $f"
        grep -E 'error:' "$o.err" | sed -E 's/.*error: //' | sort -u | head -8 >&2 || true
        uv_fail=$((uv_fail + 1))
    fi
done

if [[ "$uv_fail" -ne 0 ]]; then
    fail "$uv_fail libuv source(s) failed to compile against node-compat; extend userland/node-compat."
fi

log "All ${#UV_SRCS[@]} libuv unix sources compiled to objects."

# --- assert the NPM30 frontier: libuv links into a static AArch64 ELF -------
# Implement the shim surface (userland/node-compat/node_compat.c: epoll over
# poll/eventfd + ENOSYS fallbacks + dlopen stubs + in6addr_any + the POSIX
# funcs newlib lacks), archive libuv.a, and link a minimal uv program. Success
# proves libuv is usable on SwiftOS via the masquerade.
RUNTIME_DIR="$ROOT/build/node-port-runtime"
mkdir -p "$RUNTIME_DIR"
RT_CFLAGS=(
    -ffreestanding -Os -D_GNU_SOURCE -D__linux__
    -D_POSIX_READER_WRITER_LOCKS=1 -D_POSIX_SEMAPHORES=1 -D_POSIX_BARRIERS=1
    -D_UNIX98_THREAD_MUTEX_ATTRIBUTES=1
    -isystem "$NODE_COMPAT" -isystem "$COMPAT" -isystem "$SYSROOT/include"
)

"$CC" "${RT_CFLAGS[@]}" -I "$UV/include" -c "$NODE_COMPAT/node_compat.c" \
    -o "$RUNTIME_DIR/node_compat.o" || fail "node_compat.c failed to compile"
"$CC" "${RT_CFLAGS[@]}" -c "$ROOT/userland/lib/crt0_newlib.S" -o "$RUNTIME_DIR/crt0.o"
"$CC" "${RT_CFLAGS[@]}" -c "$ROOT/userland/lib/newlib_syscalls.c" -o "$RUNTIME_DIR/syscalls.o"
"$CC" "${RT_CFLAGS[@]}" -c "$ROOT/userland/compat/stubs.c" -o "$RUNTIME_DIR/compat_stubs.o"

LIBUV_A="$RUNTIME_DIR/libuv.a"
rm -f "$LIBUV_A"
aarch64-elf-ar rcs "$LIBUV_A" "$OBJ_DIR"/*.o "$RUNTIME_DIR/node_compat.o"

# Minimal libuv program: init a loop, run one non-blocking turn, close it.
cat > "$RUNTIME_DIR/uvhello.c" <<'EOF'
#include <uv.h>
#include <stdio.h>
int main(void) {
    printf("libuv %s\n", uv_version_string());
    uv_loop_t loop;
    if (uv_loop_init(&loop)) { printf("loop init failed\n"); return 1; }
    uv_run(&loop, UV_RUN_NOWAIT);
    uv_loop_close(&loop);
    printf("ok\n");
    return 0;
}
EOF
"$CC" "${RT_CFLAGS[@]}" -I "$UV/include" -c "$RUNTIME_DIR/uvhello.c" \
    -o "$RUNTIME_DIR/uvhello.o" || fail "uvhello.c failed to compile"

UVHELLO_ELF="$ROOT/build/uvhello.elf"
LDFLAGS=(-nostartfiles -nostdlib -static -T "$ROOT/userland/user_newlib.ld"
    -Wl,-z,max-page-size=4096 -L "$SYSROOT/lib")
if ! "$CC" "${LDFLAGS[@]}" "$RUNTIME_DIR/crt0.o" "$RUNTIME_DIR/uvhello.o" \
        "$RUNTIME_DIR/syscalls.o" "$RUNTIME_DIR/compat_stubs.o" "$LIBUV_A" \
        -Wl,--start-group -lc -lm -lgcc -Wl,--end-group -o "$UVHELLO_ELF" \
        2>"$RUNTIME_DIR/uvlink.err"; then
    log "libuv link FAILED. Unresolved symbols:"
    grep -oE "undefined reference to \`[^']+'" "$RUNTIME_DIR/uvlink.err" |
        sed -E "s/.*\`([^']+)'/\1/" | sort -u >&2 || true
    fail "libuv did not link; implement the missing symbols in node_compat.c."
fi

undef="$(aarch64-elf-nm -u "$UVHELLO_ELF" 2>/dev/null)"
[[ -z "$undef" ]] || fail "uvhello.elf has undefined symbols: $undef"
aarch64-elf-readelf -h "$UVHELLO_ELF" | grep -q 'Machine:.*AArch64' ||
    fail "uvhello.elf is not an AArch64 ELF"

log ""
log "NPM30 frontier CONFIRMED: libuv (${#UV_SRCS[@]} sources + node_compat shims)"
log "  archives to libuv.a and links a minimal uv program into a static AArch64"
log "  ELF with no undefined symbols: $UVHELLO_ELF"
log "Runtime: epoll-over-poll is exercised in QEMU by 'make epoll-test' (NPM31)."
log "Next (NPM32+): the V8 platform build under the masquerade (host mksnapshot)."
log "Full configure output: $LOG"
exit 0
