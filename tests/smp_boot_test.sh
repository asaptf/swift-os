#!/usr/bin/env bash
# smp_boot_test.sh - SMP boot smoke harness.
#
# S2/S5: secondary CPUs are released, keep kernel scheduler work on CPU0, run
# the restricted coproc EL0 pair, S5b/S5c placement stress, S5d fanout, and
# S5e shared-address-space thread fanout, and S5f run-any placement under the
# same gate.

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
  EXPECTS+=$'\n'"[I] smp: S4d OK: package-store lock boundary ready"
  EXPECTS+=$'\n'"[I] smp: S4b OK: VFS lock boundary ready"
  EXPECTS+=$'\n'"[I] smp: S4c OK: kernel heap lock boundary ready"
  EXPECTS+=$'\n'"[I] smp: S4e OK: network lock boundary ready"
  EXPECTS+=$'\n'"[I] smp: S5a OK: per-CPU utilization counters ready"
  EXPECTS+=$'\n'"[I] sched: M4.5 sched: real context switch OK"
  EXPECTS+=$'\n'"[I] smp: S2c OK: no secondary kernel scheduler execution"
  if (( SMP_CPU_COUNT > 1 )); then
    EXPECTS+=$'\n'"[I] smp: S2h OK: coproc pair dispatched across scheduler CPUs"
    EXPECTS+=$'\n'"[I] smp: S5b OK: EL0 scheduler placed batch across CPUs"
    EXPECTS+=$'\n'"[I] smp: S5c OK: repeated EL0 placement stress crossed CPUs"
    EXPECTS+=$'\n'"[I] smp: S5d OK: EL0 fanout crossed scheduler CPUs"
    EXPECTS+=$'\n'"[I] smp: S5e OK: shared-address-space threads crossed CPUs"
    EXPECTS+=$'\n'"[I] smp: S5f OK: run-any placement covered scheduler CPUs"
  else
    EXPECTS+=$'\n'"[I] smp: S2h OK: coproc pair dispatch CPU0 fallback"
    EXPECTS+=$'\n'"[I] smp: S5b OK: EL0 scheduler placement CPU0 fallback"
    EXPECTS+=$'\n'"[I] smp: S5c OK: repeated EL0 placement stress CPU0 fallback"
    EXPECTS+=$'\n'"[I] smp: S5d OK: EL0 fanout CPU0 fallback"
    EXPECTS+=$'\n'"[I] smp: S5e OK: shared-address-space thread fanout CPU0 fallback"
    EXPECTS+=$'\n'"[I] smp: S5f OK: run-any placement CPU0 fallback"
  fi
  EXPECTS+=$'\n'"[I] smp: S2h OK: process scheduler quiesced after multi-CPU dispatch"
  EXPECTS+=$'\n'"[I] smp: S2h OK: secondary EL0 gate closed after restricted dispatch"
  if (( SMP_CPU_COUNT > 1 )); then
    EXPECTS+=$'\n'"[I] smp: S5g OK: default multi-CPU EL0 placement enabled detail=$SMP_CPU_COUNT"
    EXPECTS+=$'\n'"[I] smp: S5g OK: default multi-CPU EL0 covered scheduler CPUs"
  else
    EXPECTS+=$'\n'"[I] smp: S5g OK: default multi-CPU EL0 placement enabled"
    EXPECTS+=$'\n'"[I] smp: S5g OK: default multi-CPU EL0 CPU0 fallback"
  fi
  EXPECTS+=$'\n'"[I] smp: S3a OK: address-space CPU masks matched dispatch CPUs"
  EXPECTS+=$'\n'"[I] smp: S3b OK: IPI delivery stayed scheduler-safe"
  EXPECTS+=$'\n'"[I] smp: S3c OK: TLB shootdown path stayed scheduler-safe"
  EXPECTS+=$'\n'"[I] smp: S3d OK: address-space TLB flush matched dispatch CPUs"
  EXPECTS+=$'\n'"[I] smp: S4a OK: PMM lock boundary stayed balanced"
  EXPECTS+=$'\n'"[I] smp: S4b OK: VFS lock boundary stayed balanced"
  EXPECTS+=$'\n'"[I] smp: S4c OK: kernel heap lock boundary stayed balanced"
  EXPECTS+=$'\n'"[I] smp: S4d OK: package-store lock boundary stayed balanced"
  EXPECTS+=$'\n'"[I] smp: S4e OK: network lock boundary stayed balanced"
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
  coproc_line="$(grep -nF "M8d OK: two EL0 processes ran concurrently" "$LOG" | head -1 | cut -d: -f1)"
  if (( SMP_CPU_COUNT > 1 )); then
    pair_marker="[I] smp: S2h OK: coproc pair dispatched across scheduler CPUs"
    s5b_marker="[I] smp: S5b OK: EL0 scheduler placed batch across CPUs"
    s5c_marker="[I] smp: S5c OK: repeated EL0 placement stress crossed CPUs"
    s5d_marker="[I] smp: S5d OK: EL0 fanout crossed scheduler CPUs"
    s5e_marker="[I] smp: S5e OK: shared-address-space threads crossed CPUs"
    s5f_marker="[I] smp: S5f OK: run-any placement covered scheduler CPUs"
  else
    pair_marker="[I] smp: S2h OK: coproc pair dispatch CPU0 fallback"
    s5b_marker="[I] smp: S5b OK: EL0 scheduler placement CPU0 fallback"
    s5c_marker="[I] smp: S5c OK: repeated EL0 placement stress CPU0 fallback"
    s5d_marker="[I] smp: S5d OK: EL0 fanout CPU0 fallback"
    s5e_marker="[I] smp: S5e OK: shared-address-space thread fanout CPU0 fallback"
    s5f_marker="[I] smp: S5f OK: run-any placement CPU0 fallback"
  fi
  pair_telemetry_line="$(grep -nF "$pair_marker" "$LOG" | head -1 | cut -d: -f1)"
  s5b_demo_line="$(grep -nF "S5b OK: three EL0 processes ran with scheduler placement" "$LOG" | head -1 | cut -d: -f1)"
  s5b_telemetry_line="$(grep -nF "$s5b_marker" "$LOG" | head -1 | cut -d: -f1)"
  s5c_demo_line="$(grep -nF "S5c OK: repeated EL0 placement stress completed" "$LOG" | head -1 | cut -d: -f1)"
  s5c_telemetry_line="$(grep -nF "$s5c_marker" "$LOG" | head -1 | cut -d: -f1)"
  s5d_demo_line="$(grep -nF "S5d OK: EL0 fanout ran across scheduler CPUs" "$LOG" | head -1 | cut -d: -f1)"
  s5d_telemetry_line="$(grep -nF "$s5d_marker" "$LOG" | head -1 | cut -d: -f1)"
  s5e_demo_line="$(grep -nF "S5e OK: shared-address-space thread fanout completed" "$LOG" | head -1 | cut -d: -f1)"
  s5e_telemetry_line="$(grep -nF "$s5e_marker" "$LOG" | head -1 | cut -d: -f1)"
  s5f_demo_line="$(grep -nF "S5f OK: run-any placement policy completed" "$LOG" | head -1 | cut -d: -f1)"
  s5f_telemetry_line="$(grep -nF "$s5f_marker" "$LOG" | head -1 | cut -d: -f1)"
  kernel_demo_line="$(grep -nF "[I] sched: M4.5 sched: real context switch OK" "$LOG" | head -1 | cut -d: -f1)"
  no_secondary_kernel_line="$(grep -nF "[I] smp: S2c OK: no secondary kernel scheduler execution" "$LOG" | head -1 | cut -d: -f1)"
  quiesced_line="$(grep -nF "[I] smp: S2h OK: process scheduler quiesced after multi-CPU dispatch" "$LOG" | head -1 | cut -d: -f1)"
  gate_closed_line="$(grep -nF "[I] smp: S2h OK: secondary EL0 gate closed after restricted dispatch" "$LOG" | head -1 | cut -d: -f1)"
  s3a_mask_line="$(grep -nF "[I] smp: S3a OK: address-space CPU masks matched dispatch CPUs" "$LOG" | head -1 | cut -d: -f1)"
  s3b_ipi_line="$(grep -nF "[I] smp: S3b OK: IPI delivery stayed scheduler-safe" "$LOG" | head -1 | cut -d: -f1)"
  s3c_tlb_line="$(grep -nF "[I] smp: S3c OK: TLB shootdown path stayed scheduler-safe" "$LOG" | head -1 | cut -d: -f1)"
  s3d_tlb_line="$(grep -nF "[I] smp: S3d OK: address-space TLB flush matched dispatch CPUs" "$LOG" | head -1 | cut -d: -f1)"
  s4a_pmm_line="$(grep -nF "[I] smp: S4a OK: PMM lock boundary stayed balanced" "$LOG" | head -1 | cut -d: -f1)"
  s4b_vfs_line="$(grep -nF "[I] smp: S4b OK: VFS lock boundary stayed balanced" "$LOG" | head -1 | cut -d: -f1)"
  s4c_heap_line="$(grep -nF "[I] smp: S4c OK: kernel heap lock boundary stayed balanced" "$LOG" | head -1 | cut -d: -f1)"
  s4d_pkg_line="$(grep -nF "[I] smp: S4d OK: package-store lock boundary stayed balanced" "$LOG" | head -1 | cut -d: -f1)"
  s4e_net_line="$(grep -nF "[I] smp: S4e OK: network lock boundary stayed balanced" "$LOG" | head -1 | cut -d: -f1)"
  if [[ -z "$userland_line" || -z "$quiesced_line" ||
        "$userland_line" -ge "$quiesced_line" ]]; then
    echo "FAIL: S2 scheduler-quiesced marker must appear after the Swift ps userland marker." >&2
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
    echo "FAIL: S2 coproc multi-CPU marker must appear after the coproc pair and before Swift ps." >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
  fi
  if [[ -z "$s5b_demo_line" || -z "$s5b_telemetry_line" ||
        "$pair_telemetry_line" -ge "$s5b_demo_line" ||
        "$s5b_demo_line" -ge "$s5b_telemetry_line" ||
        "$s5b_telemetry_line" -ge "$userland_line" ]]; then
    echo "FAIL: S5b placement marker must appear after the S2h pair marker and before Swift ps." >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
  fi
  if [[ -z "$s5c_demo_line" || -z "$s5c_telemetry_line" ||
        "$s5b_telemetry_line" -ge "$s5c_demo_line" ||
        "$s5c_demo_line" -ge "$s5c_telemetry_line" ||
        "$s5c_telemetry_line" -ge "$userland_line" ]]; then
    echo "FAIL: S5c placement-stress marker must appear after S5b and before Swift ps." >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
  fi
  if [[ -z "$s5d_demo_line" || -z "$s5d_telemetry_line" ||
        "$s5c_telemetry_line" -ge "$s5d_demo_line" ||
        "$s5d_demo_line" -ge "$s5d_telemetry_line" ||
        "$s5d_telemetry_line" -ge "$userland_line" ]]; then
    echo "FAIL: S5d fanout marker must appear after S5c and before Swift ps." >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
  fi
  if [[ -z "$s5e_demo_line" || -z "$s5e_telemetry_line" ||
        "$s5d_telemetry_line" -ge "$s5e_demo_line" ||
        "$s5e_demo_line" -ge "$s5e_telemetry_line" ||
        "$s5e_telemetry_line" -ge "$userland_line" ]]; then
    echo "FAIL: S5e thread-fanout marker must appear after S5d and before Swift ps." >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
  fi
  if [[ -z "$s5f_demo_line" || -z "$s5f_telemetry_line" ||
        "$s5e_telemetry_line" -ge "$s5f_demo_line" ||
        "$s5f_demo_line" -ge "$s5f_telemetry_line" ||
        "$s5f_telemetry_line" -ge "$userland_line" ]]; then
    echo "FAIL: S5f run-any marker must appear after S5e and before Swift ps." >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
  fi
  if [[ -z "$gate_closed_line" || "$quiesced_line" -ge "$gate_closed_line" ]]; then
    echo "FAIL: S2h gate-closed marker must appear after the scheduler-quiesced marker." >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
  fi
  if [[ -z "$s3a_mask_line" || "$gate_closed_line" -ge "$s3a_mask_line" ]]; then
    echo "FAIL: S3a address-space mask marker must appear after S2h gate closure." >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
  fi
  if [[ -z "$s3b_ipi_line" || "$s3a_mask_line" -ge "$s3b_ipi_line" ]]; then
    echo "FAIL: S3b IPI scheduler-safe marker must appear after S3a." >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
  fi
  if [[ -z "$s3c_tlb_line" || "$s3b_ipi_line" -ge "$s3c_tlb_line" ]]; then
    echo "FAIL: S3c TLB shootdown marker must appear after S3b." >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
  fi
  if [[ -z "$s3d_tlb_line" || "$s3c_tlb_line" -ge "$s3d_tlb_line" ]]; then
    echo "FAIL: S3d address-space TLB flush marker must appear after S3c." >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
  fi
  if [[ -z "$s4a_pmm_line" || "$s3d_tlb_line" -ge "$s4a_pmm_line" ]]; then
    echo "FAIL: S4a PMM lock boundary marker must appear after S3d." >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
  fi
  if [[ -z "$s4b_vfs_line" || "$s4a_pmm_line" -ge "$s4b_vfs_line" ]]; then
    echo "FAIL: S4b VFS lock boundary marker must appear after S4a." >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
  fi
  if [[ -z "$s4c_heap_line" || "$s4b_vfs_line" -ge "$s4c_heap_line" ]]; then
    echo "FAIL: S4c kernel heap lock boundary marker must appear after S4b." >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
  fi
  if [[ -z "$s4d_pkg_line" || "$s4c_heap_line" -ge "$s4d_pkg_line" ]]; then
    echo "FAIL: S4d package-store lock boundary marker must appear after S4c." >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
  fi
  if [[ -z "$s4e_net_line" || "$s4d_pkg_line" -ge "$s4e_net_line" ]]; then
    echo "FAIL: S4e network lock boundary marker must appear after S4d." >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
  fi

  echo "PASS: SMP boot smoke produced expected S1/S2a-S2h/S3a-S3d/S4a-S4e/S5a-S5f markers with -smp $SMP_CPU_COUNT:"
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
