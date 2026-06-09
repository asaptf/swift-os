#!/usr/bin/env bash
# smp_boot_test.sh - SMP boot smoke harness.
#
# S1: secondary CPUs are released into the early online/heartbeat path while
# scheduler and EL0 work still remain on CPU0.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
SMP_CPUS="${SMP_CPUS:-4}"
TIMEOUT="${TIMEOUT:-90}"

if [[ ! "$SMP_CPUS" =~ ^[0-9]+$ ]] || (( 10#$SMP_CPUS < 1 )); then
  echo "FAIL: SMP_CPUS must be a positive integer, got '$SMP_CPUS'." >&2
  exit 2
fi
SMP_CPU_COUNT=$((10#$SMP_CPUS))
if (( SMP_CPU_COUNT > 8 )); then
  echo "FAIL: SMP_CPUS must be <= 8 for S0 mailbox/topology scaffolding, got '$SMP_CPUS'." >&2
  exit 2
fi
if (( SMP_CPU_COUNT == 1 )); then
  PSCI_ENABLE_MASK=0
  PSCI_EXPECT="[I] smp: S0g OK: PSCI discovery ready"
else
  PSCI_ENABLE_MASK=$(((1 << SMP_CPU_COUNT) - 1))
  PSCI_EXPECT="[I] smp: S0g OK: PSCI discovery ready detail=$PSCI_ENABLE_MASK"
fi

EXPECTS="${EXPECTS:-[I] platform: M9 OK: hardware discovered from device tree
[I] smp: S0 OK: foundations ready
[I] smp: S0b OK: atomics and barriers ready
[I] smp: S0d OK: per-CPU state ready
[I] smp: S0e OK: secondary park mailbox ready
[I] smp: S0f OK: CPU topology ready detail=$SMP_CPU_COUNT
$PSCI_EXPECT
[I] smp: S1 OK: secondary CPUs online detail=$SMP_CPU_COUNT
[I] boot: swift-os userland: Swift ps}"

if [[ -z "${EXPECTS_OVERRIDE:-}" ]]; then
  cpu=0
  while (( cpu < SMP_CPU_COUNT )); do
    EXPECTS+=$'\n'"[I] smp: S2a OK: per-CPU timer heartbeat ready detail=$((cpu + 1))"
    if (( cpu == 0 )); then
      EXPECTS+=$'\n'"[I] smp: S1 CPU online"
    else
      EXPECTS+=$'\n'"[I] smp: S1 CPU online detail=$cpu"
    fi
    cpu=$((cpu + 1))
  done
  EXPECTS+=$'\n'"[I] smp: S2a OK: scheduler boundary held detail=$SMP_CPU_COUNT"
  EXPECTS+=$'\n'"[I] smp: S2a OK: scheduler owner ready"
fi

if [[ ! -f "$KERNEL" ]]; then
  echo "FAIL: $KERNEL not found - run 'make build' first." >&2
  exit 2
fi

if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || {
    echo "FAIL: cannot build base.img" >&2
    exit 2
  }
fi

LOG="$(mktemp -t swiftos-smp-boot.XXXXXX)"
QEMU_PID=""

stop_qemu() {
  if [[ -n "$QEMU_PID" ]]; then
    kill "$QEMU_PID" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "$QEMU_PID" 2>/dev/null || break
      sleep 0.1
    done
    kill -0 "$QEMU_PID" 2>/dev/null && kill -9 "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
    QEMU_PID=""
  fi
}

cleanup() {
  stop_qemu
  rm -f "$LOG"
}
trap cleanup EXIT

DTB="${SMP_DTB:-$ROOT/build/virt-smp-${SMP_CPU_COUNT}.dtb}"
if [[ -z "${SMP_DTB:-}" ]]; then
  tmp_dtb="$DTB.tmp"
  mkdir -p "$(dirname "$DTB")"
  "$QEMU" -M "virt,dumpdtb=$tmp_dtb" -cpu cortex-a72 -smp "$SMP_CPU_COUNT" -m 256M -nographic >/dev/null 2>&1
  mv "$tmp_dtb" "$DTB"
elif [[ ! -f "$DTB" ]]; then
  echo "FAIL: SMP_DTB points to missing file: $DTB" >&2
  exit 2
fi

dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

blk_args=(-global virtio-mmio.force-legacy=false
          -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on"
          -device virtio-blk-device,drive=swosbase)

"$QEMU" -M virt -cpu cortex-a72 -smp "$SMP_CPU_COUNT" -m 256M -nographic -no-reboot \
  "${dtb_args[@]}" "${blk_args[@]}" -kernel "$KERNEL" >"$LOG" 2>&1 &
QEMU_PID=$!

all_found() {
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    grep -qF "$line" "$LOG" 2>/dev/null || return 1
  done <<<"$EXPECTS"
  return 0
}

found=0
for _ in $(seq 1 "$((TIMEOUT * 10))"); do
  if grep -qF "panic:" "$LOG" 2>/dev/null; then
    found=2
    break
  fi
  if grep -qF "M9 platform: no valid device tree" "$LOG" 2>/dev/null ||
     grep -qF "M9 WARN: device tree incomplete" "$LOG" 2>/dev/null; then
    found=2
    break
  fi
  if all_found; then
    found=1
    break
  fi
  sleep 0.1
done

stop_qemu

if [[ "$found" -eq 1 ]]; then
  echo "PASS: SMP boot smoke produced expected S1/S2a markers with -smp $SMP_CPU_COUNT:"
  while IFS= read -r line; do
    [[ -n "$line" ]] && echo "  - $line"
  done <<<"$EXPECTS"
  exit 0
fi

if [[ "$found" -eq 2 ]]; then
  echo "FAIL: kernel panic seen during SMP boot smoke. Serial log was:" >&2
else
  echo "FAIL: not all expected SMP boot markers seen within ${TIMEOUT}s. Serial log was:" >&2
fi
echo "---------------------------------------------" >&2
cat -v "$LOG" >&2
echo "---------------------------------------------" >&2
exit 1
