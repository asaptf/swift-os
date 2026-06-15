#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# build-node.sh - cross-build entry point for the SwiftOS Node.js port.
#
# This is the growing build driver for `ports/lang/nodejs`. Node.js is a Tier-4
# XL runtime; bringing it up is a multi-wall porting effort, so this script
# advances one wall at a time and *asserts the current frontier* the same way
# the NPM* libuv/newlib probes do.
#
# NPM26 frontier (current): Node's own `configure.py` rejects the SwiftOS target.
# The scaffolded recipe passes `--dest-os=swiftos`, but upstream `configure.py`
# only accepts a fixed `valid_os` tuple (win/mac/solaris/freebsd/openbsd/linux/
# android/aix/cloudabi/os400/ios/openharmony). Even with `swiftos` spliced into
# that tuple, GYP immediately fails because no `swiftos` flavor exists across
# GYP, libuv (`deps/uv`), and V8 (`deps/v8`) -- each selects platform backends
# by OS name (e.g. libuv linux=epoll, bsd=kqueue; there is no generic POSIX
# event backend). Standing up a `swiftos` platform across GYP + libuv + V8 is
# the next porting series; until then this probe asserts that the build stops
# exactly at the documented wall.
#
# Run via: make node-configure-probe
#
# Env overrides: NODE_VERSION, NODE_DISTFILES, NODE_CC, NODE_CXX.

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

if [[ -f "$ROOT/sysroot/newlib/aarch64-elf/lib/libc.a" ]]; then
    SYSROOT="$ROOT/sysroot/newlib/aarch64-elf"
else
    SYSROOT="$ROOT/sysroot/aarch64-elf"
fi

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
    # crude but dependency-free: first "<key>": "<value>" string in the file.
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

# --- configure (current frontier) ------------------------------------------
# Mirror the argument vector recorded in ports/lang/nodejs/Port.json.
CONFIGURE_ARGS=(
    --dest-cpu=arm64
    --dest-os=swiftos
    --cross-compiling
    --fully-static
    --without-dtrace
    --without-etw
    --without-npm
    --without-corepack
    --v8-lite-mode
)

log "Running configure (CC=$CC CXX=$CXX) ${CONFIGURE_ARGS[*]}"
( cd "$SRC" && CC="$CC" CXX="$CXX" python3 configure.py "${CONFIGURE_ARGS[@]}" ) \
    >"$LOG" 2>&1
CONFIGURE_RC=$?

# Assert the frontier: vanilla configure must reject the swiftos target because
# `swiftos` is not in its valid_os tuple. This is the NPM26 wall.
if [[ "$CONFIGURE_RC" -eq 0 ]]; then
    fail "configure unexpectedly succeeded -- frontier moved past NPM26; update build-node.sh to the next porting wall and proceed to 'make'."
fi

if grep -q -- "--dest-os" "$LOG" && grep -q "swiftos" "$LOG"; then
    : # expected: argparse echoes the choices including our rejected value
fi

if grep -Eq "argument --dest-os: invalid choice: 'swiftos'|invalid choice: 'swiftos'|--dest-os \{win" "$LOG"; then
    log ""
    log "NPM26 frontier CONFIRMED: Node configure.py rejects --dest-os=swiftos"
    log "  ($SRC/configure.py valid_os has no 'swiftos' target)."
    log "Next porting series: add a 'swiftos' platform across configure.py +"
    log "GYP flavor + libuv (deps/uv) + V8 (deps/v8) backend selection."
    log "Full configure output: $LOG"
    exit 0
fi

# Configure failed for a different reason than the documented wall -- surface it.
log "Configure failed, but NOT at the expected NPM26 valid_os wall:"
log "--- last 40 lines of $LOG ---"
tail -40 "$LOG" >&2 || true
fail "unexpected configure failure (rc=$CONFIGURE_RC); investigate before advancing the recipe."
