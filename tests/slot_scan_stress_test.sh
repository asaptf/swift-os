#!/usr/bin/env bash
# slot_scan_stress_test.sh - concurrent full-table scan vs slot grow/shrink.
#
# Boots under -smp N (default 4), logs in as root, and runs /bin/slotscanstress,
# which races SYS_PSINFO/SYS_SYSINFO/SYS_PROCSTAT full-table walks against
# fork/reap churn that grows and reclaims PMM-backed process-slot segments.
#
# Pass: no panic, SLOTSCAN-OK, free memory returns after the final churn cycle.
# A green run is evidence the scan/shrink use-after-free is closed for the
# exercised interleavings — not a formal proof of every possible schedule.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
SEND_CHAR_DELAY="${SLOTSCAN_CHAR_DELAY:-0.02}"
SEND_SEND_DELAY="${SLOTSCAN_SEND_DELAY:-0.12}"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
KERNEL="$ROOT/build/kernel.elf"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
SMP_CPUS="${SMP_CPUS:-4}"

if [[ ! "$SMP_CPUS" =~ ^[0-9]+$ ]] || (( 10#$SMP_CPUS < 1 )); then
  echo "FAIL: SMP_CPUS must be a positive integer, got '$SMP_CPUS'." >&2
  exit 2
fi
SMP_CPU_COUNT=$((10#$SMP_CPUS))
if (( SMP_CPU_COUNT > 8 )); then
  echo "FAIL: SMP_CPUS must be <= 8 for current SMP scaffolding, got '$SMP_CPUS'." >&2
  exit 2
fi

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" || "$ROOT/userland/slotscanstress.c" -nt "$DISK" || "$ROOT/Makefile" -nt "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || {
    echo "FAIL: cannot build base.img" >&2
    exit 2
  }
fi

LOG="$(mktemp -t swiftos-slotscan.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-slotscan-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-slotscan-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""

stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

await() {
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    if grep -qF "panic:" "$LOG" 2>/dev/null; then
      return 2
    fi
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1
    n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (slot-scan stress) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -200 >&2 || true
  exit 1
}


if (( SMP_CPU_COUNT == 1 )); then
  DTB="${SMP_DTB:-$ROOT/build/virt.dtb}"
else
  DTB="${SMP_DTB:-$ROOT/build/virt-smp-${SMP_CPU_COUNT}.dtb}"
fi
if [[ -z "${SMP_DTB:-}" && ! -f "$DTB" ]]; then
  tmp_dtb="$DTB.tmp"
  mkdir -p "$(dirname "$DTB")"
  "$QEMU" -M "virt,dumpdtb=$tmp_dtb" -cpu cortex-a72 -smp "$SMP_CPU_COUNT" -m 256M -nographic >/dev/null 2>&1
  mv "$tmp_dtb" "$DTB"
elif [[ -n "${SMP_DTB:-}" && ! -f "$DTB" ]]; then
  echo "FAIL: SMP_DTB points to missing file: $DTB" >&2
  exit 2
fi

"$QEMU" -M virt -cpu cortex-a72 -smp "$SMP_CPU_COUNT" -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  -device "loader,file=$DTB,addr=0x4FF00000,force-raw=on" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "timed out waiting for tty line prompt"
printf 'tty-line\n' >&3
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "timed out waiting for login prompt"
send_line 'root'
await "Password:" 90 || drive_fail "timed out waiting for password prompt"
send_line 'swordfish'
await "M12c: shell ready" 120 || drive_fail "root shell did not start"
await_shell_ready "$LOG" 60 || drive_fail "guest shell not reading after login"
send_line '/bin/slotscanstress'
await "M11d: exec loaded from disk /bin/slotscanstress" 60 || drive_fail "slotscanstress did not execute"
await "SLOTSCAN-OK scan+shrink concurrency completed" 180 || drive_fail "slotscanstress did not finish"
send_line 'exit'
await "M12c: session ended" 60 || true

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
for marker in \
  "SLOTSCAN-START scan+shrink concurrency stress" \
  "SLOTSCAN-SCANNER-OK id=0" \
  "SLOTSCAN-CHURN-OK id=0" \
  "SLOTSCAN-MEM before=" \
  "SLOTSCAN-OK scan+shrink concurrency completed"; do
  grep -qF "$marker" <<<"$clean" || { echo "FAIL: missing marker: $marker" >&2; ok=0; }
done
grep -qF "SLOTSCAN-FAIL" <<<"$clean" && { echo "FAIL: slotscanstress reported a failure" >&2; ok=0; }
grep -qF "panic:" <<<"$clean" && { echo "FAIL: kernel panic during slot-scan stress" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: slot-scan vs grow/shrink concurrency under -smp $SMP_CPU_COUNT (evidence, not proof)"
  exit 0
fi
echo "--- serial (slot-scan stress) ---" >&2
sed 's/\r//' "$LOG" 2>/dev/null | tail -200 >&2 || true
exit 1
