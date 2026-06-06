#!/usr/bin/env bash
# swift_date_test.sh — native Swift /bin/date reads the PL031 RTC.
#
# /bin/date prints the current UTC wall-clock time (time() syscall -> PL031 RTC
# data register, which QEMU seeds from the host clock). We assert the output is
# a plausible YYYY-MM-DD HH:MM:SS UTC line in the 2020s (not the 1970 epoch),
# proving the RTC is actually read.

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

LOG="$(mktemp -t swiftos-date.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-date-pid.XXXXXX)"
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
  sleep 8;  printf 'tty-line\n'
  sleep 1;  printf '\003'
  sleep 3;  printf 'root\n'
  sleep 1.5;  printf 'swordfish\n'
  sleep 3;  printf '/bin/date\n'
  sleep 2;  printf 'exit\n'
  sleep 2
) | "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -kernel "$KERNEL" >"$LOG" 2>&1 &
QP=$!
sleep 28
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
# A line like "2026-06-06 12:34:56 UTC" — year 20xx proves the RTC was read.
if grep -Eq '^20[0-9][0-9]-[01][0-9]-[0-3][0-9] [0-2][0-9]:[0-5][0-9]:[0-5][0-9] UTC$' <<<"$clean"; then
  echo "PASS: /bin/date printed a real RTC wall-clock time"
  echo "  $(grep -Eom1 '^20[0-9][0-9]-[01][0-9]-[0-3][0-9] [0-2][0-9]:[0-5][0-9]:[0-5][0-9] UTC$' <<<"$clean")"
  exit 0
fi
echo "FAIL: /bin/date did not print a plausible UTC timestamp" >&2
sed -n '/\/bin\/date/,$p' <<<"$clean" | head -10 >&2
exit 1
