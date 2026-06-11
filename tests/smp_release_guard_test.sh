#!/usr/bin/env bash
# smp_release_guard_test.sh - SMP guard: secondary release and S2 scheduling stay explicit.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAKEFILE="$ROOT/Makefile"
KERNEL="$ROOT/build/kernel.elf"
BOOT_OBJ="$ROOT/build/boot.o"
BOOT_SRC="$ROOT/kernel/arch/aarch64/boot.S"
IO_HDR="$ROOT/kernel/arch/aarch64/io.h"
MAKEFILE_PATH="$ROOT/Makefile"
MAIN_SWIFT="$ROOT/kernel/main.swift"
GIC_SWIFT="$ROOT/kernel/drivers/gic.swift"
PERCPU_SWIFT="$ROOT/kernel/smp/percpu.swift"
SECONDARY_SWIFT="$ROOT/kernel/smp/secondary.swift"
PROCESS_SWIFT="$ROOT/kernel/user/process.swift"
FUTEX_SWIFT="$ROOT/kernel/sched/futex.swift"
VM_SWIFT="$ROOT/kernel/mm/vm.swift"
PMM_SWIFT="$ROOT/kernel/mm/pmm.swift"
VFS_SWIFT="$ROOT/kernel/vfs/vfs.swift"
PKG_SWIFT="$ROOT/kernel/pkg/store.swift"
NET_SWIFT="$ROOT/kernel/net/socket.swift"
SCHED_SWIFT="$ROOT/kernel/sched/scheduler.swift"
RUNTIME_HEAP="$ROOT/kernel/runtime/heap.c"
TOP_SWIFT="$ROOT/userland/top.swift"
SWIFT_USER_C="$ROOT/userland/lib/swift_user.c"
SWIFT_USER_H="$ROOT/userland/lib/swift_user.h"
API_REFERENCE="$ROOT/docs/API_REFERENCE.md"
S4_STRESS_C="$ROOT/userland/s4stress.c"
S4_STRESS_TEST="$ROOT/tests/s4_resource_stress_test.sh"
SMP_RESOURCE_STRESS_TEST="$ROOT/tests/smp_resource_stress_test.sh"
SMP_BOOT_TEST="$ROOT/tests/smp_boot_test.sh"
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

if ! grep -q 'private var currentProcByCpu = \[Int\]' "$PROCESS_SWIFT" ||
   ! grep -q 'setCurrentProcessSlot(s)' "$PROCESS_SWIFT" ||
   ! grep -q 'setCurrentProcessSlot(-1)' "$PROCESS_SWIFT" ||
   ! grep -q 'smpSetCurrentProcessForCurrentCpu(Int32(slot))' "$PROCESS_SWIFT"; then
  echo "FAIL: S2 requires the EL0 scheduler loop to mirror per-CPU current process state." >&2
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
  'private var pSchedulerQuiesced = \[Bool\]' \
  'private var processRunQueueHead = \[Int32\]' \
  'private var processRunQueueTail = \[Int32\]' \
  'private var processRunQueueEnqueueCount = \[UInt64\]' \
  'private var processRunQueueDispatchCount = \[UInt64\]' \
  'private var processDispatchTelemetryCount = \[UInt64\]' \
  'private var processAddressSpaceActivationCount = \[UInt64\]' \
  'private var processSecondarySchedulerRunMask: UInt64 = 0' \
  'private var processSecondarySchedulerActiveMask: UInt64 = 0' \
  'private var processSecondarySchedulerStopMask: UInt64 = 0' \
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
  'processAddressSpaceCpuMaskPostRunSelfTest' \
  'processAddressSpaceTlbFlushFacadeSelfTest' \
  'processAddressSpaceTlbFlushPostRunSelfTest' \
  'processRunQueueScaffoldSelfTest' \
  'processDormantSchedulerCpusSelfTest' \
  'processDispatchTelemetrySelfTest' \
  'processCoprocPairDispatchTelemetrySelfTest' \
  'processMultiCpuSchedulerPostRunSelfTest' \
  'processSecondarySchedulerService' \
  'processSecondarySchedulerActiveForCurrentCpu' \
  'processStartSecondaryScheduler' \
  'processStopSecondaryScheduler' \
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

if ! grep -q 'EL0 process dispatched on inactive CPU' "$PROCESS_SWIFT" ||
   ! grep -q 'EL0 process dispatch CPU mismatch' "$PROCESS_SWIFT" ||
   ! grep -q 'pDispatchCpuMask\[slot\]' "$PROCESS_SWIFT"; then
  echo "FAIL: S2 dispatch telemetry must reject inactive CPUs and home/dispatch mismatches." >&2
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

if ! grep -q 'address space activated on inactive CPU' "$PROCESS_SWIFT" ||
   ! grep -q 'address-space CPU mask dispatch mismatch' "$PROCESS_SWIFT" ||
   ! grep -q 'processAddressSpaceActivationCount\[Int(cpu)\]' "$PROCESS_SWIFT"; then
  echo "FAIL: S3a address-space CPU mask telemetry must keep inactive-CPU and dispatch-mismatch guards." >&2
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

s5b_capture_line="$(rg -n 'captureLastS5bBatchDispatchTelemetry\(a, b, c\)' "$PROCESS_SWIFT" | head -1 | cut -d: -f1)"
s5b_reap_line="$(rg -n 'reapProcess\(a\)' "$PROCESS_SWIFT" | tail -1 | cut -d: -f1)"
if [[ -z "$s5b_capture_line" || -z "$s5b_reap_line" ||
      "$s5b_capture_line" -ge "$s5b_reap_line" ]]; then
  echo "FAIL: S5b must capture placement-batch dispatch telemetry before reaping the slots." >&2
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

if ! grep -q 'cpu >= schedCtxCpuCount || !processCpuCanSchedule(cpu)' "$PROCESS_SWIFT" ||
   ! grep -q 'processOnTick entered on inactive scheduler CPU' "$PROCESS_SWIFT" ||
   ! grep -q 'processSecondarySchedulerCanTickForCurrentCpu' "$PROCESS_SWIFT"; then
  echo "FAIL: S2 process scheduler paths must panic if entered from an inactive scheduler CPU." >&2
  exit 1
fi

cpu0_timer_block="$(sed -n '/if interruptId == physicalTimerIrq && currentCpuId() == 0 {/,/} else if interruptId == uartIrqId {/p' "$MAIN_SWIFT")"
if [[ -z "$cpu0_timer_block" ]] ||
   ! grep -q 'schedulerTick()' <<<"$cpu0_timer_block" ||
   ! grep -q 'processOnTick(fromEL0: fromEL0)' <<<"$cpu0_timer_block" ||
   ! grep -q 'processSecondarySchedulerCanTickForCurrentCpu()' <<<"$cpu0_timer_block"; then
  echo "FAIL: S2 requires irqHandler to keep kernel scheduler ticks on CPU0 and gate secondary EL0 ticks on active scheduler CPUs." >&2
  exit 1
fi

secondary_tick_gate="$(sed -n '/func processSecondarySchedulerCanTickForCurrentCpu()/,/func processSecondarySchedulerService()/p' "$PROCESS_SWIFT")"
if [[ -z "$secondary_tick_gate" ]] ||
   ! grep -q 'processSecondaryActiveMask()' <<<"$secondary_tick_gate" ||
   ! grep -q 'processSecondaryRunMask()' <<<"$secondary_tick_gate" ||
   ! grep -q 'processSecondaryStopMask()' <<<"$secondary_tick_gate"; then
  echo "FAIL: secondary EL0 timer ticks must require active+run masks and reject the stop mask." >&2
  exit 1
fi

secondary_wait_block="$(sed -n '/private func processWaitForSecondaryActive/,/private func processStartSecondaryScheduler/p' "$PROCESS_SWIFT")"
if [[ -z "$secondary_wait_block" ]] ||
   ! grep -q 'if active {' <<<"$secondary_wait_block" ||
   ! grep -q 'gicSendSoftwareGeneratedInterruptToCpu(smpIpiInterruptId, cpu)' <<<"$secondary_wait_block"; then
  echo "FAIL: secondary scheduler SGI wake must stay on the start path only." >&2
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

if ! grep -q 'S2d OK: process run queue scaffold ready' "$MAIN_SWIFT"; then
  echo "FAIL: S2d must log process run queue scaffold readiness." >&2
  exit 1
fi
if ! grep -q 'S2e OK: dormant process scheduler CPUs published' "$MAIN_SWIFT"; then
  echo "FAIL: S2e must log dormant process scheduler publication." >&2
  exit 1
fi
if ! grep -q 'S2f OK: process dispatch telemetry ready' "$MAIN_SWIFT"; then
  echo "FAIL: S2f must log process dispatch telemetry readiness." >&2
  exit 1
fi
if ! grep -q 'S2h OK: secondary EL0 gate ready' "$MAIN_SWIFT" ||
   ! grep -q 'S2h OK: coproc pair dispatched across scheduler CPUs' "$MAIN_SWIFT" ||
   ! grep -q 'S2h OK: coproc pair dispatch CPU0 fallback' "$MAIN_SWIFT" ||
   ! grep -q 'S2h OK: process scheduler quiesced after multi-CPU dispatch' "$MAIN_SWIFT" ||
   ! grep -q 'S2h OK: secondary EL0 gate closed after restricted dispatch' "$MAIN_SWIFT"; then
  echo "FAIL: S2h must log gate readiness, restricted coproc dispatch, quiescence, and gate closure." >&2
  exit 1
fi
if ! grep -q 'S3a OK: address-space CPU mask scaffold ready' "$MAIN_SWIFT" ||
   ! grep -q 'S3a OK: address-space CPU masks matched dispatch CPUs' "$MAIN_SWIFT"; then
  echo "FAIL: S3a must log address-space CPU mask readiness and post-run dispatch matching." >&2
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
   ! grep -q 'S3d OK: address-space TLB flush matched dispatch CPUs' "$MAIN_SWIFT"; then
  echo "FAIL: S3d must log address-space TLB flush facade readiness and post-run dispatch matching." >&2
  exit 1
fi
if ! grep -q 'S4a OK: PMM lock boundary ready' "$MAIN_SWIFT" ||
   ! grep -q 'S4a OK: PMM lock boundary stayed balanced' "$MAIN_SWIFT"; then
  echo "FAIL: S4a must log PMM lock boundary readiness and balanced markers." >&2
  exit 1
fi
if ! grep -q 'S4b OK: VFS lock boundary ready' "$MAIN_SWIFT" ||
   ! grep -q 'S4b OK: VFS lock boundary stayed balanced' "$MAIN_SWIFT"; then
  echo "FAIL: S4b must log VFS lock boundary readiness and balanced markers." >&2
  exit 1
fi
if ! grep -q 'S4c OK: kernel heap lock boundary ready' "$MAIN_SWIFT" ||
   ! grep -q 'S4c OK: kernel heap lock boundary stayed balanced' "$MAIN_SWIFT"; then
  echo "FAIL: S4c must log kernel heap lock boundary readiness and balanced markers." >&2
  exit 1
fi
if ! grep -q 'S4d OK: package-store lock boundary ready' "$MAIN_SWIFT" ||
   ! grep -q 'S4d OK: package-store lock boundary stayed balanced' "$MAIN_SWIFT"; then
  echo "FAIL: S4d must log package-store lock boundary readiness and balanced markers." >&2
  exit 1
fi
if ! grep -q 'S4e OK: network lock boundary ready' "$MAIN_SWIFT" ||
   ! grep -q 'S4e OK: network lock boundary stayed balanced' "$MAIN_SWIFT"; then
  echo "FAIL: S4e must log network lock boundary readiness and balanced markers." >&2
  exit 1
fi

for needle in \
  'private var vfsLockWord: UInt64 = 0' \
  'private var vfsLockAcquireCount: UInt64 = 0' \
  'private var vfsLockContentionCount: UInt64 = 0' \
  'private func vfsLock() -> UInt64' \
  'private func vfsUnlock(_ daif: UInt64)' \
  'private func borrowDescriptionForFD' \
  'private func releaseBorrowedDescription' \
  'private func borrowSocketForFD' \
  'private func vfsS4bAccountingSelfTestLocked' \
  'func vfsS4bReadinessSelfTest() -> Bool' \
  'func vfsS4bLockBoundaryHeldSelfTest() -> Bool' \
  'let borrowed = borrowDescriptionForFD(proc, fd)' \
  'let borrowed = borrowSocketForFD(currentVFSProcess(), fd, required: .write)' \
  'let borrowed = borrowSocketForFD(currentVFSProcess(), fd, required: .read)' \
  'let daif = vfsLock()' \
  'processYieldForIO()'; do
  if ! grep -q "$needle" "$VFS_SWIFT"; then
    echo "FAIL: S4b VFS lock boundary missing $needle." >&2
    exit 1
  fi
done

for needle in \
  'static uint64_t heap_lock_word' \
  'static uint64_t heap_lock_acquire_count' \
  'static uint64_t heap_lock_contention_count' \
  'static uint64_t heap_lock(void)' \
  'uint64_t daif = irq_save();' \
  'smp_atomic_compare_exchange_u64(&heap_lock_word, &expected, 1)' \
  'static void heap_unlock(uint64_t daif)' \
  'irq_restore(daif);' \
  'static void heap_init_unlocked(void)' \
  'swiftos_kernel_alloc(uintptr_t byte_count, uintptr_t alignment)' \
  'uint64_t swiftos_heap_lock_acquire_count(void)' \
  'uint64_t swiftos_heap_lock_contention_count(void)' \
  'bool swiftos_heap_lock_boundary_self_test(void)' \
  'bool swiftos_heap_s4c_self_test(void)'; do
  if ! grep -q "$needle" "$RUNTIME_HEAP"; then
    echo "FAIL: S4c kernel heap lock boundary missing $needle." >&2
    exit 1
  fi
done

if ! grep -q 'swiftos_heap_lock_acquire_count' "$IO_HDR" ||
   ! grep -q 'swiftos_heap_lock_contention_count' "$IO_HDR" ||
   ! grep -q 'swiftos_heap_lock_boundary_self_test' "$IO_HDR" ||
   ! grep -q 'swiftos_heap_s4c_self_test' "$IO_HDR"; then
  echo "FAIL: S4c heap lock self-test/counter prototypes must be exported through io.h." >&2
  exit 1
fi

for needle in \
  'private var pkgStoreLockWord: UInt64 = 0' \
  'private var pkgStoreLockAcquireCount: UInt64 = 0' \
  'private var pkgStoreLockContentionCount: UInt64 = 0' \
  'private var pkgStoreMutationInProgress = false' \
  'private func pkgStoreLock() -> UInt64' \
  'private func pkgStoreUnlock(_ daif: UInt64)' \
  'private func pkgStoreBeginMutation() -> Bool' \
  'private func pkgStoreEndMutation()' \
  'private func pkgReserveRecord' \
  'private func pkgCommitRecordNext' \
  'private func pkgPublishInstalledPayload' \
  'func pkgStoreS4dLockAcquireCount() -> UInt64' \
  'func pkgStoreS4dLockContentionCount() -> UInt64' \
  'func pkgStoreS4dReadinessSelfTest() -> Bool' \
  'func pkgStoreS4dLockBoundaryHeldSelfTest() -> Bool'; do
  if ! grep -q "$needle" "$PKG_SWIFT"; then
    echo "FAIL: S4d package-store lock boundary missing $needle." >&2
    exit 1
  fi
done

if ! grep -q 'if !pkgStoreBeginMutation() { return -11 }' "$PKG_SWIFT" ||
   ! grep -q 'defer { pkgStoreEndMutation() }' "$PKG_SWIFT" ||
   ! grep -q 'let reserved = pkgReserveRecord(dataSize:' "$PKG_SWIFT" ||
   ! grep -q 'pkgCommitRecordNext(reserved.next)' "$PKG_SWIFT" ||
   ! grep -q 'payloadOffset = payload.offset' "$PKG_SWIFT" ||
   ! grep -q 'return virtioBlkReadPackageStoreRange(payloadOffset + byteOff, buf, len)' "$PKG_SWIFT"; then
  echo "FAIL: S4d package-store install/read paths must use writer gating, record reservation, and unlocked payload reads." >&2
  exit 1
fi

for needle in \
  'private var netLockWord: UInt64 = 0' \
  'private var netLockAcquireCount: UInt64 = 0' \
  'private var netLockContentionCount: UInt64 = 0' \
  'private func netLock() -> UInt64' \
  'private func netUnlock(_ daif: UInt64)' \
  'private func netPumpLocked() -> RxOutcome' \
  'func netPump()' \
  'func netIsReady() -> Bool' \
  'func netProbeSendArpRequest' \
  'func netProbePollArp' \
  'func netProbeSendEchoRequest' \
  'func netProbePollEcho() -> Bool' \
  'private func socketAllocLocked' \
  'private func allocEphemeralPortLocked' \
  'func netS4eLockAcquireCount() -> UInt64' \
  'func netS4eLockContentionCount() -> UInt64' \
  'func netS4eReadinessSelfTest() -> Bool' \
  'func netS4eLockBoundaryHeldSelfTest() -> Bool'; do
  if ! grep -q "$needle" "$NET_SWIFT"; then
    echo "FAIL: S4e network lock boundary missing $needle." >&2
    exit 1
  fi
done

if rg -n 'gNet|virtioNetPoll|virtioNetTxSubmit|virtioNetTxBuffer' "$MAIN_SWIFT" >/dev/null; then
  echo "FAIL: S4e main boot probe must use network lock-boundary helpers instead of direct gNet/virtio-net access." >&2
  exit 1
fi

if [[ ! -f "$SMP_RESOURCE_STRESS_TEST" ]]; then
  echo "FAIL: S4f resource stress test script is missing." >&2
  exit 1
fi
for needle in \
  '-smp "$SMP_CPUS"' \
  '/bin/forkdemo; echo S4F-FORK-RC=$?' \
  '/bin/fdopsdemo; echo S4F-FDOPS-RC=$?' \
  '/bin/execdemo; echo S4F-EXEC-RC=$?' \
  '/bin/threadsdemo; echo S4F-THREADS-RC=$?' \
  'S4F-TMPFS-DONE' \
  'S4F-TMPFS-CLEAN' \
  'S4F-RESOURCE-STRESS-DONE' \
  'S4a OK: PMM lock boundary stayed balanced' \
  'S4b OK: VFS lock boundary stayed balanced' \
  'S4c OK: kernel heap lock boundary stayed balanced' \
  'S4d OK: package-store lock boundary stayed balanced' \
  'S4e OK: network lock boundary stayed balanced'; do
  if ! grep -Fq -- "$needle" "$SMP_RESOURCE_STRESS_TEST"; then
    echo "FAIL: S4f resource stress test missing $needle." >&2
    exit 1
  fi
done
if ! grep -Fq 'SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/smp_resource_stress_test.sh' "$MAKEFILE_PATH" ||
   ! grep -q '^smp-resource-stress-test:' "$MAKEFILE_PATH"; then
  echo "FAIL: S4f resource stress test must be wired into make test and expose a dedicated make target." >&2
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
s4d_line="$(rg -n 'pkgStoreS4dReadinessSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s4b_line="$(rg -n 'vfsS4bReadinessSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s4c_line="$(rg -n 'swiftos_heap_s4c_self_test\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
net_probe_line="$(rg -n '^[[:space:]]*runVirtioNetProbe\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s4e_line="$(rg -n 'netS4eReadinessSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
demo_line="$(rg -n '^[[:space:]]*runSchedulerDemo\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s2c_no_secondary_line="$(rg -n 'smpS2cNoSecondaryKernelSchedulerExecution\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
process_demo_line="$(rg -n '^[[:space:]]*runProcessDemo\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
concurrent_demo_line="$(rg -n 'runConcurrentDemo\(\)' "$MAIN_SWIFT" | tail -1 | cut -d: -f1)"
s2g_pair_line="$(rg -n 'processCoprocPairDispatchTelemetrySelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s5b_demo_line="$(rg -n 'runS5bPlacementDemo\(\)' "$MAIN_SWIFT" | tail -1 | cut -d: -f1)"
s5b_guard_line="$(rg -n 'processS5bPlacementTelemetrySelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
fork_demo_line="$(rg -n '^[[:space:]]*runForkDemo\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
runps_line="$(rg -n '^[[:space:]]*runPsDemo\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s2_quiesced_line="$(rg -n 'processMultiCpuSchedulerPostRunSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s2h_gate_closed_line="$(rg -n 'processSecondaryEl0GateHeldSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s3a_postrun_line="$(rg -n 'processAddressSpaceCpuMaskPostRunSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s3b_boundary_line="$(rg -n 'smpS3bIpiSchedulerBoundarySelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s3c_boundary_line="$(rg -n 'smpS3cTlbShootdownSchedulerBoundarySelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s3d_postrun_line="$(rg -n 'processAddressSpaceTlbFlushPostRunSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s4a_lock_boundary_line="$(rg -n 'pmmS4aLockBoundaryHeldSelfTest\(\)' "$MAIN_SWIFT" | tail -1 | cut -d: -f1)"
s4a_stress_boundary_line="$(rg -n 'smpS4aPmmStressSchedulerBoundarySelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s4b_lock_boundary_line="$(rg -n 'vfsS4bLockBoundaryHeldSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s4c_lock_boundary_line="$(rg -n 'swiftos_heap_lock_boundary_self_test\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s4d_lock_boundary_line="$(rg -n 'pkgStoreS4dLockBoundaryHeldSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
s4e_lock_boundary_line="$(rg -n 'netS4eLockBoundaryHeldSelfTest\(\)' "$MAIN_SWIFT" | head -1 | cut -d: -f1)"
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
if [[ -z "$s4d_line" ||
      "$s4a_smp_line" -ge "$s4d_line" ||
      "$s4d_line" -ge "$demo_line" ]]; then
  echo "FAIL: S4d package-store lock self-test must run after S4a readiness and before scheduler/userland demos." >&2
  exit 1
fi
if [[ -z "$s4b_line" ||
      "$s4d_line" -ge "$s4b_line" ||
      "$s4b_line" -ge "$demo_line" ]]; then
  echo "FAIL: S4b VFS lock self-test must run after S4d package-store readiness and before scheduler/userland demos." >&2
  exit 1
fi
if [[ -z "$s4c_line" ||
      "$s4b_line" -ge "$s4c_line" ||
      "$s4c_line" -ge "$demo_line" ]]; then
  echo "FAIL: S4c kernel heap lock self-test must run after S4b readiness and before scheduler/userland demos." >&2
  exit 1
fi
if [[ -z "$net_probe_line" || -z "$s4e_line" ||
      "$s4c_line" -ge "$net_probe_line" ||
      "$net_probe_line" -ge "$s4e_line" ||
      "$s4e_line" -ge "$demo_line" ]]; then
  echo "FAIL: S4e network lock self-test must run after the net probe and before scheduler/userland demos." >&2
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
if [[ -z "$s5b_demo_line" || -z "$s5b_guard_line" || -z "$fork_demo_line" ||
      "$s2g_pair_line" -ge "$s5b_demo_line" ||
      "$s5b_demo_line" -ge "$s5b_guard_line" ||
      "$s5b_guard_line" -ge "$fork_demo_line" ]]; then
  echo "FAIL: S5b placement guard must run after S2h pair telemetry and before later demos can reuse slots." >&2
  exit 1
fi
if [[ -z "$runps_line" || -z "$s2_quiesced_line" ||
      "$runps_line" -ge "$s2_quiesced_line" ]]; then
  echo "FAIL: S2 multi-CPU scheduler quiescence guard must run after Swift ps." >&2
  exit 1
fi
if [[ -z "$s2h_gate_closed_line" ||
      "$s2_quiesced_line" -ge "$s2h_gate_closed_line" ]]; then
  echo "FAIL: S2h secondary EL0 gate guard must run after scheduler quiescence." >&2
  exit 1
fi
if [[ -z "$s3a_postrun_line" ||
      "$s2h_gate_closed_line" -ge "$s3a_postrun_line" ]]; then
  echo "FAIL: S3a address-space CPU mask guard must run after S2h gate closure." >&2
  exit 1
fi
if [[ -z "$s3b_boundary_line" ||
      "$s3a_postrun_line" -ge "$s3b_boundary_line" ]]; then
  echo "FAIL: S3b IPI scheduler-boundary guard must run after S3a post-run checks." >&2
  exit 1
fi
if [[ -z "$s3c_boundary_line" ||
      "$s3b_boundary_line" -ge "$s3c_boundary_line" ]]; then
  echo "FAIL: S3c TLB shootdown scheduler-boundary guard must run after S3b." >&2
  exit 1
fi
if [[ -z "$s3d_postrun_line" ||
      "$s3c_boundary_line" -ge "$s3d_postrun_line" ]]; then
  echo "FAIL: S3d address-space TLB flush guard must run after S3c." >&2
  exit 1
fi
if [[ -z "$s4a_lock_boundary_line" || -z "$s4a_stress_boundary_line" ||
      "$s3d_postrun_line" -ge "$s4a_lock_boundary_line" ||
      "$s4a_lock_boundary_line" -ge "$s4a_stress_boundary_line" ]]; then
  echo "FAIL: S4a PMM lock/stress guards must run after S3d." >&2
  exit 1
fi
if [[ -z "$s4b_lock_boundary_line" ||
      "$s4a_stress_boundary_line" -ge "$s4b_lock_boundary_line" ]]; then
  echo "FAIL: S4b VFS lock guard must run after S4a." >&2
  exit 1
fi
if [[ -z "$s4c_lock_boundary_line" ||
      "$s4b_lock_boundary_line" -ge "$s4c_lock_boundary_line" ]]; then
  echo "FAIL: S4c kernel heap lock guard must run after S4b." >&2
  exit 1
fi
if [[ -z "$s4d_lock_boundary_line" ||
      "$s4c_lock_boundary_line" -ge "$s4d_lock_boundary_line" ]]; then
  echo "FAIL: S4d package-store lock guard must run after S4c." >&2
  exit 1
fi
if [[ -z "$s4e_lock_boundary_line" ||
      "$s4d_lock_boundary_line" -ge "$s4e_lock_boundary_line" ]]; then
  echo "FAIL: S4e network lock guard must run after S4d." >&2
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

s3b_boundary_block="$(sed -n '/^func smpS3bIpiSchedulerBoundarySelfTest/,/^}/p' "$SECONDARY_SWIFT")"
if [[ -z "$s3b_boundary_block" ]] ||
   ! grep -q 'smpS2cNoSecondaryKernelSchedulerExecution()' <<<"$s3b_boundary_block"; then
  echo "FAIL: S3b post-run boundary must allow restricted S2h EL0 switches while still rejecting secondary kernel scheduler execution." >&2
  exit 1
fi

s3c_boundary_block="$(sed -n '/^func smpS3cTlbShootdownSchedulerBoundarySelfTest/,/^}/p' "$SECONDARY_SWIFT")"
if [[ -z "$s3c_boundary_block" ]] ||
   ! grep -q 'smpS2cNoSecondaryKernelSchedulerExecution()' <<<"$s3c_boundary_block"; then
  echo "FAIL: S3c post-run boundary must allow restricted S2h EL0 switches while still rejecting secondary kernel scheduler execution." >&2
  exit 1
fi

s4a_boundary_block="$(sed -n '/^func smpS4aPmmStressSchedulerBoundarySelfTest/,/^}/p' "$SECONDARY_SWIFT")"
if [[ -z "$s4a_boundary_block" ]] ||
   ! grep -q 'smpS2cNoSecondaryKernelSchedulerExecution()' <<<"$s4a_boundary_block"; then
  echo "FAIL: S4a post-run boundary must allow restricted S2h EL0 switches while still rejecting secondary kernel scheduler execution." >&2
  exit 1
fi

secondary_irq_park_block="$(sed -n '/enable_irq()/,$p' "$SECONDARY_SWIFT")"
if [[ -z "$secondary_irq_park_block" ]] ||
   ! grep -q 'processSecondarySchedulerService()' <<<"$secondary_irq_park_block" ||
   ! grep -q 'enable_irq()' <<<"$secondary_irq_park_block" ||
   ! grep -q 'wfi()' <<<"$secondary_irq_park_block"; then
  echo "FAIL: S3b parked secondaries must poll the restricted S2h scheduler hook and sleep IRQ-enabled for SGI/IPI delivery." >&2
  exit 1
fi

for needle in \
  'USER_S4STRESS_ELF := $(BUILD)/s4stress.elf' \
  '$(BUILD)/user_s4stress.o: userland/s4stress.c userland/lib/syscall.h userland/lib/fs.h Makefile' \
  '$(USER_S4STRESS_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_s4stress.o userland/user.ld Makefile' \
  'cp $(USER_S4STRESS_ELF) $(BASE_ROOT)/bin/s4stress' \
  'SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/s4_resource_stress_test.sh' \
  's4-resource-stress-test: build $(QEMU_DTB_SMP4) base-image'; do
  if ! grep -Fq -- "$needle" "$MAKEFILE"; then
    echo "FAIL: S4f resource stress is not wired into Makefile: $needle." >&2
    exit 1
  fi
done

for needle in \
  'S4F-ALLOC-OK' \
  'S4F-PIPE-OK' \
  'S4F-TMPFS-OK' \
  'S4F-FORK-OK' \
  'S4F-SPAWN-OK' \
  'S4F-OK resource stress completed' \
  'mmap(0, pageSize' \
  'munmap(mem, pageSize)' \
  'pipe(fds)' \
  'fork()' \
  'spawn("/bin/argvdemo", argv)' \
  'rename(pathA, pathB)' \
  'mkdir(dirPath, 0)'; do
  if ! grep -Fq -- "$needle" "$S4_STRESS_C"; then
    echo "FAIL: S4f /bin/s4stress workload missing resource exercise: $needle." >&2
    exit 1
  fi
done

if [[ ! -x "$S4_STRESS_TEST" ]]; then
  echo "FAIL: S4f resource stress harness must be executable." >&2
  exit 1
fi

for needle in \
  'SMP_CPUS="${SMP_CPUS:-4}"' \
  '-smp "$SMP_CPU_COUNT"' \
  'await "S4F-OK resource stress completed"' \
  '[I] smp: S2a OK: per-CPU timer heartbeat ready detail=$SMP_CPU_COUNT' \
  '[I] smp: S4e OK: network lock boundary stayed balanced'; do
  if ! grep -Fq -- "$needle" "$S4_STRESS_TEST"; then
    echo "FAIL: S4f resource stress harness missing runtime guard: $needle." >&2
    exit 1
  fi
done

for needle in \
  'smpRecordIdleTickForCurrentCpu' \
  'smpPerCpuIdleTicks' \
  'smpPerCpuUtilizationSelfTest'; do
  if ! grep -Fq -- "$needle" "$PERCPU_SWIFT"; then
    echo "FAIL: S5a per-CPU utilization state missing $needle." >&2
    exit 1
  fi
done

if ! grep -Fq 'private let sysInfoLegacySize = 64' "$PROCESS_SWIFT" ||
   ! grep -Fq 'private let sysInfoCpuMax = 8' "$PROCESS_SWIFT" ||
   ! grep -Fq 'private let sysInfoSize = sysInfoLegacySize + 8 + (sysInfoCpuMax * 16)' "$PROCESS_SWIFT" ||
   ! grep -Fq 'func processSysInfo(buffer: UInt, capacity: UInt) -> Int' "$PROCESS_SWIFT" ||
   ! grep -Fq 'capacity == 0 ? UInt(sysInfoLegacySize) : capacity' "$PROCESS_SWIFT" ||
   ! grep -Fq 'raw.storeBytes(of: UInt32(0), toByteOffset: 60, as: UInt32.self)' "$PROCESS_SWIFT" ||
   ! grep -Fq 'raw.storeBytes(of: cpuCount, toByteOffset: 64, as: UInt32.self)' "$PROCESS_SWIFT" ||
   ! grep -Fq 'raw.storeBytes(of: UInt32(sysInfoCpuMax), toByteOffset: 68, as: UInt32.self)' "$PROCESS_SWIFT" ||
   ! grep -Fq 'raw.storeBytes(of: ticks, toByteOffset: 72 + (cpu * 8), as: UInt64.self)' "$PROCESS_SWIFT" ||
   ! grep -Fq 'raw.storeBytes(of: idle, toByteOffset: 72 + (sysInfoCpuMax * 8) + (cpu * 8), as: UInt64.self)' "$PROCESS_SWIFT" ||
   ! grep -Fq 'processSysInfo(buffer: frame[0], capacity: frame[1])' "$ROOT/kernel/syscall/syscall.swift"; then
  echo "FAIL: S5a SYS_sysinfo must export cpuCount plus per-CPU timer/idle ticks." >&2
  exit 1
fi

if ! grep -Fq 'if !smpPerCpuUtilizationSelfTest(platform.cpuCount)' "$MAIN_SWIFT" ||
   ! grep -Fq 'S5a OK: per-CPU utilization counters ready' "$MAIN_SWIFT" ||
   ! grep -Fq 'smpRecordIdleTickForCurrentCpu()' "$MAIN_SWIFT"; then
  echo "FAIL: S5a boot/IRQ path must publish utilization readiness and parked-secondary idle ticks." >&2
  exit 1
fi

for needle in \
  '#define SWIFTOS_CPU_MAX 8' \
  'unsigned int  swiftos_sys_cpu_count(void);' \
  'unsigned int  swiftos_sys_cpu_capacity(void);' \
  'unsigned long swiftos_sys_cpu_ticks(unsigned int cpu);' \
  'unsigned long swiftos_sys_cpu_idle_ticks(unsigned int cpu);'; do
  if ! grep -Fq -- "$needle" "$SWIFT_USER_H"; then
    echo "FAIL: S5a swift_user.h missing sysinfo accessor: $needle." >&2
    exit 1
  fi
done

for needle in \
  'unsigned int  cpu_count;' \
  'unsigned int  cpu_capacity;' \
  'unsigned long cpu_ticks[SWIFTOS_CPU_MAX];' \
  'unsigned long cpu_idle_ticks[SWIFTOS_CPU_MAX];' \
  'return (int)__syscall3(SYS_SYSINFO, (long)&g_sys, sizeof(g_sys), 0);' \
  'swiftos_sys_cpu_count' \
  'swiftos_sys_cpu_capacity' \
  'swiftos_sys_cpu_ticks' \
  'swiftos_sys_cpu_idle_ticks'; do
  if ! grep -Fq -- "$needle" "$SWIFT_USER_C"; then
    echo "FAIL: S5a swift_user.c missing sysinfo ABI field/accessor: $needle." >&2
    exit 1
  fi
done

for needle in \
  '| 46 | `sysinfo` | `buffer`, `capacity` | 0 or negative error |' \
  '`sysinfo(buffer, capacity)` writes a system stats blob' \
  'A capacity of 0 requests the legacy 64-byte layout.' \
  'A capacity of at least 200 bytes requests the full S5 layout' \
  '#define SWIFTOS_CPU_MAX 8' \
  'unsigned int cpu_count;' \
  'unsigned int cpu_capacity;' \
  'unsigned long cpu_ticks[SWIFTOS_CPU_MAX];' \
  'unsigned long cpu_idle_ticks[SWIFTOS_CPU_MAX];' \
  'unsigned int swiftos_sys_cpu_count(void);' \
  'unsigned int swiftos_sys_cpu_capacity(void);' \
  'unsigned long swiftos_sys_cpu_ticks(unsigned int cpu);' \
  'unsigned long swiftos_sys_cpu_idle_ticks(unsigned int cpu);'; do
  if ! grep -Fq -- "$needle" "$API_REFERENCE"; then
    echo "FAIL: S5a API_REFERENCE.md missing sysinfo ABI detail: $needle." >&2
    exit 1
  fi
done

for needle in \
  'private let cpuMax = 8' \
  'swiftos_sys_cpu_count()' \
  'swiftos_sys_cpu_ticks(UInt32(cpuIndex))' \
  'swiftos_sys_cpu_idle_ticks(UInt32(cpuIndex))' \
  'per-CPU busy:'; do
  if ! grep -Fq -- "$needle" "$TOP_SWIFT"; then
    echo "FAIL: S5a /bin/top missing per-CPU utilization rendering: $needle." >&2
    exit 1
  fi
done

for needle in \
  'SMP_CPUS="${SMP_CPUS:-1}"' \
  'SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/top_test.sh' \
  'smp-cpu-utilization-test: build $(QEMU_DTB_SMP4) base-image' \
  'CPUs: [0-9]+ present, per-CPU busy'; do
  if ! grep -Fq -- "$needle" "$MAKEFILE" "$ROOT/tests/top_test.sh"; then
    echo "FAIL: S5a top/SMP utilization test wiring missing $needle." >&2
    exit 1
  fi
done

for needle in \
  'lastS5bBatchDispatchTelemetryValid' \
  'captureLastS5bBatchDispatchTelemetry' \
  'func processRunS5bPlacementBatch' \
  'smpCpuOnline(cpu)' \
  'smpPerCpuTimerTicks(cpu) != 0' \
  'let home = pHomeCpu[slot] == unassignedCpu ? processHomeCpuForNewReadySlot(slot) : pHomeCpu[slot]' \
  'pDispatchCpuMask[slot] = 0' \
  'let secondaryHome = secondary == unassignedCpu ? UInt32(0) : secondary' \
  'let cHome: UInt32 = 0' \
  'func processS5bPlacementTelemetrySelfTest' \
  'lastS5bBatchDispatchCpuMaskB != secondaryMask' \
  'lastS5bBatchDispatchCpuMaskC != primaryMask'; do
  if ! grep -Fq -- "$needle" "$PROCESS_SWIFT"; then
    echo "FAIL: S5b process placement telemetry missing $needle." >&2
    exit 1
  fi
done

for needle in \
  'logSinkWrite(currentLogSink, tick: tick, level: level,' \
  'source: source, message: message, detail: detail)' \
  'uartPuts(" detail=")' \
  'uartPutUInt(detail)'; do
  if ! grep -Fq -- "$needle" "$ROOT/kernel/log/log.swift"; then
    echo "FAIL: S5b live klog detail rendering missing $needle." >&2
    exit 1
  fi
done

for needle in \
  'runS5bPlacementDemo' \
  'processRunS5bPlacementBatch' \
  'processS5bPlacementTelemetrySelfTest' \
  'S5b OK: three EL0 processes ran with scheduler placement' \
  'S5b OK: EL0 scheduler placed batch across CPUs' \
  'S5b OK: EL0 scheduler placement CPU0 fallback'; do
  if ! grep -Fq -- "$needle" "$MAIN_SWIFT"; then
    echo "FAIL: S5b boot placement acceptance missing $needle." >&2
    exit 1
  fi
done

for needle in \
  '[I] smp: S5b OK: EL0 scheduler placed batch across CPUs' \
  '[I] smp: S5b OK: EL0 scheduler placement CPU0 fallback' \
  'S5b OK: three EL0 processes ran with scheduler placement'; do
  if ! grep -Fq -- "$needle" "$SMP_BOOT_TEST"; then
    echo "FAIL: S5b SMP boot smoke missing $needle." >&2
    exit 1
  fi
done

for needle in \
  's5-scheduler-placement-test: build $(QEMU_DTB_SMP4) base-image' \
  'TIMEOUT=180 SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/smp_boot_test.sh'; do
  if ! grep -Fq -- "$needle" "$MAKEFILE"; then
    echo "FAIL: S5b make target missing $needle." >&2
    exit 1
  fi
done

for needle in \
  'private var processRunQueueLockWord' \
  'private var processRunQueueLockAcquireCount' \
  'private func processRunQueueLock(_ cpu: UInt32) -> UInt64' \
  'private func processRunQueueUnlock(_ cpu: UInt32, _ daif: UInt64)' \
  'let daif = processRunQueueLock(cpu)' \
  'processRunQueueUnlock(cpu, daif)' \
  'if cpu != currentCpuId() {' \
  'cpu_sev()' \
  'lastS5cStressTelemetryValid' \
  'captureLastS5cPlacementStressTelemetry' \
  'func processRunS5cPlacementStress' \
  'func processS5cPlacementStressSelfTest' \
  's5cPlacementStressRounds' \
  's5cPlacementStressCpu0TailCount' \
  'lastS5cStressSecondaryCpuMask != secondaryMask'; do
  if ! grep -Fq -- "$needle" "$PROCESS_SWIFT"; then
    echo "FAIL: S5c run queue locking / placement stress missing $needle." >&2
    exit 1
  fi
done

for needle in \
  'runS5cPlacementStressDemo' \
  'processRunS5cPlacementStress' \
  'processS5cPlacementStressSelfTest' \
  'S5c OK: repeated EL0 placement stress completed' \
  'S5c OK: repeated EL0 placement stress crossed CPUs' \
  'S5c OK: repeated EL0 placement stress CPU0 fallback'; do
  if ! grep -Fq -- "$needle" "$MAIN_SWIFT"; then
    echo "FAIL: S5c boot placement-stress acceptance missing $needle." >&2
    exit 1
  fi
done

for needle in \
  '[I] smp: S5c OK: repeated EL0 placement stress crossed CPUs' \
  '[I] smp: S5c OK: repeated EL0 placement stress CPU0 fallback' \
  'S5c OK: repeated EL0 placement stress completed'; do
  if ! grep -Fq -- "$needle" "$SMP_BOOT_TEST"; then
    echo "FAIL: S5c SMP boot smoke missing $needle." >&2
    exit 1
  fi
done

for needle in \
  's5-placement-stress-test: build $(QEMU_DTB_SMP4) base-image' \
  'TIMEOUT=240 SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/smp_boot_test.sh'; do
  if ! grep -Fq -- "$needle" "$MAKEFILE"; then
    echo "FAIL: S5c make target missing $needle." >&2
    exit 1
  fi
done

for needle in \
  'lastS5dFanoutTelemetryValid' \
  'lastS5dFanoutSchedulerCpuMask' \
  'lastS5dFanoutDispatchCpuMask' \
  'lastS5dFanoutExactCpuMatchCount' \
  's5dFanoutSlots' \
  'captureLastS5dFanoutTelemetry' \
  'func processRunS5dFanout' \
  'processStartSecondaryScheduler(cpu: cpu)' \
  'startedSecondaryMask' \
  'schedulerCpuMask |= bit' \
  'func processS5dFanoutSelfTest' \
  'lastS5dFanoutDispatchCpuMask != lastS5dFanoutSchedulerCpuMask' \
  'lastS5dFanoutExactCpuMatchCount != lastS5dFanoutProcessCount'; do
  if ! grep -Fq -- "$needle" "$PROCESS_SWIFT"; then
    echo "FAIL: S5d multi-secondary fanout missing $needle." >&2
    exit 1
  fi
done

for needle in \
  'runS5dFanoutDemo' \
  'processRunS5dFanout' \
  'processS5dFanoutSelfTest' \
  'S5d OK: EL0 fanout ran across scheduler CPUs' \
  'S5d OK: EL0 fanout crossed scheduler CPUs' \
  'S5d OK: EL0 fanout CPU0 fallback'; do
  if ! grep -Fq -- "$needle" "$MAIN_SWIFT"; then
    echo "FAIL: S5d boot fanout acceptance missing $needle." >&2
    exit 1
  fi
done

for needle in \
  '[I] smp: S5d OK: EL0 fanout crossed scheduler CPUs' \
  '[I] smp: S5d OK: EL0 fanout CPU0 fallback' \
  'S5d OK: EL0 fanout ran across scheduler CPUs' \
  'S1/S2a-S2h/S3a-S3d/S4a-S4e/S5a-S5f markers'; do
  if ! grep -Fq -- "$needle" "$SMP_BOOT_TEST"; then
    echo "FAIL: S5d SMP boot smoke missing $needle." >&2
    exit 1
  fi
done

for needle in \
  's5-el0-fanout-test: build $(QEMU_DTB_SMP4) base-image' \
  'TIMEOUT=240 SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/smp_boot_test.sh'; do
  if ! grep -Fq -- "$needle" "$MAKEFILE"; then
    echo "FAIL: S5d make target missing $needle." >&2
    exit 1
  fi
done

for needle in \
  'futexLockWord' \
  'futexLockAcquireCount' \
  'futexLockContentionCount' \
  'private func futexLock()' \
  'private func futexUnlock' \
  'func futexS5eLockBoundaryHeldSelfTest' \
  'func futexS5eWaitTableIdleSelfTest' \
  'processPrepareBlockOnFutex' \
  'processYieldAfterPreparedFutexBlock'; do
  if ! grep -Fq -- "$needle" "$FUTEX_SWIFT" "$PROCESS_SWIFT"; then
    echo "FAIL: S5e futex SMP boundary missing $needle." >&2
    exit 1
  fi
done

for needle in \
  'lastS5eThreadFanoutTelemetryValid' \
  'lastS5eThreadSharedAddressSpaceCount' \
  'lastS5eThreadSecondaryCpuMask' \
  'lastS5eThreadFutexLockAcquireCount' \
  's5eThreadPlacementActive' \
  's5eThreadTelemetryLockWord' \
  'processNextS5eThreadHomeCpu' \
  'recordS5eThreadCreate' \
  'recordS5eThreadExit' \
  'func processRunS5eThreadFanout' \
  'processRunS5eThreadFanout' \
  'func processS5eThreadFanoutSelfTest' \
  'lastS5eThreadSharedAddressSpaceCount != 2' \
  'lastS5eThreadDispatchCpuMask != lastS5eThreadHomeCpuMask' \
  'futexS5eLockBoundaryHeldSelfTest' \
  'futexS5eWaitTableIdleSelfTest'; do
  if ! grep -Fq -- "$needle" "$PROCESS_SWIFT"; then
    echo "FAIL: S5e shared-address-space thread fanout missing $needle." >&2
    exit 1
  fi
done

for needle in \
  'runS5eThreadFanoutDemo' \
  'processRunS5eThreadFanout' \
  'processS5eThreadFanoutSelfTest' \
  'S5e OK: shared-address-space thread fanout completed' \
  'S5e OK: shared-address-space threads crossed CPUs' \
  'S5e OK: shared-address-space thread fanout CPU0 fallback'; do
  if ! grep -Fq -- "$needle" "$MAIN_SWIFT"; then
    echo "FAIL: S5e boot thread-fanout acceptance missing $needle." >&2
    exit 1
  fi
done

for needle in \
  '[I] smp: S5e OK: shared-address-space threads crossed CPUs' \
  '[I] smp: S5e OK: shared-address-space thread fanout CPU0 fallback' \
  'S5e OK: shared-address-space thread fanout completed' \
  'S1/S2a-S2h/S3a-S3d/S4a-S4e/S5a-S5f markers'; do
  if ! grep -Fq -- "$needle" "$SMP_BOOT_TEST"; then
    echo "FAIL: S5e SMP boot smoke missing $needle." >&2
    exit 1
  fi
done

for needle in \
  's5-thread-fanout-test: build $(QEMU_DTB_SMP4) base-image' \
  'TIMEOUT=240 SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/smp_boot_test.sh'; do
  if ! grep -Fq -- "$needle" "$MAKEFILE"; then
    echo "FAIL: S5e make target missing $needle." >&2
    exit 1
  fi
done

for needle in \
  'lastS5fRunAnyTelemetryValid' \
  'lastS5fRunAnySchedulerCpuMask' \
  'lastS5fRunAnyDispatchCpuMask' \
  'lastS5fRunAnyPolicySelectionCount' \
  's5fRunAnyPlacementActive' \
  's5fRunAnySlots' \
  'processNextS5fRunAnyHomeCpu' \
  'processSecondarySchedulerCanTickForCurrentCpu' \
  'captureLastS5fRunAnyTelemetry' \
  'func processRunS5fRunAnyPlacement' \
  'homeCpu: unassignedCpu' \
  'func processS5fRunAnyPlacementSelfTest' \
  'lastS5fRunAnyPolicySelectionCount != lastS5fRunAnyProcessCount' \
  'lastS5fRunAnyDispatchCpuMask != lastS5fRunAnySchedulerCpuMask' \
  'lastS5fRunAnyExactCpuMatchCount != lastS5fRunAnyProcessCount'; do
  if ! grep -Fq -- "$needle" "$PROCESS_SWIFT"; then
    echo "FAIL: S5f run-any placement policy missing $needle." >&2
    exit 1
  fi
done

for needle in \
  'runS5fRunAnyPlacementDemo' \
  'processRunS5fRunAnyPlacement' \
  'processS5fRunAnyPlacementSelfTest' \
  'S5f OK: run-any placement policy completed' \
  'S5f OK: run-any placement covered scheduler CPUs' \
  'S5f OK: run-any placement CPU0 fallback'; do
  if ! grep -Fq -- "$needle" "$MAIN_SWIFT"; then
    echo "FAIL: S5f boot run-any placement acceptance missing $needle." >&2
    exit 1
  fi
done

for needle in \
  '[I] smp: S5f OK: run-any placement covered scheduler CPUs' \
  '[I] smp: S5f OK: run-any placement CPU0 fallback' \
  'S5f OK: run-any placement policy completed' \
  'S1/S2a-S2h/S3a-S3d/S4a-S4e/S5a-S5f markers'; do
  if ! grep -Fq -- "$needle" "$SMP_BOOT_TEST"; then
    echo "FAIL: S5f SMP boot smoke missing $needle." >&2
    exit 1
  fi
done

for needle in \
  's5-run-any-placement-test: build $(QEMU_DTB_SMP4) base-image' \
  'TIMEOUT=240 SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/smp_boot_test.sh'; do
  if ! grep -Fq -- "$needle" "$MAKEFILE"; then
    echo "FAIL: S5f make target missing $needle." >&2
    exit 1
  fi
done

echo "PASS: S1/S2a-S2h/S3a-S3d/S4a-S4f/S5a-S5f release-readiness contract holds (PSCI CPU_ON + restricted multi-CPU EL0 dispatch + scheduler/IPI/TLB/PMM/VFS/heap/package-store/network boundary + resource stress + per-CPU utilization export + placement batch + repeated placement stress + EL0 fanout + shared-address-space thread fanout + run-any EL0 placement policy)"
