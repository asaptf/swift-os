#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# ncurses_test.sh — NC1 ncurses port acceptance.
#
# Boots the base image, logs into the root shell, and runs /bin/ncdemo, which
# links the cross-built static libncurses.a. The demo resolves its terminal
# from compiled-in fallbacks (no terminfo DB on disk), enters raw mode via
# tcsetattr, draws a box + greeting on the 24x80 serial console, reads one key
# ('q'), and runs endwin(). The harness asserts on the demo's plain-text markers
# (printed after endwin so we never parse escape sequences).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-ncurses.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-ncurses-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-ncurses-in.XXXXXX)"; mkfifo "$INFIFO"
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
  echo "--- serial (ncurses) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -100 >&2 || true
  exit 1
}

send_line() {
  local line="$1" delay="${NC_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${NC_SEND_DELAY:-0.08}"
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

# Pre-login M7 tty demo: feed it a line then Ctrl-C to reach the login prompt.
await "M7 tty: type a line then Enter" 60 || drive_fail "timed out waiting for tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "timed out waiting for login prompt"
send_line 'root'
await "Password:" 90 || drive_fail "timed out waiting for password prompt"
send_line 'swordfish'
await "M12c: shell ready" 120 || drive_fail "root shell did not start"
send_line '/bin/ncdemo'
await "NCDEMO-START" 60 || drive_fail "/bin/ncdemo did not start (link/load failure?)"
# Satisfy the getch() loop with a single 'q' (no newline — raw mode).
printf 'q' >&3
await "NCDEMO-OK rows=24 cols=80" 60 || drive_fail "ncdemo did not complete cleanly"
send_line 'exit'
await "M12c: session ended" 60 || true

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
if grep -qF "NCDEMO-INITFAIL" <<<"$clean"; then
  echo "FAIL: ncdemo reported terminfo/initscr failure" >&2
  grep -F "NCDEMO-INITFAIL" <<<"$clean" >&2
  exit 1
fi
ok=1
for marker in \
  "NCDEMO-START" \
  "NCDEMO-OK rows=24 cols=80"; do
  if grep -qF "$marker" <<<"$clean"; then
    echo "PASS: $marker"
  else
    echo "FAIL: missing marker: $marker" >&2
    ok=0
  fi
done

if (( ok )); then exit 0; fi
echo "--- serial (ncdemo region) ---" >&2
sed -n '/NCDEMO/,$p' <<<"$clean" | head -60 >&2
exit 1
