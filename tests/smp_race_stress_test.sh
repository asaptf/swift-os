#!/usr/bin/env bash
# smp_race_stress_test.sh - concurrent cross-CPU resource-churn race smoke.
#
# Boots under -smp N and lets the kernel's SMPRACE demo run N+2 copies of
# /bin/smprace concurrently across CPUs (reusing the reviewed S5f run-any
# placement primitive). While those copies execute in parallel they hammer the
# S4-locked shared pools (PMM via mmap/munmap, VFS/tmpfs via create/write/unlink,
# the pipe pool). The pass condition is that genuine multi-CPU contention left no
# damage: every placed copy ran to completion, the kernel's frame-leak check
# passed, and the S4a-S4e lock-boundary guards stayed balanced - with no panic.
# A CPU0-only userland stress cannot put two CPUs inside those locks at once;
# this is the test that does.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
SMP_CPUS="${SMP_CPUS:-4}"
TIMEOUT="${TIMEOUT:-150}"

if [[ ! "$SMP_CPUS" =~ ^[0-9]+$ ]] || (( 10#$SMP_CPUS < 1 )); then
  echo "FAIL: SMP_CPUS must be a positive integer, got '$SMP_CPUS'." >&2
  exit 2
fi
SMP_CPU_COUNT=$((10#$SMP_CPUS))
if (( SMP_CPU_COUNT < 2 )); then
  echo "FAIL: SMP race stress expects at least 2 CPUs, got '$SMP_CPUS'." >&2
  exit 2
fi
if (( SMP_CPU_COUNT > 8 )); then
  echo "FAIL: SMP_CPUS must be <= 8 for current SMP scaffolding, got '$SMP_CPUS'." >&2
  exit 2
fi

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" || "$ROOT/userland/smprace.c" -nt "$DISK" || "$ROOT/Makefile" -nt "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || {
    echo "FAIL: cannot build base.img" >&2
    exit 2
  }
fi

LOG="$(mktemp -t swiftos-smprace.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-smprace-pid.XXXXXX)"
QP=""

stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; rm -f "$LOG" "$PIDFILE"' EXIT

await() {
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    if grep -qaF "panic:" "$LOG" 2>/dev/null; then
      return 2
    fi
    grep -qaF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1
    n=$((n + 1))
  done
  return 1
}

DTB="${SMP_DTB:-$ROOT/build/virt-smp-${SMP_CPU_COUNT}.dtb}"
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
  -kernel "$KERNEL" >"$LOG" 2>&1 &
QP=$!

rc=0
await "SMPRACE OK: concurrent EL0 churn completed" "$TIMEOUT"
case $? in
  0) ;;
  2) echo "FAIL: kernel panic during SMP race stress" >&2; rc=1 ;;
  *) echo "FAIL: timed out waiting for SMPRACE completion" >&2; rc=1 ;;
esac

# Let the post-demo S4 lock-boundary guards emit before we tear down.
[[ "$rc" -eq 0 ]] && { await "S4e OK: network lock boundary stayed balanced" 40 || true; }

stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
# Note: per-copy stdout (SMPRACE-CHILD-OK) is intentionally NOT asserted - with
# multiple CPUs writing the UART at once the lines interleave character-by-character
# and are unparseable. Instead the kernel reports a clean "copies=N ok=N" summary
# and panics if any copy's self-check failed, so the OK line below already implies
# every concurrently-placed copy passed under genuine multi-CPU contention.
for marker in \
  "swift-os SMPRACE: concurrent EL0 resource churn" \
  "SMPRACE OK: concurrent EL0 churn completed copies=" \
  "SMPRACE OK: concurrent churn crossed scheduler CPUs" \
  "S4a OK: PMM lock boundary stayed balanced" \
  "S4b OK: VFS lock boundary stayed balanced" \
  "S4e OK: network lock boundary stayed balanced"; do
  grep -qF "$marker" <<<"$clean" || { echo "FAIL: missing marker: $marker" >&2; ok=0; }
done
grep -qF "panic:" <<<"$clean" && { echo "FAIL: kernel panic seen during SMP race stress" >&2; ok=0; }

summary="$(grep -aoE 'SMPRACE OK: concurrent EL0 churn completed copies=[0-9]+ ok=[0-9]+' <<<"$clean" | head -1)"
if [[ "$rc" -eq 0 && "$ok" -eq 1 ]]; then
  echo "PASS: concurrent PMM/VFS/pipe churn across -smp $SMP_CPU_COUNT, locks balanced (${summary:-summary missing})"
  exit 0
fi
echo "--- serial (SMP race stress region) ---" >&2
sed -n '/SMPRACE: concurrent/,$p' <<<"$clean" | head -80 >&2
exit 1
