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
  EXPECTS+=$'\n'"[I] smp: S2b OK: process scheduler context scaffold ready"
  EXPECTS+=$'\n'"[I] smp: S2c OK: kernel scheduler owner ready"
  EXPECTS+=$'\n'"[I] smp: S2d OK: process run queue scaffold ready"
  EXPECTS+=$'\n'"[I] smp: S2e OK: dormant process scheduler CPUs published"
  EXPECTS+=$'\n'"[I] smp: S2f OK: process dispatch telemetry ready"
  EXPECTS+=$'\n'"[I] smp: S2h OK: secondary EL0 gate ready"
  EXPECTS+=$'\n'"[I] smp: S3a OK: address-space CPU mask scaffold ready"
  EXPECTS+=$'\n'"[I] smp: S3b OK: GIC SGI IPI substrate ready"
  EXPECTS+=$'\n'"[I] smp: S3c OK: TLB shootdown IPI scaffold ready"
  EXPECTS+=$'\n'"[I] smp: S3d OK: address-space TLB flush facade ready"
  EXPECTS+=$'\n'"[I] smp: S4a OK: PMM lock boundary ready"
  EXPECTS+=$'\n'"[I] smp: S4b OK: VFS lock boundary ready"
  EXPECTS+=$'\n'"[I] smp: S4c OK: kernel heap lock boundary ready"
  EXPECTS+=$'\n'"[I] sched: M4.5 sched: real context switch OK"
  EXPECTS+=$'\n'"[I] smp: S2c OK: no secondary kernel scheduler execution"
  EXPECTS+=$'\n'"[I] smp: S2g OK: coproc pair dispatch telemetry CPU0-owned"
  EXPECTS+=$'\n'"[I] smp: S2d OK: process run queue stayed CPU0-owned"
  EXPECTS+=$'\n'"[I] smp: S2e OK: secondary process scheduler contexts stayed dormant"
  EXPECTS+=$'\n'"[I] smp: S2f OK: process dispatch telemetry stayed CPU0-owned"
  EXPECTS+=$'\n'"[I] smp: S2h OK: secondary EL0 gate held CPU0-owned"
  EXPECTS+=$'\n'"[I] smp: S3a OK: address-space CPU masks stayed CPU0-owned"
  EXPECTS+=$'\n'"[I] smp: S3b OK: IPI delivery stayed scheduler-safe"
  EXPECTS+=$'\n'"[I] smp: S3c OK: TLB shootdown path stayed scheduler-safe"
  EXPECTS+=$'\n'"[I] smp: S3d OK: address-space TLB flush stayed CPU0-owned"
  EXPECTS+=$'\n'"[I] smp: S4a OK: PMM lock boundary stayed balanced"
  EXPECTS+=$'\n'"[I] smp: S4b OK: VFS lock boundary stayed balanced"
  EXPECTS+=$'\n'"[I] smp: S4c OK: kernel heap lock boundary stayed balanced"
  EXPECTS+=$'\n'"[I] smp: S2b OK: no secondary EL0 execution"
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
  userland_line="$(grep -nF "[I] boot: swift-os userland: Swift ps" "$LOG" | head -1 | cut -d: -f1)"
  no_secondary_line="$(grep -nF "[I] smp: S2b OK: no secondary EL0 execution" "$LOG" | head -1 | cut -d: -f1)"
  coproc_line="$(grep -nF "M8d OK: two EL0 processes ran concurrently" "$LOG" | head -1 | cut -d: -f1)"
  pair_telemetry_line="$(grep -nF "[I] smp: S2g OK: coproc pair dispatch telemetry CPU0-owned" "$LOG" | head -1 | cut -d: -f1)"
  kernel_demo_line="$(grep -nF "[I] sched: M4.5 sched: real context switch OK" "$LOG" | head -1 | cut -d: -f1)"
  no_secondary_kernel_line="$(grep -nF "[I] smp: S2c OK: no secondary kernel scheduler execution" "$LOG" | head -1 | cut -d: -f1)"
  runqueue_line="$(grep -nF "[I] smp: S2d OK: process run queue stayed CPU0-owned" "$LOG" | head -1 | cut -d: -f1)"
  dormant_line="$(grep -nF "[I] smp: S2e OK: secondary process scheduler contexts stayed dormant" "$LOG" | head -1 | cut -d: -f1)"
  telemetry_line="$(grep -nF "[I] smp: S2f OK: process dispatch telemetry stayed CPU0-owned" "$LOG" | head -1 | cut -d: -f1)"
  s2h_gate_line="$(grep -nF "[I] smp: S2h OK: secondary EL0 gate held CPU0-owned" "$LOG" | head -1 | cut -d: -f1)"
  s3a_mask_line="$(grep -nF "[I] smp: S3a OK: address-space CPU masks stayed CPU0-owned" "$LOG" | head -1 | cut -d: -f1)"
  s3b_ipi_line="$(grep -nF "[I] smp: S3b OK: IPI delivery stayed scheduler-safe" "$LOG" | head -1 | cut -d: -f1)"
  s3c_tlb_line="$(grep -nF "[I] smp: S3c OK: TLB shootdown path stayed scheduler-safe" "$LOG" | head -1 | cut -d: -f1)"
  s3d_tlb_line="$(grep -nF "[I] smp: S3d OK: address-space TLB flush stayed CPU0-owned" "$LOG" | head -1 | cut -d: -f1)"
  s4a_pmm_line="$(grep -nF "[I] smp: S4a OK: PMM lock boundary stayed balanced" "$LOG" | head -1 | cut -d: -f1)"
  s4b_vfs_line="$(grep -nF "[I] smp: S4b OK: VFS lock boundary stayed balanced" "$LOG" | head -1 | cut -d: -f1)"
  s4c_heap_line="$(grep -nF "[I] smp: S4c OK: kernel heap lock boundary stayed balanced" "$LOG" | head -1 | cut -d: -f1)"
  if [[ -z "$userland_line" || -z "$no_secondary_line" ||
        "$userland_line" -ge "$no_secondary_line" ]]; then
    echo "FAIL: S2b no-secondary-EL0 marker must appear after the Swift ps userland marker." >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
  fi
  if [[ -z "$kernel_demo_line" || -z "$no_secondary_kernel_line" ||
        "$kernel_demo_line" -ge "$no_secondary_kernel_line" ||
        "$no_secondary_kernel_line" -ge "$userland_line" ]]; then
    echo "FAIL: S2c no-secondary-kernel marker must appear after the kernel scheduler demo marker and before Swift ps." >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
  fi
  if [[ -z "$coproc_line" || -z "$pair_telemetry_line" ||
        "$coproc_line" -ge "$pair_telemetry_line" ||
        "$pair_telemetry_line" -ge "$userland_line" ]]; then
    echo "FAIL: S2g coproc dispatch telemetry marker must appear after the coproc pair and before Swift ps." >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
  fi
  if [[ -z "$runqueue_line" || "$userland_line" -ge "$runqueue_line" ||
        "$runqueue_line" -ge "$no_secondary_line" ]]; then
    echo "FAIL: S2d process-runqueue marker must appear after Swift ps and before the no-secondary-EL0 marker." >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
  fi
  if [[ -z "$dormant_line" || "$runqueue_line" -ge "$dormant_line" ||
        "$dormant_line" -ge "$no_secondary_line" ]]; then
    echo "FAIL: S2e dormant-scheduler marker must appear after S2d runqueue guard and before the no-secondary-EL0 marker." >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
  fi
  if [[ -z "$telemetry_line" || "$dormant_line" -ge "$telemetry_line" ||
        "$telemetry_line" -ge "$no_secondary_line" ]]; then
    echo "FAIL: S2f dispatch telemetry marker must appear after S2e and before the no-secondary-EL0 marker." >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
  fi
  if [[ -z "$s2h_gate_line" || "$telemetry_line" -ge "$s2h_gate_line" ||
        "$s2h_gate_line" -ge "$no_secondary_line" ]]; then
    echo "FAIL: S2h gate-held marker must appear after S2f and before the no-secondary-EL0 marker." >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
  fi
  if [[ -z "$s3a_mask_line" || "$s2h_gate_line" -ge "$s3a_mask_line" ||
        "$s3a_mask_line" -ge "$no_secondary_line" ]]; then
    echo "FAIL: S3a address-space mask marker must appear after S2h and before the no-secondary-EL0 marker." >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
  fi
  if [[ -z "$s3b_ipi_line" || "$s3a_mask_line" -ge "$s3b_ipi_line" ||
        "$s3b_ipi_line" -ge "$no_secondary_line" ]]; then
    echo "FAIL: S3b IPI scheduler-safe marker must appear after S3a and before the no-secondary-EL0 marker." >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
  fi
  if [[ -z "$s3c_tlb_line" || "$s3b_ipi_line" -ge "$s3c_tlb_line" ||
        "$s3c_tlb_line" -ge "$no_secondary_line" ]]; then
    echo "FAIL: S3c TLB shootdown marker must appear after S3b and before the no-secondary-EL0 marker." >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
  fi
  if [[ -z "$s3d_tlb_line" || "$s3c_tlb_line" -ge "$s3d_tlb_line" ||
        "$s3d_tlb_line" -ge "$no_secondary_line" ]]; then
    echo "FAIL: S3d address-space TLB flush marker must appear after S3c and before the no-secondary-EL0 marker." >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
  fi
  if [[ -z "$s4a_pmm_line" || "$s3d_tlb_line" -ge "$s4a_pmm_line" ||
        "$s4a_pmm_line" -ge "$no_secondary_line" ]]; then
    echo "FAIL: S4a PMM lock boundary marker must appear after S3d and before the no-secondary-EL0 marker." >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
  fi
  if [[ -z "$s4b_vfs_line" || "$s4a_pmm_line" -ge "$s4b_vfs_line" ||
        "$s4b_vfs_line" -ge "$no_secondary_line" ]]; then
    echo "FAIL: S4b VFS lock boundary marker must appear after S4a and before the no-secondary-EL0 marker." >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
  fi
  if [[ -z "$s4c_heap_line" || "$s4b_vfs_line" -ge "$s4c_heap_line" ||
        "$s4c_heap_line" -ge "$no_secondary_line" ]]; then
    echo "FAIL: S4c kernel heap lock boundary marker must appear after S4b and before the no-secondary-EL0 marker." >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
  fi

  echo "PASS: SMP boot smoke produced expected S1/S2a/S2b/S2c/S2d/S2e/S2f/S2g/S2h/S3a/S3b/S3c/S3d/S4a/S4b/S4c markers with -smp $SMP_CPU_COUNT:"
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
