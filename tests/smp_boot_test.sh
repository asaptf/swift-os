#!/usr/bin/env bash
# smp_boot_test.sh - S0 parked-SMP boot smoke harness.
#
# S0a: secondary CPUs are expected to stay parked for now. The test asserts the
# CPU0 S0 marker plus a late userland marker while QEMU exposes extra CPUs.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
SMP_CPUS="${SMP_CPUS:-4}"
TIMEOUT="${TIMEOUT:-90}"

EXPECTS="${EXPECTS:-[I] platform: M9 OK: hardware discovered from device tree
[I] smp: S0 OK: foundations ready
[I] smp: S0b OK: atomics and barriers ready
[I] smp: S0d OK: per-CPU state ready
[I] boot: swift-os userland: Swift ps}"

if [[ ! "$SMP_CPUS" =~ ^[0-9]+$ ]] || (( 10#$SMP_CPUS < 1 )); then
  echo "FAIL: SMP_CPUS must be a positive integer, got '$SMP_CPUS'." >&2
  exit 2
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
    wait "$QEMU_PID" 2>/dev/null || true
    QEMU_PID=""
  fi
}

cleanup() {
  stop_qemu
  rm -f "$LOG"
}
trap cleanup EXIT

dtb_args=()
if [[ -f "$DTB" ]]; then
  dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
fi

blk_args=(-global virtio-mmio.force-legacy=false
          -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on"
          -device virtio-blk-device,drive=swosbase)

"$QEMU" -M virt -cpu cortex-a72 -smp "$SMP_CPUS" -m 256M -nographic -no-reboot \
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
  if all_found; then
    found=1
    break
  fi
  sleep 0.1
done

stop_qemu

if [[ "$found" -eq 1 ]]; then
  echo "PASS: SMP boot smoke produced expected markers with -smp $SMP_CPUS:"
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
