#!/usr/bin/env bash
# package_overlay_test.sh - P2 acceptance: mount and execute a package payload.
#
# The test boots with the base image plus a pkghello package payload image, then
# logs in and runs /usr/bin/pkghello from the mounted package namespace.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE_DISK="$ROOT/build/base.img"
PKG_DISK="$ROOT/build/pkghello-payload.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$BASE_DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
if [[ ! -f "$PKG_DISK" ]]; then
  ( cd "$ROOT" && make package-fixture ) >/dev/null 2>&1 || { echo "FAIL: cannot build pkghello payload image" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-package-overlay.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-package-overlay-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-package-overlay-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      sleep 0.2
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  if [[ -n "$QP" ]]; then
    wait "$QP" 2>/dev/null || true
  fi
}
cleanup() {
  stop_qemu
  exec 3>&- 2>/dev/null || true
  rm -f "$LOG" "$PIDFILE" "$INFIFO"
}
trap cleanup EXIT

dtb_args=()
if [[ -f "$DTB" ]]; then
  dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
fi

await() {
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (package overlay driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/M11c:/,$p' >&2 || true
  exit 1
}

send_line() {
  local line="$1" delay="${PACKAGE_OVERLAY_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${PACKAGE_OVERLAY_SEND_DELAY:-0.08}"
}

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$BASE_DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -drive "file=$PKG_DISK,format=raw,if=none,id=swospkg0,readonly=on" \
  -device virtio-blk-device,drive=swospkg0 \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" 60 || drive_fail "timed out waiting for tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "timed out waiting for login prompt"
send_line 'root'
await "Password:" 90 || drive_fail "timed out waiting for password prompt"
send_line 'swordfish'
await "Welcome to swift-os, root" 120 || drive_fail "root login did not complete"
await "M12c: shell ready" 120 || drive_fail "root shell did not start"
send_line '/usr/bin/pkghello'
await "pkghello: hello from package overlay" 60 || drive_fail "/usr/bin/pkghello did not execute from package overlay"
send_line 'exit'
await "M12c: session ended" 60 || true

exec 3>&-
stop_qemu
QP=""

ok=1
grep -qF "M11c: read-only base mounted from disk" "$LOG" || { echo "FAIL: base was not mounted from disk" >&2; ok=0; }
grep -qF "pkghello: hello from package overlay" "$LOG" || { echo "FAIL: pkghello output missing" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /usr/bin/pkghello executed from package payload overlay (P2 acceptance)"
  exit 0
fi
echo "--- serial (package overlay region) ---" >&2
sed 's/\r//' "$LOG" | sed -n '/M11c:/,$p' >&2
exit 1
