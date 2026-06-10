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
SCHED_SWIFT="$ROOT/kernel/sched/scheduler.swift"
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

if rg -n 'schedulerInit|schedYield|processInit|processRun|vfsInit|virtio|processOnTick|yieldToScheduler|cpu_switch_context|address_space_switch|smpSetCurrentProcessForCurrentCpu|smpSetProcessSchedulerContextForCurrentCpu|smpRecordEl0SwitchForCurrentCpu|smpMarkKernelSchedulerReadyForCurrentCpu|smpRecordKernelSchedulerActivityForCurrentCpu|user_thread_launch|trap_return' "$SECONDARY_SWIFT" >/dev/null; then
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

for needle in \
  'smpSetProcessRunQueueForCurrentCpu' \
  'smpPerCpuProcessRunQueueIdle' \
  'smpPerCpuProcessRunQueueHead' \
  'smpPerCpuProcessRunQueueTail'; do
  if ! grep -q "$needle" "$PERCPU_SWIFT"; then
    echo "FAIL: S2d per-CPU process run queue mirror missing $needle." >&2
    exit 1
  fi
done

for needle in \
  'private var pHomeCpu = \[UInt32\]' \
  'private var pRunNext = \[Int32\]' \
  'private var pRunQueued = \[Bool\]' \
  'private var processRunQueueHead = \[Int32\]' \
  'private var processRunQueueTail = \[Int32\]' \
  'private var processRunQueueEnqueueCount = \[UInt64\]' \
  'private var processRunQueueDispatchCount = \[UInt64\]' \
  'markProcessReady' \
  'processHomeCpuForNewReadySlot' \
  'processRunQueueScaffoldSelfTest' \
  'processRunQueueNoSecondaryExecutionSelfTest'; do
  if ! grep -q "$needle" "$PROCESS_SWIFT"; then
    echo "FAIL: S2d process scheduler run queue scaffold missing $needle." >&2
    exit 1
  fi
done

if grep -q 'private var rrCursor' "$PROCESS_SWIFT" ||
   grep -q 'for step in 1...maxProc' "$PROCESS_SWIFT"; then
  echo "FAIL: S2d must not retain the old scan/rrCursor EL0 scheduler path." >&2
  exit 1
fi

ready_assignments="$(rg -n 'pState\[[^]]+\][[:space:]]*=[[:space:]]*pReady' "$PROCESS_SWIFT" || true)"
ready_assignment_count="$(rg -c 'pState\[[^]]+\][[:space:]]*=[[:space:]]*pReady' "$PROCESS_SWIFT" || true)"
ready_assignment_count="${ready_assignment_count:-0}"
if [[ "$ready_assignment_count" != "1" ]]; then
  echo "FAIL: S2d requires pReady transitions to go through markProcessReady; found:" >&2
  echo "$ready_assignments" >&2
  exit 1
fi

if ! grep -q 'cpu != 0 || cpu >= schedCtxCpuCount' "$PROCESS_SWIFT" ||
   ! grep -q 'processOnTick entered on non-owner CPU' "$PROCESS_SWIFT"; then
  echo "FAIL: S2b process scheduler paths must panic if entered from a non-owner CPU." >&2
  exit 1
fi

cpu0_timer_block="$(sed -n '/if interruptId == physicalTimerIrq && currentCpuId() == 0 {/,/} else if interruptId == uartIrqId {/p' "$MAIN_SWIFT")"
if [[ -z "$cpu0_timer_block" ]] ||
   ! grep -q 'schedulerTick()' <<<"$cpu0_timer_block" ||
   ! grep -q 'processOnTick(fromEL0: fromEL0)' <<<"$cpu0_timer_block"; then
  echo "FAIL: S2b/S2c requires irqHandler to keep schedulerTick/processOnTick gated to CPU0." >&2
  exit 1
fi

for needle in \
  'smpCpuFlagKernelSchedulerReady' \
  'kernelSchedulerActivityCount' \
  'smpMarkKernelSchedulerReadyForCurrentCpu' \
  'smpRecordKernelSchedulerActivityForCurrentCpu' \
  'smpPerCpuKernelSchedulerReady' \
  'smpPerCpuKernelSchedulerActivityCount' \
  'smpPerCpuCurrentThreadIs'; do
  if ! grep -q "$needle" "$PERCPU_SWIFT"; then
    echo "FAIL: S2c per-CPU kernel scheduler ownership state missing $needle." >&2
    exit 1
  fi
done

for needle in \
  'schedulerCpuIndex' \
  'kernelSchedulerOwnershipSelfTest' \
  'smpMarkKernelSchedulerReadyForCurrentCpu()' \
  'smpRecordKernelSchedulerActivityForCurrentCpu()' \
  'smpPerCpuCurrentThreadIs(0, 0)'; do
  if ! grep -q "$needle" "$SCHED_SWIFT"; then
    echo "FAIL: S2c kernel scheduler owner guard missing $needle." >&2
    exit 1
  fi
done

schedule_line="$(rg -n '^private func schedule\(\)' "$SCHED_SWIFT" | head -1 | cut -d: -f1)"
schedule_owner_line="$(awk -v start="$schedule_line" 'NR > start && /schedulerCpuIndex/ { print NR; exit }' "$SCHED_SWIFT")"
schedule_ready_line="$(awk -v start="$schedule_line" 'NR > start && /if !schedulerReady/ { print NR; exit }' "$SCHED_SWIFT")"
sched_yield_line="$(rg -n '^func schedYield\(\)' "$SCHED_SWIFT" | head -1 | cut -d: -f1)"
sched_yield_owner_line="$(awk -v start="$sched_yield_line" 'NR > start && /schedulerCpuIndex/ { print NR; exit }' "$SCHED_SWIFT")"
sched_yield_ready_line="$(awk -v start="$sched_yield_line" 'NR > start && /if !schedulerReady/ { print NR; exit }' "$SCHED_SWIFT")"
scheduler_tick_line="$(rg -n '^func schedulerTick\(\)' "$SCHED_SWIFT" | head -1 | cut -d: -f1)"
scheduler_tick_owner_line="$(awk -v start="$scheduler_tick_line" 'NR > start && /schedulerCpuIndex/ { print NR; exit }' "$SCHED_SWIFT")"
sched_done_line="$(rg -n '^func schedAllThreadsDone\(\)' "$SCHED_SWIFT" | head -1 | cut -d: -f1)"
sched_done_owner_line="$(awk -v start="$sched_done_line" 'NR > start && /schedulerCpuIndex/ { print NR; exit }' "$SCHED_SWIFT")"
if [[ -z "$schedule_line" || -z "$schedule_owner_line" || -z "$schedule_ready_line" ||
      "$schedule_owner_line" -ge "$schedule_ready_line" ||
      -z "$sched_yield_line" || -z "$sched_yield_owner_line" || -z "$sched_yield_ready_line" ||
      "$sched_yield_owner_line" -ge "$sched_yield_ready_line" ||
      -z "$scheduler_tick_line" || -z "$scheduler_tick_owner_line" ||
      -z "$sched_done_line" || -z "$sched_done_owner_line" ]]; then
  echo "FAIL: S2c scheduler APIs must check the CPU0 owner before scheduler work or readiness returns." >&2
  exit 1
fi

if ! grep -q 'cpu != 0 || cpu >= smpMaxCpuCount()' "$SCHED_SWIFT" ||
   ! grep -q 'kernel scheduler entered on non-owner CPU' "$SCHED_SWIFT"; then
  echo "FAIL: S2c kernel scheduler paths must panic if entered from a non-owner CPU." >&2
  exit 1
fi

if ! grep -q 'smpS2cKernelSchedulerReadinessSelfTest' "$SECONDARY_SWIFT" ||
   ! grep -q 'smpS2cNoSecondaryKernelSchedulerExecution' "$SECONDARY_SWIFT" ||
   ! grep -q 'S2c OK: no secondary kernel scheduler execution' "$MAIN_SWIFT"; then
  echo "FAIL: S2c must verify no secondary CPU ran kernel scheduler work after the scheduler demo." >&2
  exit 1
fi

if ! grep -q 'S2d OK: process run queue scaffold ready' "$MAIN_SWIFT" ||
   ! grep -q 'S2d OK: process run queue stayed CPU0-owned' "$MAIN_SWIFT"; then
  echo "FAIL: S2d must log process run queue scaffold and CPU0-owned acceptance markers." >&2
  exit 1
fi

sched_line="$(rg -n '^[[:space:]]*schedulerInit\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s2c_owner_line="$(rg -n 'kernelSchedulerOwnershipSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
proc_line="$(rg -n '^[[:space:]]*processInit\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s2a_line="$(rg -n 'smpS2ReadinessSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s2b_line="$(rg -n 'processSchedulerContextSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s2d_line="$(rg -n 'processRunQueueScaffoldSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
demo_line="$(rg -n '^[[:space:]]*runSchedulerDemo\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s2c_no_secondary_line="$(rg -n 'smpS2cNoSecondaryKernelSchedulerExecution\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
process_demo_line="$(rg -n '^[[:space:]]*runProcessDemo\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
runps_line="$(rg -n '^[[:space:]]*runPsDemo\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s2d_no_secondary_line="$(rg -n 'processRunQueueNoSecondaryExecutionSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s2b_no_secondary_line="$(rg -n 'smpS2bNoSecondaryEl0Execution\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
if [[ -z "$sched_line" || -z "$s2c_owner_line" || -z "$proc_line" || -z "$s2a_line" ||
      "$sched_line" -ge "$s2c_owner_line" || "$s2c_owner_line" -ge "$proc_line" ||
      "$proc_line" -ge "$s2a_line" ]]; then
  echo "FAIL: S2c/S2a scheduler readiness self-tests must run in schedulerInit -> S2c -> processInit -> S2a order." >&2
  exit 1
fi
if [[ -z "$s2b_line" || "$s2a_line" -ge "$s2b_line" ]]; then
  echo "FAIL: S2b process scheduler context self-test must run after the S2a scheduler readiness check." >&2
  exit 1
fi
if [[ -z "$s2d_line" || "$s2b_line" -ge "$s2d_line" ]]; then
  echo "FAIL: S2d process run queue scaffold self-test must run after the S2b context scaffold." >&2
  exit 1
fi
if [[ -z "$demo_line" || -z "$s2c_no_secondary_line" || -z "$process_demo_line" ||
      "$demo_line" -ge "$s2c_no_secondary_line" ||
      "$s2c_no_secondary_line" -ge "$process_demo_line" ]]; then
  echo "FAIL: S2c no-secondary-kernel guard must run after the kernel scheduler demo and before EL0 demos." >&2
  exit 1
fi
if [[ -z "$runps_line" || -z "$s2d_no_secondary_line" || -z "$s2b_no_secondary_line" ||
      "$runps_line" -ge "$s2d_no_secondary_line" ||
      "$s2d_no_secondary_line" -ge "$s2b_no_secondary_line" ]]; then
  echo "FAIL: S2d run queue CPU0-owned guard must run after Swift ps and before S2b no-secondary-EL0." >&2
  exit 1
fi

echo "PASS: S1/S2a/S2b/S2c/S2d release-readiness contract holds (PSCI CPU_ON + early timer + scheduler boundary)"
