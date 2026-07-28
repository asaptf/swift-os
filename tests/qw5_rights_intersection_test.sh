#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# qw5_rights_intersection_test.sh — QW5 rights = held ∩ requested on IPC transfer.
#
# Boots the base image, logs in, and runs /bin/qw5-rightsxfer. The program moves a
# /dev/zero handle (READ|WRITE|TRANSFER) over a C4 endpoint requesting only
# READ|TRANSFER; the receiver proves a read succeeds, a write is denied (WRITE was
# attenuated away), and the sender's source fd was invalidated (move semantics).
# Passes when "QW5: PASS" appears; fails on any "QW5: FAIL" marker or QEMU exit.

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

LOG="$(mktemp -t swiftos-qw5.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-qw5-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-qw5-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      for _ in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
      done
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    if [[ -n "$QP" ]] && ! jobs -pr | grep -qx "$QP"; then
      echo "FAIL: QEMU exited while waiting for marker: $marker" >&2
      echo "--- serial tail ---" >&2
      sed 's/\r//' "$LOG" | tail -80 >&2
      exit 1
    fi
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

send_text() {  # send_text TEXT
  local text="$1" i
  for (( i = 0; i < ${#text}; i++ )); do
    printf '%s' "${text:i:1}" >&3 || return 1
    sleep 0.02
  done
}

send_after() {  # send_after MARKER MAXSEC TEXT
  local marker="$1" max="$2" text="$3"
  if ! await "$marker" "$max"; then
    echo "FAIL: timed out waiting for marker: $marker" >&2
    echo "--- serial tail ---" >&2
    sed 's/\r//' "$LOG" | tail -80 >&2
    exit 1
  fi
  send_text "$text"
}

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  ${dtb_args[@]+"${dtb_args[@]}"} \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

send_after "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" $'tty-line\n'
send_after "M7 tty: running; press Ctrl-C" 40 $'\003'
send_after "swift-os login:" 60 $'root\n'
send_after "Password:" 40 $'swordfish\n'
send_after "Welcome to swift-os, root" 60 $'/bin/qw5-rightsxfer\n'

# Wait for the verdict, then drop back to the shell so QEMU shuts down cleanly.
if await "QW5: PASS" 60; then
  send_text $'exit\n'
fi

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
if grep -qF "QW5: FAIL" <<<"$clean"; then
  echo "FAIL: a QW5 assertion failed:" >&2
  grep -F "QW5:" <<<"$clean" >&2
  exit 1
fi
if grep -qF "QW5: PASS" <<<"$clean"; then
  echo "PASS: IPC handle transfer attenuated rights to held ∩ requested (QW5 acceptance)"
  exit 0
fi

echo "FAIL: QW5: PASS marker never appeared" >&2
echo "--- serial (qw5 region) ---" >&2
sed -n '/QW5:/,$p' <<<"$clean" | head -40 >&2
exit 1
