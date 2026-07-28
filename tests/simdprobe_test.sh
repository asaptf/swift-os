#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# simdprobe_test.sh — LM1b diagnostic: does the int8 NEON dot match scalar in QEMU?
#
# Boots, logs in, runs /bin/simdprobe (built with +neon) which computes an
# int8 dot both forced-scalar and via SIMD16<Int8> in the SAME binary and
# compares. Prints the per-case scalar/simd values. The verdict:
#   "SIMDPROBE: ALL OK"        -> int8 NEON computes correctly under QEMU
#   "SIMDPROBE: MISMATCH FOUND" -> the int8 SIMD path itself is wrong here

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$DISK" ]]   || { echo "FAIL: $DISK missing (make base-image)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-simd.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-simd-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-simd-in.XXXXXX)"; mkfifo "$INFIFO"
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
  echo "--- serial ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -60 >&2 || true
  exit 1
}
send_line() {
  local line="$1" delay="${SLEEP_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do printf '%s' "${line:i:1}" >&3; sleep "$delay"; done
  printf '\n' >&3
  sleep "${SLEEP_SEND_DELAY:-0.08}"
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

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "no tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "no tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "no login prompt"
send_line 'root'
await "Password:" 90 || drive_fail "no password prompt"
send_line 'swordfish'
await "M12c: shell ready" 120 || drive_fail "root shell did not start"
send_line '/bin/simdprobe'
await "SIMDPROBE: ALL OK" 60 || await "SIMDPROBE: MISMATCH FOUND" 5 || drive_fail "simdprobe printed no verdict"
send_line 'exit'
await "M12c: session ended" 60 || true

exec 3>&-; stop_qemu; QP=""
clean="$(sed 's/\r//' "$LOG")"

echo "--- simdprobe output ---"
grep -F "SIMDPROBE:" <<<"$clean"
echo "------------------------"

if grep -qF "SIMDPROBE: ALL OK" <<<"$clean"; then
  echo "PASS: int8 SIMD dot matches forced-scalar in QEMU (NEON int8 codegen correct)"
  exit 0
fi
echo "FAIL: int8 SIMD dot diverges from forced-scalar in QEMU" >&2
exit 1
