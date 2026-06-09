#!/usr/bin/env bash
# smp_release_guard_test.sh - S1 guard: secondary release stays explicit.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
BOOT_OBJ="$ROOT/build/boot.o"
BOOT_SRC="$ROOT/kernel/arch/aarch64/boot.S"
IO_HDR="$ROOT/kernel/arch/aarch64/io.h"
SECONDARY_SWIFT="$ROOT/kernel/smp/secondary.swift"
OBJDUMP="${LLVM_OBJDUMP:-/opt/homebrew/opt/llvm/bin/llvm-objdump}"

[[ -x "$OBJDUMP" ]] || { echo "FAIL: llvm-objdump not found at $OBJDUMP" >&2; exit 2; }
[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL not found - run 'make build' first." >&2; exit 2; }
[[ -f "$BOOT_OBJ" ]] || { echo "FAIL: $BOOT_OBJ not found - run 'make build' first." >&2; exit 2; }
[[ -f "$BOOT_SRC" ]] || { echo "FAIL: $BOOT_SRC missing." >&2; exit 2; }

kernel_disasm="$("$OBJDUMP" -d "$KERNEL")"
boot_disasm="$("$OBJDUMP" -d "$BOOT_OBJ")"

if ! grep -E '^[[:space:]]*[0-9a-f]+:.*[[:space:]](hvc|smc)([[:space:]]|$)' <<<"$kernel_disasm" >/dev/null; then
  echo "FAIL: S1 kernel does not contain a PSCI hvc/smc call for CPU_ON." >&2
  exit 1
fi

if ! grep -q '^smp_secondary_entry:' "$BOOT_SRC"; then
  echo "FAIL: boot.S does not define the explicit S1 smp_secondary_entry target." >&2
  exit 1
fi

if ! grep -E '^[[:space:]]*[0-9a-f]+:.*[[:space:]]br[[:space:]]+x4' <<<"$boot_disasm" >/dev/null; then
  echo "FAIL: parked secondary mailbox path does not branch to the published entry." >&2
  exit 1
fi

if ! grep -q 'bl[[:space:]]*mmu_configure_translation' "$BOOT_SRC" ||
   ! grep -q 'bl[[:space:]]*mmu_enable_sctlr' "$BOOT_SRC" ||
   ! grep -q 'bl[[:space:]]*smp_secondary_main' "$BOOT_SRC"; then
  echo "FAIL: S1 secondary entry must enable the kernel MMU path before Swift." >&2
  exit 1
fi

if ! grep -q 'smp_secondary_prepare_release' "$IO_HDR" ||
   ! grep -q '__ATOMIC_RELEASE' "$IO_HDR"; then
  echo "FAIL: mailbox release helper must publish the flag with release ordering." >&2
  exit 1
fi

if ! grep -q 'psci_cpu_on_hvc' "$SECONDARY_SWIFT" ||
   ! grep -q 'psci_cpu_on_smc' "$SECONDARY_SWIFT"; then
  echo "FAIL: S1 Swift release path must use the DTB-selected PSCI method." >&2
  exit 1
fi

if rg -n 'schedulerInit|schedYield|processInit|processRun|vfsInit|virtio' "$SECONDARY_SWIFT" >/dev/null; then
  echo "FAIL: S1 secondary path touched scheduler/process/VFS/driver work; leave that for S2+." >&2
  exit 1
fi

echo "PASS: S1 secondary release contract holds (PSCI CPU_ON + mailbox entry + early timer path only)"
