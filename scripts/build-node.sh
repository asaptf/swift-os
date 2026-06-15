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
#           now COMPLETES. The frontier moves into the build: libuv's `linux`
#           backend (`deps/uv/src/unix/linux.c`) hard-includes <sys/epoll.h>,
#           <sys/inotify.h>, <sys/syscall.h> -- none of which exist in our
#           newlib sysroot or userland/compat. SwiftOS provides poll + eventfd +
#           futex but no epoll. libuv ships a poll-based core (`posix-poll.c`),
#           so NPM28 will steer libuv to that backend rather than shim epoll.
#
# This probe asserts the NPM27 frontier: configure must SUCCEED under the linux
# masquerade, and the epoll-class headers the linux backend needs must be ABSENT
# (proving the next wall is libuv's event backend, not configure).
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

# --- assert the NPM27 frontier: libuv event-backend wall --------------------
# libuv's linux backend needs epoll/inotify/syscall headers we do not provide.
# Prove they are absent so the next milestone (NPM28) is unambiguously "steer
# libuv to its posix-poll backend", not "configure".
MISSING=()
for h in sys/epoll.h sys/inotify.h sys/syscall.h; do
    if printf '#include <%s>\nint main(void){return 0;}\n' "$h" |
        "$CC" -isystem "$COMPAT" -isystem "$SYSROOT/include" -x c - \
            -fsyntax-only -o /dev/null >/dev/null 2>&1; then
        : # header resolved -- unexpected
    else
        MISSING+=("$h")
    fi
done

if [[ "${#MISSING[@]}" -eq 3 ]]; then
    log ""
    log "NPM27 frontier CONFIRMED: configure succeeds; libuv linux backend wall ahead."
    log "  Absent headers (no epoll on SwiftOS): ${MISSING[*]}"
    log "  Next (NPM28): build libuv with its posix-poll backend (uses poll, which"
    log "  SwiftOS has) instead of linux.c's epoll path."
    log "Full configure output: $LOG"
    exit 0
fi

fail "expected epoll-class headers to be absent (got missing: ${MISSING[*]:-none}); frontier moved -- libuv may now build, advance build-node.sh to the next wall (compile/link)."
