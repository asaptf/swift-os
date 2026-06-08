#!/usr/bin/env bash
# sleep_test.sh — timer-backed nanosleep/sleep actually blocks.
#
# Two checks, end to end inside QEMU:
#   1. /bin/sleepprobe (native Swift) reads the RTC, sleeps 2s via nanosleep,
#      reads the RTC again, and prints "SLEEP_DELTA=<secs>". The old no-op stub
#      gave 0; a working timer-backed sleep yields >= 2. This is the timing proof.
#   2. busybox `sleep 1` returns (then we echo a marker), proving the whole
#      busybox -> libc nanosleep -> SYS_NANOSLEEP -> kernel path works.

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

LOG="$(mktemp -t swiftos-sleep.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-sleep-pid.XXXXXX)"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; rm -f "$LOG" "$PIDFILE"' EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

(
  sleep 12;  printf 'tty-line\n'
  sleep 2;   printf '\003'
  sleep 5;   printf 'root\n'
  sleep 2;   printf 'swordfish\n'
  sleep 5;   printf '/bin/sleepprobe\n'
  sleep 6;   printf 'busybox sleep 1\n'
  sleep 4;   printf 'echo BUSYBOX-SLEEP-DONE\n'
  sleep 3;   printf 'exit\n'
  sleep 2
) | "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -kernel "$KERNEL" >"$LOG" 2>&1 &
QP=$!
sleep 46
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1

delta="$(grep -Eom1 'SLEEP_DELTA=[0-9]+' <<<"$clean" | grep -Eo '[0-9]+$' || true)"
if [[ -z "$delta" ]]; then
  echo "FAIL: /bin/sleepprobe printed no SLEEP_DELTA line" >&2
  ok=0
elif (( delta < 2 || delta > 10 )); then
  echo "FAIL: nanosleep(2s) measured delta=${delta}s (expected 2..10)" >&2
  ok=0
else
  echo "PASS: nanosleep(2s) blocked for ${delta}s (timer-backed sleep works)"
fi

if grep -qF "BUSYBOX-SLEEP-DONE" <<<"$clean"; then
  echo "PASS: busybox sleep returned (busybox -> libc -> kernel path works)"
else
  echo "FAIL: busybox 'sleep 1' did not complete" >&2
  ok=0
fi

if (( ok )); then exit 0; fi
echo "--- serial (sleep region) ---" >&2
sed -n '/sleepprobe/,$p' <<<"$clean" | head -20 >&2
exit 1
