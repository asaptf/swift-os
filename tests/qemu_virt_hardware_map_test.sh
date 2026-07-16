#!/usr/bin/env bash
# qemu_virt_hardware_map_test.sh - QEMU virt hardware-map stability guard.
#
# Dump fresh QEMU virt DTBs and verify the board facts SwiftOS relies on before
# boot: PL011 serial routing, GICv2, generic timer PPI flags, PSCI/topology, and
# the contiguous virtio-mmio transport bank. This complements fdt_test.swift,
# which validates the kernel's parser view of the same DTB.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
QEMU="${QEMU:-qemu-system-aarch64}"
HOST_SWIFTC="${HOST_SWIFTC:-/usr/bin/swiftc}"
FDT_TEST="${FDT_TEST:-$BUILD/fdt_test}"
DTC="${DTC:-dtc}"

mkdir -p "$BUILD"
command -v "$DTC" >/dev/null || {
  echo "FAIL: dtc not found; needed for QEMU virt hardware-map validation." >&2
  exit 2
}

if [[ ! -x "$FDT_TEST" ]]; then
  "$HOST_SWIFTC" "$ROOT/tests/fdt_test.swift" \
    "$ROOT/kernel/arch/aarch64/fdt.swift" \
    -o "$FDT_TEST"
fi

if [[ -n "${QEMU_VIRT_HW_CPUS:-}" ]]; then
  read -r -a cpus <<<"$QEMU_VIRT_HW_CPUS"
else
  cpus=(1 4)
fi

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_fixed() {
  local file="$1" needle="$2" message="$3"
  grep -qF "$needle" "$file" || fail "$message"
}

require_regex() {
  local file="$1" regex="$2" message="$3"
  grep -Eq "$regex" "$file" || fail "$message"
}

count_regex() {
  local file="$1" regex="$2"
  grep -Ec "$regex" "$file" 2>/dev/null || true
}

for cpu in "${cpus[@]}"; do
  if [[ ! "$cpu" =~ ^[0-9]+$ ]] || (( 10#$cpu < 1 || 10#$cpu > 8 )); then
    fail "QEMU_VIRT_HW_CPUS entries must be 1..8, got '$cpu'."
  fi

  cpu_count=$((10#$cpu))
  dtb="$BUILD/qemu-virt-hardware-smp-${cpu_count}.dtb"
  dts="$BUILD/qemu-virt-hardware-smp-${cpu_count}.dts"
  tmp="$dtb.tmp.$$"
  rm -f "$tmp"
  "$QEMU" -M "virt,dumpdtb=$tmp" -cpu cortex-a72 -smp "$cpu_count" -m 256M -nographic >/dev/null 2>&1
  mv "$tmp" "$dtb"

  "$FDT_TEST" "$dtb" "$cpu_count" >/dev/null
  "$DTC" -I dtb -O dts "$dtb" >"$dts" 2>/dev/null

  require_fixed "$dts" 'stdout-path = "/pl011@9000000";' \
    "QEMU virt -smp $cpu_count should route stdout to PL011 @ 0x09000000."
  require_fixed "$dts" 'serial0 = "/pl011@9000000";' \
    "QEMU virt -smp $cpu_count should advertise serial0 as PL011 @ 0x09000000."
  require_fixed "$dts" "pl011@9000000 {" \
    "QEMU virt -smp $cpu_count missing PL011 node."
  require_fixed "$dts" 'compatible = "arm,pl011", "arm,primecell";' \
    "QEMU virt -smp $cpu_count PL011 compatible changed."
  require_fixed "$dts" "reg = <0x00 0x9000000 0x00 0x1000>;" \
    "QEMU virt -smp $cpu_count PL011 MMIO range changed."
  require_fixed "$dts" "interrupts = <0x00 0x01 0x04>;" \
    "QEMU virt -smp $cpu_count PL011 interrupt spec changed."

  require_fixed "$dts" "intc@8000000 {" \
    "QEMU virt -smp $cpu_count missing GICv2 node."
  require_fixed "$dts" 'compatible = "arm,cortex-a15-gic";' \
    "QEMU virt -smp $cpu_count GIC compatible changed."
  require_fixed "$dts" "reg = <0x00 0x8000000 0x00 0x10000 0x00 0x8010000 0x00 0x10000>;" \
    "QEMU virt -smp $cpu_count GIC distributor/CPU-interface ranges changed."
  require_regex "$dts" '^[[:space:]]*interrupt-controller;$' \
    "QEMU virt -smp $cpu_count GIC node should be an interrupt controller."

  timer_flags="$(printf '0x%x' "$(((((1 << cpu_count) - 1) << 8) | 4))")"
  # dtc multi-string formatting differs by version (comma-separated vs \0-escaped).
  require_fixed "$dts" 'arm,armv8-timer' \
    "QEMU virt -smp $cpu_count generic timer compatible missing arm,armv8-timer."
  require_fixed "$dts" 'arm,armv7-timer' \
    "QEMU virt -smp $cpu_count generic timer compatible missing arm,armv7-timer."
  require_fixed "$dts" "interrupts = <0x01 0x0d $timer_flags 0x01 0x0e $timer_flags" \
    "QEMU virt -smp $cpu_count timer PPI flags should include physical INTID 30 with $timer_flags."

  require_fixed "$dts" 'method = "hvc";' \
    "QEMU virt -smp $cpu_count PSCI method changed."
  require_fixed "$dts" "cpu_on = <0xc4000003>;" \
    "QEMU virt -smp $cpu_count PSCI CPU_ON function changed."

  cpu_nodes="$(count_regex "$dts" '^[[:space:]]*cpu@[0-9a-f]+[[:space:]]*\{')"
  [[ "$cpu_nodes" == "$cpu_count" ]] || \
    fail "QEMU virt -smp $cpu_count should expose $cpu_count CPU nodes, got $cpu_nodes."
  if (( cpu_count > 1 )); then
    enable_methods="$(count_regex "$dts" 'enable-method = "psci";')"
    [[ "$enable_methods" == "$cpu_count" ]] || \
      fail "QEMU virt -smp $cpu_count should expose PSCI enable-method on each CPU, got $enable_methods."
  fi

  virtio_nodes="$(count_regex "$dts" '^[[:space:]]*virtio_mmio@')"
  [[ "$virtio_nodes" == 32 ]] || \
    fail "QEMU virt -smp $cpu_count should expose 32 virtio-mmio slots, got $virtio_nodes."
  slot=0
  while (( slot < 32 )); do
    base=$((0x0A000000 + slot * 0x200))
    irq=$((0x10 + slot))
    base_hex="$(printf '%x' "$base")"
    irq_hex="$(printf '%x' "$irq")"
    require_fixed "$dts" "virtio_mmio@$base_hex {" \
      "QEMU virt -smp $cpu_count missing virtio-mmio slot $slot at 0x$base_hex."
    require_fixed "$dts" "reg = <0x00 0x$base_hex 0x00 0x200>;" \
      "QEMU virt -smp $cpu_count virtio-mmio slot $slot range changed."
    require_fixed "$dts" "interrupts = <0x00 0x$irq_hex 0x01>;" \
      "QEMU virt -smp $cpu_count virtio-mmio slot $slot IRQ changed."
    slot=$((slot + 1))
  done
done

echo "PASS: QEMU virt hardware map validated for -smp ${cpus[*]} (PL011/GIC/timer/PSCI/virtio-mmio)"
