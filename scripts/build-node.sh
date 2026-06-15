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
#           implementation (NPM29+), not shimmed 1:1.
#
# This probe asserts the NPM28 frontier: configure must SUCCEED under the linux
# masquerade AND libuv's linux backend must COMPILE against node-compat.
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

# --- assert the NPM28 frontier: libuv linux-backend header surface ----------
# The libuv linux backend (deps/uv/src/unix/linux.c) is the file that pulls
# every Linux-only header (epoll/inotify/ifaddrs/packet/prctl/syscall). With the
# userland/node-compat shims on the include path ahead of userland/compat, and
# the newlib pthread feature-test macros + __linux__ set, that file must now
# compile to an object. This proves the header surface is complete; the
# remaining work (NPM29+) is the *implementation* of the shim functions and the
# constant long-tail in libuv's other unix sources.
UV="$SRC/deps/uv"
NODE_COMPAT="$ROOT/userland/node-compat"
LINUX_BACKEND="$UV/src/unix/linux.c"
LINUX_OBJ="$ROOT/build/node-uv-linux.o"
[[ -f "$LINUX_BACKEND" ]] || fail "libuv linux backend not found at $LINUX_BACKEND"

UV_CFLAGS=(
    -I "$UV/include" -I "$UV/src"
    -D_GNU_SOURCE -D__linux__
    -D_POSIX_READER_WRITER_LOCKS=1 -D_POSIX_SEMAPHORES=1 -D_POSIX_BARRIERS=1
    -isystem "$NODE_COMPAT" -isystem "$COMPAT" -isystem "$SYSROOT/include"
)

if "$CC" "${UV_CFLAGS[@]}" -c "$LINUX_BACKEND" -o "$LINUX_OBJ" 2>"$ROOT/build/node-uv-linux.err"; then
    log ""
    log "NPM28 frontier CONFIRMED: configure succeeds and libuv's linux backend"
    log "  (src/unix/linux.c) compiles to an object against userland/node-compat."
    log "  Object: $LINUX_OBJ"
    log "Next (NPM29+): close the constant long-tail in libuv's other unix sources"
    log "  (cpu_set_t/CPU_*, CMSG_*, sendfile.h, errqueue.h, rusage fields, ...) and"
    log "  implement the shim surface: epoll_* over poll/eventfd, getifaddrs,"
    log "  inotify_* (ENOSYS), prctl, syscall (-ENOSYS), dlopen stubs."
    log "Full configure output: $LOG"
    exit 0
fi

log "libuv linux backend FAILED to compile against node-compat:"
log "--- errors ---"
grep -E 'error:' "$ROOT/build/node-uv-linux.err" | sed -E 's/.*error: //' | sort -u | head -20 >&2 || true
fail "node-compat header surface incomplete; linux.c no longer compiles. Restore/extend userland/node-compat."
