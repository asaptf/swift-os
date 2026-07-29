#!/usr/bin/env bash
# saturation_test.sh - fixed-size kernel-pool saturation smoke.
#
# Boots, logs in as root, and runs /bin/satstress, which drives the still-
# bounded kernel resource pools (per-process fds, pipes, IPC endpoints) to
# their ceiling and back, exercises process-table growth past the initial
# slot capacity (PMM-backed reclaimable segments: free memory must return after
# reap), and under artificial memory pressure asserts fork fails with EAGAIN
# (admission reserve) without panic, plus a balanced vnode create/unlink churn.
# For bounded pools the pass condition is twofold: refuse gracefully at the
# cap (a clean negative errno, NOT a panic) AND recover afterwards (no slot
# leak). Defaults to single-core (the cap logic is not SMP-specific); set
# SMP_CPUS=N to also exercise the S4 pool locks while secondaries are online
# and ticking.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
SMP_CPUS="${SMP_CPUS:-1}"

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
if [[ ! -f "$DISK" || "$ROOT/userland/satstress.c" -nt "$DISK" || "$ROOT/Makefile" -nt "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || {
    echo "FAIL: cannot build base.img" >&2
    exit 2
  }
fi

LOG="$(mktemp -t swiftos-sat.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-sat-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-sat-in.XXXXXX)"; mkfifo "$INFIFO"
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
  echo "--- serial (saturation stress) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -160 >&2 || true
  exit 1
}

send_line() {
  local line="$1" delay="${SAT_CHAR_DELAY:-0.02}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${SAT_SEND_DELAY:-0.12}"
}

# Device-tree blob: single-core uses virt.dtb, SMP uses virt-smp-N.dtb.
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
send_line '/bin/satstress'
await "M11d: exec loaded from disk /bin/satstress" 60 || drive_fail "satstress did not execute"
await "SAT-OK fixed-size pool saturation completed" 120 || drive_fail "satstress did not finish"
send_line 'exit'
await "M12c: session ended" 60 || true

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
for marker in \
  "SAT-START fixed-size pool saturation" \
  "SAT-PROC-OK n=" \
  "SAT-PROC-MEM before=" \
  "SAT-ADMIT-OK refused_after_n=" \
  "SAT-FD-OK n=" \
  "SAT-PIPE-OK n=" \
  "SAT-ENDPOINT-OK n=" \
  "SAT-VNODE-OK" \
  "SAT-OK fixed-size pool saturation completed"; do
  grep -qF "$marker" <<<"$clean" || { echo "FAIL: missing marker: $marker" >&2; ok=0; }
done
grep -qF "SAT-FAIL" <<<"$clean" && { echo "FAIL: satstress reported a failure" >&2; ok=0; }
grep -qF "panic:" <<<"$clean" && { echo "FAIL: kernel panic seen during saturation stress" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: fixed-size pool saturation graceful + recovered under -smp $SMP_CPU_COUNT"
  exit 0
fi
echo "--- serial (saturation stress region) ---" >&2
sed -n '/\/bin\/satstress/,$p' <<<"$clean" | head -80 >&2
exit 1
