#!/usr/bin/env bash
# smp_release_guard_test.sh - S1 guard: secondary release stays explicit.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
BOOT_OBJ="$ROOT/build/boot.o"
BOOT_SRC="$ROOT/kernel/arch/aarch64/boot.S"
IO_HDR="$ROOT/kernel/arch/aarch64/io.h"
MAIN_SWIFT="$ROOT/kernel/main.swift"
GIC_SWIFT="$ROOT/kernel/drivers/gic.swift"
PERCPU_SWIFT="$ROOT/kernel/smp/percpu.swift"
SECONDARY_SWIFT="$ROOT/kernel/smp/secondary.swift"
PROCESS_SWIFT="$ROOT/kernel/user/process.swift"
VM_SWIFT="$ROOT/kernel/mm/vm.swift"
PMM_SWIFT="$ROOT/kernel/mm/pmm.swift"
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
  'smpSetProcessSchedulerContextForCpu' \
  'smpPerCpuProcessSchedulerContext' \
  'smpSetProcessRunQueueForCpu' \
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
  'private var pLastDispatchCpu = \[UInt32\]' \
  'private var pDispatchCount = \[UInt64\]' \
  'private var pDispatchCpuMask = \[UInt64\]' \
  'private var pAddressSpaceCpuMask = \[UInt64\]' \
  'private var processRunQueueHead = \[Int32\]' \
  'private var processRunQueueTail = \[Int32\]' \
  'private var processRunQueueEnqueueCount = \[UInt64\]' \
  'private var processRunQueueDispatchCount = \[UInt64\]' \
  'private var processDispatchTelemetryCount = \[UInt64\]' \
  'private var processAddressSpaceActivationCount = \[UInt64\]' \
  'private var lastPairDispatchTelemetryValid = false' \
  'private var lastPairDispatchCountA: UInt64 = 0' \
  'private var lastPairDispatchCountB: UInt64 = 0' \
  'private var lastPairDispatchCpuMaskA: UInt64 = 0' \
  'private var lastPairDispatchCpuMaskB: UInt64 = 0' \
  'private var lastPairLastDispatchCpuA: UInt32 = unassignedCpu' \
  'private var lastPairLastDispatchCpuB: UInt32 = unassignedCpu' \
  'schedulerContextAddressForCpu' \
  'markProcessReady' \
  'processHomeCpuForNewReadySlot' \
  'recordProcessDispatch' \
  'recordProcessAddressSpaceActivation' \
  'processAddressSpaceActiveCpuMaskForSlot' \
  'processCurrentAddressSpaceActiveCpuMask' \
  'captureLastPairDispatchTelemetry' \
  'processSecondaryEl0GateEnabled' \
  'processSecondaryEl0GateAllowsCpu' \
  'processSecondaryEl0GateSelfTest' \
  'processSecondaryEl0GateHeldSelfTest' \
  'processAddressSpaceCpuMaskSelfTest' \
  'processAddressSpaceCpuMaskNoSecondarySelfTest' \
  'processAddressSpaceTlbFlushFacadeSelfTest' \
  'processAddressSpaceTlbFlushNoSecondarySelfTest' \
  'processRunQueueScaffoldSelfTest' \
  'processDormantSchedulerCpusSelfTest' \
  'processDispatchTelemetrySelfTest' \
  'processCoprocPairDispatchTelemetrySelfTest' \
  'processRunQueueNoSecondaryExecutionSelfTest' \
  'processNoSecondarySchedulerDispatchSelfTest' \
  'processDispatchTelemetryNoSecondarySelfTest'; do
  if ! grep -q "$needle" "$PROCESS_SWIFT"; then
    echo "FAIL: S2d/S2f process scheduler scaffold missing $needle." >&2
    exit 1
  fi
done

if ! grep -q 'smpSetProcessSchedulerContextForCpu(cpu, context)' "$PROCESS_SWIFT" ||
   ! grep -q 'smpSetProcessRunQueueForCpu(cpu, head: noProcessSlot, tail: noProcessSlot)' "$PROCESS_SWIFT" ||
   grep -q 'smpSetProcessSchedulerContextForCurrentCpu(UInt(bitPattern: schedCtx))' "$PROCESS_SWIFT"; then
  echo "FAIL: S2e requires processInit to publish dormant scheduler contexts and run queues for each CPU." >&2
  exit 1
fi

if grep -q 'private var rrCursor' "$PROCESS_SWIFT" ||
   grep -q 'for step in 1...maxProc' "$PROCESS_SWIFT"; then
  echo "FAIL: S2d must not retain the old scan/rrCursor EL0 scheduler path." >&2
  exit 1
fi

dispatch_record_line="$(rg -n 'recordProcessDispatch\(s, on: cpu\)' "$PROCESS_SWIFT" | head -1 | cut -d: -f1)"
el0_switch_line="$(rg -n 'smpRecordEl0SwitchForCurrentCpu\(\)' "$PROCESS_SWIFT" | head -1 | cut -d: -f1)"
if [[ -z "$dispatch_record_line" || -z "$el0_switch_line" ||
      "$dispatch_record_line" -ge "$el0_switch_line" ]]; then
  echo "FAIL: S2f dispatch telemetry must be recorded on the actual switch path before the EL0 switch counter." >&2
  exit 1
fi

if ! grep -q 'processSecondaryEl0GateAllowsCpu(cpu)' "$PROCESS_SWIFT" ||
   ! grep -q 'EL0 process dispatched on secondary before S2' "$PROCESS_SWIFT" ||
   ! grep -q 'EL0 process dispatch CPU mismatch' "$PROCESS_SWIFT" ||
   ! grep -q 'pDispatchCpuMask\[slot\]' "$PROCESS_SWIFT"; then
  echo "FAIL: S2f/S2h dispatch telemetry must keep the secondary-EL0 gate and mismatch guard." >&2
  exit 1
fi

address_switch_line="$(rg -n 'address_space_switch\(pTtbr0\[s\]\)' "$PROCESS_SWIFT" | head -1 | cut -d: -f1)"
as_mask_line="$(rg -n 'recordProcessAddressSpaceActivation\(s, on: cpu\)' "$PROCESS_SWIFT" | head -1 | cut -d: -f1)"
if [[ -z "$address_switch_line" || -z "$as_mask_line" || -z "$el0_switch_line" ||
      "$address_switch_line" -ge "$as_mask_line" ||
      "$as_mask_line" -ge "$el0_switch_line" ]]; then
  echo "FAIL: S3a address-space CPU mask must be recorded after TTBR0 switch and before EL0 switch accounting." >&2
  exit 1
fi

if ! grep -q 'address space activated on secondary before S3' "$PROCESS_SWIFT" ||
   ! grep -q 'address-space CPU mask dispatch mismatch' "$PROCESS_SWIFT" ||
   ! grep -q 'processAddressSpaceActivationCount\[Int(cpu)\]' "$PROCESS_SWIFT"; then
  echo "FAIL: S3a address-space CPU mask telemetry must keep secondary and dispatch-mismatch guards." >&2
  exit 1
fi

for needle in \
  'addressSpaceCurrentCpuTlbMask' \
  'addressSpaceFlushTlbForActiveCpuMask' \
  'addressSpaceTlbFlushFacadeSelfTest' \
  'smpRequestTlbShootdownForCpuMask(remoteMask)' \
  'addressSpaceMapForActiveCpuMask' \
  'addressSpaceMmapForActiveCpuMask' \
  'addressSpaceMapFilePageForActiveCpuMask' \
  'addressSpaceMunmapForActiveCpuMask' \
  'addressSpaceMprotectForActiveCpuMask' \
  'addressSpaceCloneForActiveCpuMask' \
  'addressSpaceHandleCowFaultForActiveCpuMask' \
  'addressSpacePrepareWriteForActiveCpuMask'; do
  if ! grep -q "$needle" "$VM_SWIFT"; then
    echo "FAIL: S3d VM TLB flush facade missing $needle." >&2
    exit 1
  fi
done

if grep -q 'address_space_mmap(pTtbr0\[me\]' "$PROCESS_SWIFT" ||
   grep -q 'address_space_munmap(pTtbr0\[me\]' "$PROCESS_SWIFT" ||
   grep -q 'address_space_mprotect(pTtbr0\[me\]' "$PROCESS_SWIFT" ||
   grep -q 'address_space_clone(pTtbr0\[parent\]' "$PROCESS_SWIFT" ||
   ! grep -q 'addressSpaceMapFilePageForActiveCpuMask' "$PROCESS_SWIFT" ||
   ! grep -q 'addressSpacePrepareWriteForActiveCpuMask' "$ROOT/kernel/user/user_access.swift" ||
   ! grep -q 'addressSpaceHandleCowFaultForActiveCpuMask' "$MAIN_SWIFT"; then
  echo "FAIL: S3d process-owned VM mutations must route through active CPU mask TLB flush helpers." >&2
  exit 1
fi

for needle in \
  'private var pmmLockWord: UInt64 = 0' \
  'private var pmmLockAcquireCount: UInt64 = 0' \
  'private var pmmLockContentionCount: UInt64 = 0' \
  'private func pmmLock() -> UInt64' \
  'let daif = irq_save()' \
  'smpAtomicCompareExchange(word, expected: &expected, desired: 1)' \
  'private func pmmUnlock(_ daif: UInt64)' \
  'irq_restore(daif)' \
  'private func pmmWithAllocator' \
  '@_cdecl("pmm_frame_release")' \
  'pmmS4aBoundedStressForCurrentCpu' \
  'pmmS4aConcurrencySelfTest' \
  'pmmS4aLockBoundaryHeldSelfTest'; do
  if ! grep -q "$needle" "$PMM_SWIFT"; then
    echo "FAIL: S4a PMM lock boundary missing $needle." >&2
    exit 1
  fi
done

direct_pmm_access="$(rg -n 'pmm[!?]\.' "$PMM_SWIFT" || true)"
if [[ -n "$direct_pmm_access" ]]; then
  echo "FAIL: S4a PMM exported operations must not access the allocator outside pmmWithAllocator." >&2
  echo "$direct_pmm_access" >&2
  exit 1
fi

if ! grep -q 'pmm_frame_release' "$IO_HDR" ||
   ! grep -q 'pmm_frame_release(pa)' "$VM_SWIFT" ||
   grep -q 'if pmm_frame_unref(pa)' "$VM_SWIFT"; then
  echo "FAIL: S4a VM user-frame release must use atomic pmm_frame_release instead of split unref/free." >&2
  exit 1
fi

for needle in \
  'smpPmmStressSelfTest' \
  'smpRequestPmmStressForCpuMask' \
  'smpS4aPmmStressSchedulerBoundarySelfTest' \
  'smpHandlePmmStressForCurrentCpu()'; do
  if ! grep -q "$needle" "$SECONDARY_SWIFT" "$MAIN_SWIFT"; then
    echo "FAIL: S4a secondary PMM stress path missing $needle." >&2
    exit 1
  fi
done

pair_capture_line="$(rg -n 'captureLastPairDispatchTelemetry\(a, b\)' "$PROCESS_SWIFT" | head -1 | cut -d: -f1)"
pair_reap_line="$(rg -n 'reapProcess\(a\)' "$PROCESS_SWIFT" | head -1 | cut -d: -f1)"
if [[ -z "$pair_capture_line" || -z "$pair_reap_line" ||
      "$pair_capture_line" -ge "$pair_reap_line" ]]; then
  echo "FAIL: S2g must capture coproc pair dispatch telemetry before processRunPair reaps the slots." >&2
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

if ! grep -q 'cpu >= schedCtxCpuCount || !processSecondaryEl0GateAllowsCpu(cpu)' "$PROCESS_SWIFT" ||
   ! grep -q 'processOnTick entered on non-owner CPU' "$PROCESS_SWIFT"; then
  echo "FAIL: S2b/S2h process scheduler paths must panic when the secondary-EL0 gate is closed." >&2
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
  'smpIpiReceivedCount' \
  'smpIpiProbeTargetMaskStorage' \
  'smpIpiProbeDeliveredMaskStorage' \
  'smpTlbShootdownRequestGeneration' \
  'smpTlbShootdownAckGeneration' \
  'smpTlbShootdownProbeTargetMaskStorage' \
  'smpTlbShootdownProbeAckMaskStorage' \
  'smpPmmStressRequestGeneration' \
  'smpPmmStressAckGeneration' \
  'smpPmmStressProbeTargetMaskStorage' \
  'smpPmmStressProbeAckMaskStorage' \
  'smpPmmStressProbeFailureMaskStorage' \
  'smpMarkKernelSchedulerReadyForCurrentCpu' \
  'smpRecordKernelSchedulerActivityForCurrentCpu' \
  'smpRecordIpiForCurrentCpu' \
  'smpPerCpuIpiReceivedCount' \
  'smpBeginTlbShootdownProbe' \
  'smpPublishTlbShootdownRequest' \
  'smpHandleTlbShootdownForCurrentCpu' \
  'smpBeginPmmStressProbe' \
  'smpPublishPmmStressRequest' \
  'smpHandlePmmStressForCurrentCpu' \
  'smpPmmStressProbeFailureMask' \
  'smpPerCpuTlbShootdownAckGeneration' \
  'smpPerCpuKernelSchedulerReady' \
  'smpPerCpuKernelSchedulerActivityCount' \
  'smpPerCpuCurrentThreadIs'; do
  if ! grep -q "$needle" "$PERCPU_SWIFT"; then
    echo "FAIL: S2c per-CPU kernel scheduler ownership state missing $needle." >&2
    exit 1
  fi
done

for needle in \
  'private let gicdSgir: UInt = 0xF00' \
  'let smpIpiInterruptId: UInt32 = 1' \
  'gicSendSoftwareGeneratedInterruptToCpu' \
  'gicSoftwareGeneratedInterruptSource' \
  'gicSoftwareGeneratedInterruptSelfTest' \
  '((targetMask & 0xFF) << 16)' \
  'smpStoreBarrier()' \
  'mmio_write32(gicdBase + gicdSgir'; do
  if ! grep -q "$needle" "$GIC_SWIFT"; then
    echo "FAIL: S3b GIC SGI substrate missing $needle." >&2
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
if ! grep -q 'S2e OK: dormant process scheduler CPUs published' "$MAIN_SWIFT" ||
   ! grep -q 'S2e OK: secondary process scheduler contexts stayed dormant' "$MAIN_SWIFT"; then
  echo "FAIL: S2e must log dormant process scheduler publication and no-secondary-dispatch markers." >&2
  exit 1
fi
if ! grep -q 'S2f OK: process dispatch telemetry ready' "$MAIN_SWIFT" ||
   ! grep -q 'S2f OK: process dispatch telemetry stayed CPU0-owned' "$MAIN_SWIFT"; then
  echo "FAIL: S2f must log process dispatch telemetry readiness and CPU0-owned markers." >&2
  exit 1
fi
if ! grep -q 'S2h OK: secondary EL0 gate ready' "$MAIN_SWIFT" ||
   ! grep -q 'S2h OK: secondary EL0 gate held CPU0-owned' "$MAIN_SWIFT"; then
  echo "FAIL: S2h must log secondary EL0 gate readiness and held markers." >&2
  exit 1
fi
if ! grep -q 'S3a OK: address-space CPU mask scaffold ready' "$MAIN_SWIFT" ||
   ! grep -q 'S3a OK: address-space CPU masks stayed CPU0-owned' "$MAIN_SWIFT"; then
  echo "FAIL: S3a must log address-space CPU mask readiness and CPU0-owned markers." >&2
  exit 1
fi
if ! grep -q 'S3b OK: GIC SGI IPI substrate ready' "$MAIN_SWIFT" ||
   ! grep -q 'S3b OK: IPI delivery stayed scheduler-safe' "$MAIN_SWIFT"; then
  echo "FAIL: S3b must log GIC SGI/IPI readiness and scheduler-safe delivery markers." >&2
  exit 1
fi
if ! grep -q 'S3c OK: TLB shootdown IPI scaffold ready' "$MAIN_SWIFT" ||
   ! grep -q 'S3c OK: TLB shootdown path stayed scheduler-safe' "$MAIN_SWIFT"; then
  echo "FAIL: S3c must log TLB shootdown readiness and scheduler-safe delivery markers." >&2
  exit 1
fi
if ! grep -q 'S3d OK: address-space TLB flush facade ready' "$MAIN_SWIFT" ||
   ! grep -q 'S3d OK: address-space TLB flush stayed CPU0-owned' "$MAIN_SWIFT"; then
  echo "FAIL: S3d must log address-space TLB flush facade readiness and CPU0-owned markers." >&2
  exit 1
fi
if ! grep -q 'S4a OK: PMM lock boundary ready' "$MAIN_SWIFT" ||
   ! grep -q 'S4a OK: PMM lock boundary stayed balanced' "$MAIN_SWIFT"; then
  echo "FAIL: S4a must log PMM lock boundary readiness and balanced markers." >&2
  exit 1
fi
if ! grep -q 'S2g OK: coproc pair dispatch telemetry CPU0-owned' "$MAIN_SWIFT"; then
  echo "FAIL: S2g must log coproc pair dispatch telemetry capture." >&2
  exit 1
fi

sched_line="$(rg -n '^[[:space:]]*schedulerInit\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s2c_owner_line="$(rg -n 'kernelSchedulerOwnershipSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
proc_line="$(rg -n '^[[:space:]]*processInit\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s2a_line="$(rg -n 'smpS2ReadinessSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s2b_line="$(rg -n 'processSchedulerContextSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s2d_line="$(rg -n 'processRunQueueScaffoldSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s2e_line="$(rg -n 'processDormantSchedulerCpusSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s2f_line="$(rg -n 'processDispatchTelemetrySelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s2h_line="$(rg -n 'processSecondaryEl0GateSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s3a_line="$(rg -n 'processAddressSpaceCpuMaskSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s3b_line="$(rg -n 'smpIpiSubstrateSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s3c_line="$(rg -n 'smpTlbShootdownSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s3d_line="$(rg -n 'processAddressSpaceTlbFlushFacadeSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s4a_line="$(rg -n 'pmmS4aConcurrencySelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s4a_smp_line="$(rg -n 'smpPmmStressSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
demo_line="$(rg -n '^[[:space:]]*runSchedulerDemo\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s2c_no_secondary_line="$(rg -n 'smpS2cNoSecondaryKernelSchedulerExecution\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
process_demo_line="$(rg -n '^[[:space:]]*runProcessDemo\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
concurrent_demo_line="$(rg -n 'runConcurrentDemo\(\)' "$MAIN_SWIFT" | tail -1 | cut -d: -f1)"
s2g_pair_line="$(rg -n 'processCoprocPairDispatchTelemetrySelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
fork_demo_line="$(rg -n '^[[:space:]]*runForkDemo\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
runps_line="$(rg -n '^[[:space:]]*runPsDemo\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s2d_no_secondary_line="$(rg -n 'processRunQueueNoSecondaryExecutionSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s2e_no_secondary_line="$(rg -n 'processNoSecondarySchedulerDispatchSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s2f_no_secondary_line="$(rg -n 'processDispatchTelemetryNoSecondarySelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s2h_no_secondary_line="$(rg -n 'processSecondaryEl0GateHeldSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s3a_no_secondary_line="$(rg -n 'processAddressSpaceCpuMaskNoSecondarySelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s3b_no_secondary_line="$(rg -n 'smpS3bIpiSchedulerBoundarySelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s3c_no_secondary_line="$(rg -n 'smpS3cTlbShootdownSchedulerBoundarySelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s3d_no_secondary_line="$(rg -n 'processAddressSpaceTlbFlushNoSecondarySelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s4a_no_secondary_line="$(rg -n 'pmmS4aLockBoundaryHeldSelfTest\(\)' "$MAIN_SWIFT" | tail -1 | cut -d: -f1)"
s4a_smp_no_secondary_line="$(rg -n 'smpS4aPmmStressSchedulerBoundarySelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
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
if [[ -z "$s2e_line" || "$s2d_line" -ge "$s2e_line" ]]; then
  echo "FAIL: S2e dormant scheduler CPU self-test must run after the S2d run queue scaffold." >&2
  exit 1
fi
if [[ -z "$s2f_line" || "$s2e_line" -ge "$s2f_line" ]]; then
  echo "FAIL: S2f dispatch telemetry self-test must run after the S2e dormant scheduler scaffold." >&2
  exit 1
fi
if [[ -z "$s2h_line" || "$s2f_line" -ge "$s2h_line" || "$s2h_line" -ge "$demo_line" ]]; then
  echo "FAIL: S2h secondary EL0 gate self-test must run after S2f readiness and before scheduler/userland demos." >&2
  exit 1
fi
if [[ -z "$s3a_line" || "$s2h_line" -ge "$s3a_line" || "$s3a_line" -ge "$demo_line" ]]; then
  echo "FAIL: S3a address-space CPU mask self-test must run after S2h readiness and before scheduler/userland demos." >&2
  exit 1
fi
if [[ -z "$s3b_line" || "$s3a_line" -ge "$s3b_line" || "$s3b_line" -ge "$demo_line" ]]; then
  echo "FAIL: S3b IPI substrate self-test must run after S3a readiness and before scheduler/userland demos." >&2
  exit 1
fi
if [[ -z "$s3c_line" || "$s3b_line" -ge "$s3c_line" || "$s3c_line" -ge "$demo_line" ]]; then
  echo "FAIL: S3c TLB shootdown self-test must run after S3b readiness and before scheduler/userland demos." >&2
  exit 1
fi
if [[ -z "$s3d_line" || "$s3c_line" -ge "$s3d_line" || "$s3d_line" -ge "$demo_line" ]]; then
  echo "FAIL: S3d TLB flush facade self-test must run after S3c readiness and before scheduler/userland demos." >&2
  exit 1
fi
if [[ -z "$s4a_line" || -z "$s4a_smp_line" ||
      "$s3d_line" -ge "$s4a_line" ||
      "$s4a_line" -ge "$s4a_smp_line" ||
      "$s4a_smp_line" -ge "$demo_line" ]]; then
  echo "FAIL: S4a PMM lock and SMP stress self-tests must run after S3d readiness and before scheduler/userland demos." >&2
  exit 1
fi
if [[ -z "$demo_line" || -z "$s2c_no_secondary_line" || -z "$process_demo_line" ||
      "$demo_line" -ge "$s2c_no_secondary_line" ||
      "$s2c_no_secondary_line" -ge "$process_demo_line" ]]; then
  echo "FAIL: S2c no-secondary-kernel guard must run after the kernel scheduler demo and before EL0 demos." >&2
  exit 1
fi
if [[ -z "$concurrent_demo_line" || -z "$s2g_pair_line" || -z "$fork_demo_line" ||
      "$concurrent_demo_line" -ge "$s2g_pair_line" ||
      "$s2g_pair_line" -ge "$fork_demo_line" ]]; then
  echo "FAIL: S2g coproc telemetry guard must run immediately after the concurrent EL0 demo and before later demos can reuse slots." >&2
  exit 1
fi
if [[ -z "$runps_line" || -z "$s2d_no_secondary_line" || -z "$s2b_no_secondary_line" ||
      "$runps_line" -ge "$s2d_no_secondary_line" ||
      "$s2d_no_secondary_line" -ge "$s2b_no_secondary_line" ]]; then
  echo "FAIL: S2d run queue CPU0-owned guard must run after Swift ps and before S2b no-secondary-EL0." >&2
  exit 1
fi
if [[ -z "$s2e_no_secondary_line" ||
      "$s2d_no_secondary_line" -ge "$s2e_no_secondary_line" ||
      "$s2e_no_secondary_line" -ge "$s2b_no_secondary_line" ]]; then
  echo "FAIL: S2e dormant scheduler guard must run after S2d and before S2b no-secondary-EL0." >&2
  exit 1
fi
if [[ -z "$s2f_no_secondary_line" ||
      "$s2e_no_secondary_line" -ge "$s2f_no_secondary_line" ||
      "$s2f_no_secondary_line" -ge "$s2b_no_secondary_line" ]]; then
  echo "FAIL: S2f dispatch telemetry guard must run after S2e and before S2b no-secondary-EL0." >&2
  exit 1
fi
if [[ -z "$s2h_no_secondary_line" ||
      "$s2f_no_secondary_line" -ge "$s2h_no_secondary_line" ||
      "$s2h_no_secondary_line" -ge "$s2b_no_secondary_line" ]]; then
  echo "FAIL: S2h secondary EL0 gate guard must run after S2f and before S2b no-secondary-EL0." >&2
  exit 1
fi
if [[ -z "$s3a_no_secondary_line" ||
      "$s2h_no_secondary_line" -ge "$s3a_no_secondary_line" ||
      "$s3a_no_secondary_line" -ge "$s2b_no_secondary_line" ]]; then
  echo "FAIL: S3a address-space CPU mask guard must run after S2h and before S2b no-secondary-EL0." >&2
  exit 1
fi
if [[ -z "$s3b_no_secondary_line" ||
      "$s3a_no_secondary_line" -ge "$s3b_no_secondary_line" ||
      "$s3b_no_secondary_line" -ge "$s2b_no_secondary_line" ]]; then
  echo "FAIL: S3b IPI scheduler-boundary guard must run after S3a and before S2b no-secondary-EL0." >&2
  exit 1
fi
if [[ -z "$s3c_no_secondary_line" ||
      "$s3b_no_secondary_line" -ge "$s3c_no_secondary_line" ||
      "$s3c_no_secondary_line" -ge "$s2b_no_secondary_line" ]]; then
  echo "FAIL: S3c TLB shootdown scheduler-boundary guard must run after S3b and before S2b no-secondary-EL0." >&2
  exit 1
fi
if [[ -z "$s3d_no_secondary_line" ||
      "$s3c_no_secondary_line" -ge "$s3d_no_secondary_line" ||
      "$s3d_no_secondary_line" -ge "$s2b_no_secondary_line" ]]; then
  echo "FAIL: S3d address-space TLB flush guard must run after S3c and before S2b no-secondary-EL0." >&2
  exit 1
fi
if [[ -z "$s4a_no_secondary_line" || -z "$s4a_smp_no_secondary_line" ||
      "$s3d_no_secondary_line" -ge "$s4a_no_secondary_line" ||
      "$s4a_no_secondary_line" -ge "$s4a_smp_no_secondary_line" ||
      "$s4a_smp_no_secondary_line" -ge "$s2b_no_secondary_line" ]]; then
  echo "FAIL: S4a PMM lock/stress guards must run after S3d and before S2b no-secondary-EL0." >&2
  exit 1
fi

if ! grep -q 'smpHandleIpi(iar)' "$MAIN_SWIFT" ||
   ! grep -q 'interruptId == smpIpiInterruptId' "$MAIN_SWIFT"; then
  echo "FAIL: S3b IRQ path must dispatch SGIs to the SMP IPI handler." >&2
  exit 1
fi
ipi_irq_line="$(rg -n 'interruptId == smpIpiInterruptId' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
unexpected_irq_line="$(rg -n 'unexpected IRQ' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
if [[ -z "$ipi_irq_line" || -z "$unexpected_irq_line" ||
      "$ipi_irq_line" -ge "$unexpected_irq_line" ]]; then
  echo "FAIL: S3b IRQ path must recognize SGIs before the unexpected-IRQ branch." >&2
  exit 1
fi

ipi_handler_block="$(sed -n '/^func smpHandleIpi/,/^}/p' "$SECONDARY_SWIFT")"
if [[ -z "$ipi_handler_block" ]] ||
   rg -n 'klog\(|schedulerTick|processOnTick|schedYield|yieldToScheduler|cpu_switch_context|address_space_switch|tlbi|vmalle1|vae1|markProcessReady|processRun|vfs|virtio|pmm_' <<<"$ipi_handler_block" >/dev/null; then
  echo "FAIL: S3b IPI handler must stay side-effect-light: no logging, scheduler, process, VFS, PMM, virtio, or inline TLB primitives." >&2
  exit 1
fi

tlb_handler_block="$(awk '/^func smpHandleTlbShootdownForCurrentCpu/ { flag=1 } flag { print } /^func smpTlbShootdownProbeTargetMask/ { exit }' "$PERCPU_SWIFT")"
if [[ -z "$tlb_handler_block" ]] ||
   ! grep -q 'tlbi_all()' <<<"$tlb_handler_block" ||
   rg -n 'klog\(|schedulerTick|processOnTick|schedYield|yieldToScheduler|cpu_switch_context|address_space_switch|markProcessReady|processRun|vfs|virtio|pmm_|tableStore|linkPage|unmapRange' <<<"$tlb_handler_block" >/dev/null; then
  echo "FAIL: S3c TLB shootdown handler must only do a local TLB invalidate plus atomic ack/counters." >&2
  exit 1
fi

pmm_stress_handler_block="$(awk '/^func smpHandlePmmStressForCurrentCpu/ { flag=1 } flag { print } /^func smpPmmStressProbeTargetMask/ { exit }' "$PERCPU_SWIFT")"
if [[ -z "$pmm_stress_handler_block" ]] ||
   ! grep -q 'pmmS4aBoundedStressForCurrentCpu()' <<<"$pmm_stress_handler_block" ||
   rg -n 'klog\(|schedulerTick|processOnTick|schedYield|yieldToScheduler|cpu_switch_context|address_space_switch|markProcessReady|processRun|vfs|virtio|pkgStore|tableStore|linkPage|unmapRange|tlbi|vmalle1|vae1' <<<"$pmm_stress_handler_block" >/dev/null; then
  echo "FAIL: S4a PMM stress handler must stay bounded to PMM stress plus atomic ack/counters." >&2
  exit 1
fi

secondary_irq_park_block="$(sed -n '/enable_irq()/,$p' "$SECONDARY_SWIFT")"
if [[ -z "$secondary_irq_park_block" ]] ||
   ! grep -q 'while true { wfi() }' <<<"$secondary_irq_park_block" ||
   grep -q 'disable_irq()' <<<"$secondary_irq_park_block"; then
  echo "FAIL: S3b parked secondaries must remain IRQ-enabled for SGI/IPI delivery." >&2
  exit 1
fi

echo "PASS: S1/S2a/S2b/S2c/S2d/S2e/S2f/S2g/S2h/S3a/S3b/S3c/S3d/S4a release-readiness contract holds (PSCI CPU_ON + early timer + scheduler/IPI/TLB/PMM boundary)"
