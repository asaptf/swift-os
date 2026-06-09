#!/usr/bin/env bash
# smp_release_guard_test.sh - S1 guard: secondary release stays explicit.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
BOOT_OBJ="$ROOT/build/boot.o"
BOOT_SRC="$ROOT/kernel/arch/aarch64/boot.S"
IO_HDR="$ROOT/kernel/arch/aarch64/io.h"
MAIN_SWIFT="$ROOT/kernel/main.swift"
PERCPU_SWIFT="$ROOT/kernel/smp/percpu.swift"
SECONDARY_SWIFT="$ROOT/kernel/smp/secondary.swift"
PROCESS_SWIFT="$ROOT/kernel/user/process.swift"
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

if rg -n 'schedulerInit|schedYield|processInit|processRun|vfsInit|virtio|processOnTick|yieldToScheduler|cpu_switch_context|address_space_switch|smpSetCurrentProcessForCurrentCpu|smpSetProcessSchedulerContextForCurrentCpu|smpRecordEl0SwitchForCurrentCpu|user_thread_launch|trap_return' "$SECONDARY_SWIFT" >/dev/null; then
  echo "FAIL: S1/S2b secondary path touched scheduler/process/VFS/driver work; leave that for S2+." >&2
  exit 1
fi

for needle in \
  'smpSecondariesRemainSchedulerIdle' \
  'smpLogS2ReadinessMarkers' \
  'smpS2ReadinessSelfTest'; do
  if ! grep -q "$needle" "$SECONDARY_SWIFT"; then
    echo "FAIL: S2a readiness guard missing $needle in secondary bring-up contract." >&2
    exit 1
  fi
done

for needle in \
  'smpPerCpuHasCurrentThread' \
  'smpPerCpuProcessIdle' \
  'smpPerCpuSchedulerIdle'; do
  if ! grep -q "$needle" "$PERCPU_SWIFT"; then
    echo "FAIL: S2a per-CPU readiness accessor missing $needle." >&2
    exit 1
  fi
done

if ! grep -q 'smpSetCurrentProcessForCurrentCpu(Int32(s))' "$PROCESS_SWIFT" ||
   ! grep -q 'smpSetCurrentProcessForCurrentCpu(-1)' "$PROCESS_SWIFT"; then
  echo "FAIL: S2a requires the EL0 scheduler loop to mirror currentProc into per-CPU state." >&2
  exit 1
fi

for needle in \
  'private var schedCtx: UnsafeMutablePointer<CPUContext>! = nil  // [smpMaxCpuCount()]' \
  'private var schedCtxCpuCount: UInt32 = 0' \
  'processSchedulerCpuIndex' \
  'schedulerContextForCurrentCpu' \
  'processSchedulerContextSelfTest'; do
  if ! grep -Fq "$needle" "$PROCESS_SWIFT"; then
    echo "FAIL: S2b process scheduler context scaffold missing: $needle." >&2
    exit 1
  fi
done

if grep -Fq 'schedCtx = s.bindMemory(to: CPUContext.self, capacity: 1)' "$PROCESS_SWIFT" ||
   grep -Fq 'cpu_switch_context(UnsafeMutableRawPointer(schedCtx),' "$PROCESS_SWIFT" ||
   grep -Fq 'UnsafeMutableRawPointer(schedCtx))' "$PROCESS_SWIFT"; then
  echo "FAIL: S2b must not keep using a singleton process scheduler context." >&2
  exit 1
fi

if ! grep -q 'cpu != 0 || cpu >= schedCtxCpuCount' "$PROCESS_SWIFT" ||
   ! grep -q 'processOnTick entered on non-owner CPU' "$PROCESS_SWIFT"; then
  echo "FAIL: S2b process scheduler paths must panic if entered from a non-owner CPU." >&2
  exit 1
fi

if ! grep -q 'interruptId == physicalTimerIrq && currentCpuId() == 0' "$MAIN_SWIFT" ||
   ! grep -q 'processOnTick(fromEL0: fromEL0)' "$MAIN_SWIFT"; then
  echo "FAIL: S2b requires irqHandler to keep processOnTick gated to CPU0." >&2
  exit 1
fi

sched_line="$(rg -n '^[[:space:]]*schedulerInit\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
proc_line="$(rg -n '^[[:space:]]*processInit\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s2a_line="$(rg -n 'smpS2ReadinessSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s2b_line="$(rg -n 'processSchedulerContextSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
if [[ -z "$sched_line" || -z "$proc_line" || -z "$s2a_line" ||
      "$sched_line" -ge "$proc_line" || "$proc_line" -ge "$s2a_line" ]]; then
  echo "FAIL: S2a scheduler readiness self-test must run after schedulerInit and processInit." >&2
  exit 1
fi
if [[ -z "$s2b_line" || "$s2a_line" -ge "$s2b_line" ]]; then
  echo "FAIL: S2b process scheduler context self-test must run after the S2a scheduler readiness check." >&2
  exit 1
fi

echo "PASS: S1/S2a/S2b release-readiness contract holds (PSCI CPU_ON + early timer + scheduler boundary)"
