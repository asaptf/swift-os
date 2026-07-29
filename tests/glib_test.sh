#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# glib_test.sh — GL1 GLib port acceptance.
#
# Boots the base image, logs into the root shell, and runs /bin/glibdemo, which
# links the cross-built static libglib-2.0.a and exercises GString, GList,
# GHashTable, GArray, g_utf8_validate, and g_get_monotonic_time (GLib's main-loop
# clock). The harness asserts on the demo's plain-text GLIBDEMO-OK marker.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
SEND_CHAR_DELAY="${GLIB_CHAR_DELAY:-0.01}"
SEND_SEND_DELAY="${GLIB_SEND_DELAY:-0.08}"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-glib.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-glib-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-glib-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

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
  echo "--- serial (glib) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -100 >&2 || true
  exit 1
}

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
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
await "M12c: shell ready" 120 || drive_fail "root shell did not start"
send_line '/bin/glibdemo'
await "GLIBDEMO-START" 60 || drive_fail "/bin/glibdemo did not start (link/load failure?)"
await "GLIBDEMO-OK" 60 || drive_fail "glibdemo did not complete"
send_line 'exit'
await "M12c: session ended" 60 || true

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
for marker in "GLIBDEMO-START" "GLIBDEMO-OK"; do
  if grep -qF "$marker" <<<"$clean"; then echo "PASS: $marker"; else echo "FAIL: missing marker: $marker" >&2; ok=0; fi
done
# Surface the full result line (str/list/map/array/utf8/mono/glib version) for the log.
grep -F "GLIBDEMO-OK" <<<"$clean" | tail -1 | sed 's/^/RESULT: /' >&2 || true

if (( ok )); then exit 0; fi
echo "--- serial (glibdemo region) ---" >&2
sed -n '/GLIBDEMO/,$p' <<<"$clean" | head -40 >&2
exit 1
