#!/usr/bin/env bash
# sleep_test.sh — timer-backed nanosleep/sleep actually blocks.
#
# Two checks, end to end inside QEMU:
#   1. /bin/sleepprobe (native Swift) reads the RTC, sleeps 2s via nanosleep,
#      reads the RTC again, and prints "SLEEP_DELTA=<secs>". The old no-op stub
#      gave 0; a working timer-backed sleep yields >= 2. This is the timing proof.
#      QEMU's RTC is host-wall-clock based, so long host stalls are tolerated
#      above the lower bound rather than treated as kernel sleep failures.
#   2. busybox `sleep 1` returns (then we echo a marker), proving the whole
#      busybox -> libc nanosleep -> SYS_NANOSLEEP -> kernel path works.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
SEND_CHAR_DELAY="${SLEEP_CHAR_DELAY:-0.01}"
SEND_SEND_DELAY="${SLEEP_SEND_DELAY:-0.08}"
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

LOG="$(mktemp -t swiftos-sleep.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-sleep-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-sleep-in.XXXXXX)"; mkfifo "$INFIFO"
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

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

await_regex() {  # await_regex REGEX [MAXSEC]
  local regex="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    sed 's/\r//' "$LOG" 2>/dev/null | grep -Eq -- "$regex" && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (sleep driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -80 >&2 || true
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
await_shell_ready "$LOG" 60 || drive_fail "guest shell not reading after login"
probe_host_start="$(date +%s)"
send_line '/bin/sleepprobe'
await_regex 'SLEEP_DELTA=[0-9]+' 120 || drive_fail "/bin/sleepprobe printed no SLEEP_DELTA line"
probe_host_end="$(date +%s)"
send_line 'busybox sleep 1'
send_line 'echo BUSYBOX-SLEEP-DONE'
await "BUSYBOX-SLEEP-DONE" 120 || true
send_line 'exit'
await "M12c: session ended" 60 || true

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1

delta="$(grep -Eom1 'SLEEP_DELTA=[0-9]+' <<<"$clean" | grep -Eo '[0-9]+$' || true)"
host_delta=$((probe_host_end - probe_host_start))
if [[ -z "$delta" ]]; then
  echo "FAIL: /bin/sleepprobe printed no SLEEP_DELTA line" >&2
  ok=0
elif (( delta < 2 || host_delta < 1 || host_delta > 180 )); then
  echo "FAIL: nanosleep(2s) measured rtc_delta=${delta}s host_delta=${host_delta}s (expected rtc>=2 and host 1..180)" >&2
  ok=0
else
  echo "PASS: nanosleep(2s) blocked; rtc_delta=${delta}s host_delta=${host_delta}s"
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
