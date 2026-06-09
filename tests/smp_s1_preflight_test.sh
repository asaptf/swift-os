#!/usr/bin/env bash
# smp_s1_preflight_test.sh - S0j: DTB preflight for the reviewed S1 bring-up.
#
# This is deliberately not a secondary-release test. It dumps fresh QEMU virt
# DTBs for the core counts S1 will care about and runs the pure host FDT parser
# against them, proving the advertised topology/PSCI/GIC/timer facts before
# any CPU_ON/HVC/SMC path is added.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
QEMU="${QEMU:-qemu-system-aarch64}"
HOST_SWIFTC="${HOST_SWIFTC:-/usr/bin/swiftc}"
FDT_TEST="${FDT_TEST:-$BUILD/fdt_test}"
DTC="${DTC:-dtc}"

mkdir -p "$BUILD"
command -v "$DTC" >/dev/null || { echo "FAIL: dtc not found; needed for S1 timer-PPI preflight." >&2; exit 2; }

if [[ ! -x "$FDT_TEST" ]]; then
  "$HOST_SWIFTC" "$ROOT/tests/fdt_test.swift" \
    "$ROOT/kernel/arch/aarch64/fdt.swift" \
    -o "$FDT_TEST"
fi

if [[ -n "${SMP_S1_PREFLIGHT_CPUS:-}" ]]; then
  read -r -a cpus <<<"$SMP_S1_PREFLIGHT_CPUS"
else
  cpus=(1 2 4 8)
fi

for cpu in "${cpus[@]}"; do
  if [[ ! "$cpu" =~ ^[0-9]+$ ]] || (( 10#$cpu < 1 || 10#$cpu > 8 )); then
    echo "FAIL: S1 preflight CPU count must be 1..8, got '$cpu'." >&2
    exit 2
  fi

  dtb="$BUILD/virt-s1-preflight-smp-${cpu}.dtb"
  tmp="$dtb.tmp.$$"
  rm -f "$tmp"
  "$QEMU" -M "virt,dumpdtb=$tmp" -cpu cortex-a72 -smp "$cpu" -m 256M -nographic >/dev/null 2>&1
  mv "$tmp" "$dtb"
  "$FDT_TEST" "$dtb" "$cpu"

  timer="$("$DTC" -I dtb -O dts "$dtb" 2>/dev/null |
    sed -n '/^[[:space:]]*timer {/,/^[[:space:]]*};/p' |
    tr '\n' ' ')"
  flags="$(printf '0x%x' "$(((((1 << cpu) - 1) << 8) | 4))")"
  if [[ "$timer" != *'compatible = "arm,armv8-timer", "arm,armv7-timer"'* ]]; then
    echo "FAIL: DTB timer node for -smp $cpu does not advertise arm,armv8-timer." >&2
    echo "$timer" >&2
    exit 1
  fi
  if [[ "$timer" != *"interrupts = <0x01 0x0d $flags 0x01 0x0e $flags"* ]]; then
    echo "FAIL: DTB timer node for -smp $cpu does not expose physical timer PPI INTID 30 with flags $flags." >&2
    echo "$timer" >&2
    exit 1
  fi
done

echo "PASS: S1 DTB preflight validated QEMU virt PSCI/GIC/timer/topology facts for -smp ${cpus[*]}"
