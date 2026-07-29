#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# rsync_test.sh - R1 smoke: install the rsync port from a signed repo over the
# network and run `rsync --version` in QEMU.
#
# Builds a single-package repo containing only build/rsync.swpkg, signed with the
# default repo seed the base image trusts (PKGREPO_SEED_HEX), serves it over HTTP
# via QEMU user networking, then boots SwiftOS, logs in, installs rsync, and
# asserts the version banner and packaged marker file.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
SEND_CHAR_DELAY="${RSYNC_CHAR_DELAY:-0.01}"
SEND_SEND_DELAY="${RSYNC_SEND_DELAY:-0.08}"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
QEMU="${QEMU:-qemu-system-aarch64}"
PYTHON="${PYTHON:-python3}"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
PKGREPO="$ROOT/build/pkgrepo"
RSYNC_PKG="$ROOT/build/rsync.swpkg"
SEED_HEX="${PKGREPO_SEED_HEX:-000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f}"
PORT="${PORT:-18197}"
REPO_URL="http://10.0.2.2:$PORT/aarch64/current"
BASE="$ROOT/build/base-rsync-repo.img"
STORE_DISK="$ROOT/build/pkgstore-lua-install.img"
REPO_DIR="$ROOT/build/rsync-test-repo"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -x "$PKGREPO" ]] || { echo "FAIL: $PKGREPO missing (make pkgrepo)" >&2; exit 2; }
command -v "$PYTHON" >/dev/null 2>&1 || { echo "FAIL: $PYTHON not found" >&2; exit 2; }

# Build the rsync package (and refresh it if sources changed).
( cd "$ROOT" && make ports-rsync-repo-fixture ) >/dev/null 2>&1 || {
  echo "FAIL: cannot build rsync port package" >&2; exit 2;
}
[[ -f "$RSYNC_PKG" ]] || { echo "FAIL: $RSYNC_PKG missing after build" >&2; exit 2; }

# Publish a one-package repo signed with the seed the base image trusts.
rm -rf "$REPO_DIR"
"$PKGREPO" create --package "$RSYNC_PKG" --output "$REPO_DIR" \
  --seed-hex "$SEED_HEX" --generation 1 >/dev/null 2>&1 || {
  echo "FAIL: cannot create rsync test repo" >&2; exit 2;
}

# Base image whose default pkg repo is our HTTP-served rsync repo. rsync only
# needs the OS to boot (a shell + pkg + networking), so keep the image free of
# the heavy shell ports (bash/zsh) and point root's login shell at busybox ash
# (/bin/sh) — SH3 defaults it to /bin/zsh, which need not be built for this test.
rm -f "$BASE"
( cd "$ROOT" && make BASE_IMG=build/base-rsync-repo.img PKG_DEFAULT_REPO_URL="$REPO_URL" INCLUDE_BASH=0 INCLUDE_ZSH=0 ROOT_LOGIN_SHELL=/bin/sh base-image ) >/dev/null 2>&1 || {
  echo "FAIL: cannot build default-repo base image" >&2; exit 2;
}
( cd "$ROOT" && make package-lua-install-fixture ) >/dev/null 2>&1 || {
  echo "FAIL: cannot create package store image" >&2; exit 2;
}

LOG="$(mktemp -t swiftos-rsync.XXXXXX)"
HTTPLOG="$(mktemp -t swiftos-rsync-http.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-rsync-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-rsync-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""; HTTPPID=""

stop_all() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  [[ -n "$HTTPPID" ]] && kill "$HTTPPID" 2>/dev/null || true
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
cleanup() { stop_all; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$HTTPLOG" "$PIDFILE" "$INFIFO"; }
trap cleanup EXIT

drive_fail() {
  echo "FAIL: $*" >&2
  [[ -f "$LOG" ]] && { echo "--- serial ---" >&2; tail -n 200 "$LOG" >&2 || true; }
  [[ -f "$HTTPLOG" ]] && { echo "--- http log ---" >&2; cat "$HTTPLOG" >&2 || true; }
  exit 1
}

await() {
  local needle="$1" timeout="${2:-40}" start now
  start="$(date +%s)"
  while true; do
    grep -qF "$needle" "$LOG" && return 0
    now="$(date +%s)"; (( now - start >= timeout )) && return 1
    sleep 0.2
  done
}


dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

( cd "$REPO_DIR/.." && "$PYTHON" -m http.server "$PORT" --bind 0.0.0.0 \
    --directory "$REPO_DIR" >"$HTTPLOG" 2>&1 ) &
HTTPPID=$!
disown "$HTTPPID" 2>/dev/null || true
sleep 0.8
kill -0 "$HTTPPID" 2>/dev/null || { echo "FAIL: HTTP server did not start" >&2; sed -n '1,80p' "$HTTPLOG" >&2; exit 2; }

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$BASE,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -drive "file=$STORE_DISK,format=raw,if=none,id=swpkgstore" \
  -device virtio-blk-device,drive=swpkgstore \
  -netdev user,id=n0 \
  -device virtio-net-device,netdev=n0 \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "timed out waiting for tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "timed out waiting for login prompt"
send_line 'root'
await "Password:" 90 || drive_fail "timed out waiting for password prompt"
send_line 'swordfish'
await "Welcome to swift-os, root" 120 || drive_fail "root login did not complete"
# Shell-agnostic readiness marker (console-login prints this before exec'ing the
# root login shell — /bin/zsh per SH3 — so it does not assume a specific shell).
await "M12c: shell ready" 120 || drive_fail "root shell did not start"

await_shell_ready "$LOG" 60 || drive_fail "guest shell not reading after login"
send_line "pkg update"
await "pkg: catalog updated $REPO_URL" 120 || drive_fail "pkg update did not complete from default repo"
send_line "pkg search rsync"
await "rsync-3.4.1_1" 60 || drive_fail "pkg search did not find rsync"
send_line "pkg install rsync"
await "pkg: installed rsync-3.4.1_1" 120 || drive_fail "rsync package was not installed"
send_line "/usr/bin/rsync --version"
await "version 3.4.1" 60 || drive_fail "rsync --version did not run"
send_line "cat /usr/share/rsync/swiftos-rsync.version"
await "rsync 3.4.1 swift-os static no-tls no-xattr no-acl" 60 || drive_fail "rsync marker output mismatch"
send_line "pkg list"
await "rsync-3.4.1_1" 60 || drive_fail "installed rsync package not listed"
send_line 'exit'
await "M12c: session ended" 60 || true

exec 3>&-
stop_all
QP=""; HTTPPID=""

clean="$(tr -d '\r' < "$LOG")"
ok=1
grep -qF "pkg: installed rsync-3.4.1_1" <<<"$clean" || { echo "FAIL: rsync install output missing" >&2; ok=0; }
grep -qF "version 3.4.1" <<<"$clean" || { echo "FAIL: rsync --version banner missing" >&2; ok=0; }
if [[ "$ok" -eq 1 ]]; then
  echo "PASS: rsync 3.4.1 installed from signed repo and ran --version in QEMU"
  exit 0
fi
echo "--- serial (tail) ---" >&2; tail -n 200 "$LOG" >&2 || true
exit 1
