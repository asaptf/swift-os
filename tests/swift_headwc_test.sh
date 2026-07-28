#!/usr/bin/env bash
# swift_headwc_test.sh — native Swift /bin/head, /bin/wc, /bin/touch.
#
# Boots with the packed base image, logs in as root, builds a small file with
# the shell, then exercises the three Swift tools (reached by absolute path so
# the busybox standalone shell execs our binaries):
#   - wc counts lines/words/bytes,
#   - head -n N prints the first N lines (verified by piping head into wc),
#   - touch creates an empty tmpfs file (then wc reports 0 0 0).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-headwc.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-headwc-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-headwc-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (head/wc driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -100 >&2 || true
  exit 1
}

send_line() {
  local line="$1" delay="${HEADWC_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${HEADWC_SEND_DELAY:-0.08}"
}

qemu_args=("$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot
  -pidfile "$PIDFILE"
  -global virtio-mmio.force-legacy=false)
if [[ -f "$DTB" ]]; then
  qemu_args+=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
fi
qemu_args+=(-drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -kernel "$KERNEL")
"${qemu_args[@]}" <"$INFIFO" >"$LOG" 2>&1 &
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
send_line 'echo one > /tmp/t'
send_line 'echo two >> /tmp/t'
send_line 'echo three >> /tmp/t'
send_line '/bin/wc /tmp/t'
send_line '/bin/head -n 2 /tmp/t | /bin/wc'
send_line '/bin/touch /tmp/empty'
send_line '/bin/wc /tmp/empty'
send_line 'echo HEADWC-DONE'
send_line 'exit'
await "HEADWC-DONE" 180 || drive_fail "shell did not survive head/wc/touch"
await "M12c: session ended" 60 || true

exec 3>&-
stop_qemu
QP=""

CLEAN="$(sed 's/\r//' "$LOG")"
ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }

grep -qE '^[[:space:]]*3[[:space:]]+3[[:space:]]+14 /tmp/t$' <<<"$CLEAN" \
  || fail "wc /tmp/t did not report 3 lines / 3 words / 14 bytes"
grep -qE '^[[:space:]]*2[[:space:]]+2[[:space:]]+8[[:space:]]*$' <<<"$CLEAN" \
  || fail "head -n 2 | wc did not report 2 lines / 2 words / 8 bytes (head limit wrong)"
grep -qE '^[[:space:]]*0[[:space:]]+0[[:space:]]+0 /tmp/empty$' <<<"$CLEAN" \
  || fail "touch + wc /tmp/empty did not report an empty file"
grep -qF 'HEADWC-DONE' <<<"$CLEAN" \
  || fail "shell did not survive (no trailing marker)"

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: native Swift head/wc/touch work on swift-os"
  exit 0
fi
echo "--- serial (tool region) ---" >&2
sed -n '/\/bin\/wc/,$p' <<<"$CLEAN" >&2
exit 1
