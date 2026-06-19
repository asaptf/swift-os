#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# futex_test.sh — TH8: direct-futex boundary probe (val-mismatch fast path,
# wake-empty, and the 16-slot wait table full -> EAGAIN). Runs at -smp 4 (via
# SMP_CPUS / SMP_DTB) so the slot-table races (cross-CPU wait/wake) matter.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
SMP_CPUS="${SMP_CPUS:-4}"
DTB="${SMP_DTB:-$ROOT/build/virt-smp4.dtb}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-futex.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-futex-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-futex-in.XXXXXX)"; mkfifo "$INFIFO"
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
  echo "--- serial (futex driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -100 >&2 || true
  exit 1
}

send_line() {
  local line="$1" delay="${FUTEX_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${FUTEX_SEND_DELAY:-0.08}"
}

"$QEMU" -M virt -cpu cortex-a72 -smp "$SMP_CPUS" -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
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
await "built-in shell (ash)" 120 || drive_fail "root shell did not start"
send_line '/bin/futexprobe'
await "FUTEXPROBE-OK" 120 || drive_fail "/bin/futexprobe did not report success"
send_line 'exit'
await "M12c: session ended" 60 || true

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
if grep -qE 'futexprobe: FAIL' <<<"$clean"; then
  echo "FAIL: a futexprobe assertion failed:" >&2
  grep -F 'futexprobe: FAIL' <<<"$clean" >&2
  exit 1
fi
ok=1
for marker in \
  "FUTEXPROBE-VALMISMATCH-OK" \
  "FUTEXPROBE-WAKEEMPTY-OK" \
  "FUTEXPROBE-WAKEALL-OK" \
  "FUTEXPROBE-OK"; do
  if grep -qF "$marker" <<<"$clean"; then
    echo "PASS: $marker"
  else
    echo "FAIL: missing marker: $marker" >&2
    ok=0
  fi
done

if (( ok )); then
  echo "PASS: direct futex boundaries (val-mismatch, wake-empty, multi-waiter wake) at -smp $SMP_CPUS"
  exit 0
fi
echo "--- serial (futexprobe region) ---" >&2
sed -n '/futexprobe\|FUTEXPROBE/,$p' <<<"$clean" | head -50 >&2
exit 1
