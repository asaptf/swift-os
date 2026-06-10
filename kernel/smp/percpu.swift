// SPDX-License-Identifier: Apache-2.0
// percpu.swift - fixed per-CPU state scaffold for SMP bring-up.
//
// The storage stays heap-free and fixed-size so secondary CPUs can mark their
// own early state without touching allocator-backed scheduler/VFS structures.

private let smpMaxCpus = 8

private let smpCpuFlagInitialized: UInt64 = 1 << 0
private let smpCpuFlagOnline: UInt64 = 1 << 1
private let smpCpuFlagKernelSchedulerReady: UInt64 = 1 << 2
private let smpNoThread: Int32 = -1
private let smpNoProcess: Int32 = -1
private let smpUninitializedCpu: UInt32 = 0xFFFF_FFFF

@_alignment(16) private struct SMPPerCpuState {
    var flags: UInt64 = 0
    var logicalId: UInt32 = smpUninitializedCpu
    var kernelSchedulerActivityCount: UInt32 = 0
    var timerTicks: UInt64 = 0
    var idleTicks: UInt64 = 0
    var currentThread: Int32 = smpNoThread
    var currentProcess: Int32 = smpNoProcess
    var runQueueHead: Int32 = smpNoThread
    var runQueueTail: Int32 = smpNoThread
    var schedulerContext: UInt = 0
    var el0SwitchCount: UInt64 = 0
}

// Fixed static storage: no Swift Array, no heap, and safe to address before any
// future secondary CPU is allowed to call allocator-backed code.
private var smpCpuState: InlineArray<8, SMPPerCpuState> = .init(repeating: SMPPerCpuState())
private var smpIpiReceivedCount: InlineArray<8, UInt64> = .init(repeating: 0)
private var smpIpiLastSourceCpu: InlineArray<8, UInt64> = .init(repeating: UInt64.max)
private var smpIpiProbeTargetMaskStorage: UInt64 = 0
private var smpIpiProbeDeliveredMaskStorage: UInt64 = 0
private var smpTlbShootdownRequestGeneration: InlineArray<8, UInt64> = .init(repeating: 0)
private var smpTlbShootdownAckGeneration: InlineArray<8, UInt64> = .init(repeating: 0)
private var smpTlbShootdownReceivedCount: InlineArray<8, UInt64> = .init(repeating: 0)
private var smpTlbShootdownProbeGenerationStorage: UInt64 = 0
private var smpTlbShootdownProbeTargetMaskStorage: UInt64 = 0
private var smpTlbShootdownProbeAckMaskStorage: UInt64 = 0
private var smpPmmStressRequestGeneration: InlineArray<8, UInt64> = .init(repeating: 0)
private var smpPmmStressAckGeneration: InlineArray<8, UInt64> = .init(repeating: 0)
private var smpPmmStressReceivedCount: InlineArray<8, UInt64> = .init(repeating: 0)
private var smpPmmStressProbeGenerationStorage: UInt64 = 0
private var smpPmmStressProbeTargetMaskStorage: UInt64 = 0
private var smpPmmStressProbeAckMaskStorage: UInt64 = 0
private var smpPmmStressProbeFailureMaskStorage: UInt64 = 0

@inline(__always)
private func smpValidCpu(_ cpu: UInt32) -> Bool {
    cpu < UInt32(smpMaxCpus)
}

@inline(__always)
func smpMaxCpuCount() -> UInt32 {
    UInt32(smpMaxCpus)
}

func smpEarlyInitCurrentCpu() -> Bool {
    let cpu = currentCpuId()
    if !smpValidCpu(cpu) { return false }

    let idx = Int(cpu)
    smpCpuState[idx].flags = 0
    smpCpuState[idx].logicalId = cpu
    smpCpuState[idx].kernelSchedulerActivityCount = 0
    smpCpuState[idx].timerTicks = 0
    smpCpuState[idx].idleTicks = 0
    smpCpuState[idx].currentThread = smpNoThread
    smpCpuState[idx].currentProcess = smpNoProcess
    smpCpuState[idx].runQueueHead = smpNoThread
    smpCpuState[idx].runQueueTail = smpNoThread
    smpCpuState[idx].schedulerContext = 0
    smpCpuState[idx].el0SwitchCount = 0

    withUnsafeMutablePointer(to: &smpCpuState[idx].flags) { flags in
        smpAtomicStore(flags, smpCpuFlagInitialized)
    }
    return true
}

func smpCpuInitialized(_ cpu: UInt32) -> Bool {
    if !smpValidCpu(cpu) { return false }
    let idx = Int(cpu)
    let flags = withUnsafeMutablePointer(to: &smpCpuState[idx].flags) { flags in
        smpAtomicLoad(flags)
    }
    return (flags & smpCpuFlagInitialized) != 0 && smpCpuState[idx].logicalId == cpu
}

func smpMarkCurrentCpuOnline() {
    let cpu = currentCpuId()
    if !smpValidCpu(cpu) { return }
    let idx = Int(cpu)
    withUnsafeMutablePointer(to: &smpCpuState[idx].flags) { flags in
        let current = smpAtomicLoad(flags)
        smpAtomicStore(flags, current | smpCpuFlagInitialized | smpCpuFlagOnline)
    }
}

func smpCpuOnline(_ cpu: UInt32) -> Bool {
    if !smpValidCpu(cpu) { return false }
    let idx = Int(cpu)
    let flags = withUnsafeMutablePointer(to: &smpCpuState[idx].flags) { flags in
        smpAtomicLoad(flags)
    }
    return (flags & smpCpuFlagOnline) != 0 && smpCpuState[idx].logicalId == cpu
}

func smpMarkKernelSchedulerReadyForCurrentCpu() {
    let cpu = currentCpuId()
    if !smpValidCpu(cpu) { return }
    let idx = Int(cpu)
    withUnsafeMutablePointer(to: &smpCpuState[idx].flags) { flags in
        let current = smpAtomicLoad(flags)
        smpAtomicStore(flags, current | smpCpuFlagKernelSchedulerReady)
    }
}

func smpSetCurrentThreadForCurrentCpu(_ thread: Int32) {
    let cpu = currentCpuId()
    if !smpValidCpu(cpu) { return }
    smpCpuState[Int(cpu)].currentThread = thread
}

func smpSetCurrentProcessForCurrentCpu(_ process: Int32) {
    let cpu = currentCpuId()
    if !smpValidCpu(cpu) { return }
    smpCpuState[Int(cpu)].currentProcess = process
}

@discardableResult
func smpSetProcessSchedulerContextForCpu(_ cpu: UInt32, _ context: UInt) -> Bool {
    if !smpValidCpu(cpu) { return false }
    smpCpuState[Int(cpu)].schedulerContext = context
    return true
}

func smpSetProcessSchedulerContextForCurrentCpu(_ context: UInt) {
    _ = smpSetProcessSchedulerContextForCpu(currentCpuId(), context)
}

@discardableResult
func smpSetProcessRunQueueForCpu(_ cpu: UInt32, head: Int32, tail: Int32) -> Bool {
    if !smpValidCpu(cpu) { return false }
    let idx = Int(cpu)
    smpCpuState[idx].runQueueHead = head
    smpCpuState[idx].runQueueTail = tail
    return true
}

func smpSetProcessRunQueueForCurrentCpu(head: Int32, tail: Int32) {
    _ = smpSetProcessRunQueueForCpu(currentCpuId(), head: head, tail: tail)
}

func smpRecordEl0SwitchForCurrentCpu() {
    let cpu = currentCpuId()
    if !smpValidCpu(cpu) { return }
    smpCpuState[Int(cpu)].el0SwitchCount &+= 1
}

func smpRecordKernelSchedulerActivityForCurrentCpu() {
    let cpu = currentCpuId()
    if !smpValidCpu(cpu) { return }
    smpCpuState[Int(cpu)].kernelSchedulerActivityCount &+= 1
}

func smpRecordTimerTickForCurrentCpu() {
    let cpu = currentCpuId()
    if !smpValidCpu(cpu) { return }
    smpCpuState[Int(cpu)].timerTicks &+= 1
}

func smpPerCpuTimerTicks(_ cpu: UInt32) -> UInt64 {
    if !smpValidCpu(cpu) { return 0 }
    return smpCpuState[Int(cpu)].timerTicks
}

func smpPerCpuHasCurrentThread(_ cpu: UInt32) -> Bool {
    if !smpValidCpu(cpu) { return false }
    return smpCpuState[Int(cpu)].currentThread != smpNoThread
}

func smpPerCpuCurrentThreadIs(_ cpu: UInt32, _ thread: Int32) -> Bool {
    if !smpValidCpu(cpu) { return false }
    return smpCpuState[Int(cpu)].currentThread == thread
}

func smpPerCpuProcessIdle(_ cpu: UInt32) -> Bool {
    if !smpValidCpu(cpu) { return false }
    return smpCpuState[Int(cpu)].currentProcess == smpNoProcess
}

func smpPerCpuProcessSchedulerContextReady(_ cpu: UInt32) -> Bool {
    if !smpValidCpu(cpu) { return false }
    return smpCpuState[Int(cpu)].schedulerContext != 0
}

func smpPerCpuProcessSchedulerContext(_ cpu: UInt32) -> UInt {
    if !smpValidCpu(cpu) { return 0 }
    return smpCpuState[Int(cpu)].schedulerContext
}

func smpPerCpuProcessRunQueueIdle(_ cpu: UInt32) -> Bool {
    if !smpValidCpu(cpu) { return false }
    let state = smpCpuState[Int(cpu)]
    return state.runQueueHead == smpNoThread && state.runQueueTail == smpNoThread
}

func smpPerCpuProcessRunQueueHead(_ cpu: UInt32) -> Int32 {
    if !smpValidCpu(cpu) { return smpNoThread }
    return smpCpuState[Int(cpu)].runQueueHead
}

func smpPerCpuProcessRunQueueTail(_ cpu: UInt32) -> Int32 {
    if !smpValidCpu(cpu) { return smpNoThread }
    return smpCpuState[Int(cpu)].runQueueTail
}

func smpPerCpuEl0SwitchCount(_ cpu: UInt32) -> UInt64 {
    if !smpValidCpu(cpu) { return 0 }
    return smpCpuState[Int(cpu)].el0SwitchCount
}

func smpRecordIpiForCurrentCpu(source: UInt32) {
    let cpu = currentCpuId()
    if !smpValidCpu(cpu) { return }
    let idx = Int(cpu)
    withUnsafeMutablePointer(to: &smpIpiLastSourceCpu[idx]) { lastSource in
        smpAtomicStore(lastSource, UInt64(source))
    }
    withUnsafeMutablePointer(to: &smpIpiReceivedCount[idx]) { count in
        _ = smpAtomicFetchAdd(count, 1)
    }
}

func smpPerCpuIpiReceivedCount(_ cpu: UInt32) -> UInt64 {
    if !smpValidCpu(cpu) { return 0 }
    return withUnsafeMutablePointer(to: &smpIpiReceivedCount[Int(cpu)]) { count in
        smpAtomicLoad(count)
    }
}

func smpPerCpuIpiLastSource(_ cpu: UInt32) -> UInt64 {
    if !smpValidCpu(cpu) { return UInt64.max }
    return withUnsafeMutablePointer(to: &smpIpiLastSourceCpu[Int(cpu)]) { source in
        smpAtomicLoad(source)
    }
}

func smpResetIpiProbe(targetMask: UInt64) {
    withUnsafeMutablePointer(to: &smpIpiProbeTargetMaskStorage) { mask in
        smpAtomicStore(mask, targetMask)
    }
    withUnsafeMutablePointer(to: &smpIpiProbeDeliveredMaskStorage) { mask in
        smpAtomicStore(mask, 0)
    }
}

func smpMarkIpiProbeDelivered(cpu: UInt32) {
    if !smpValidCpu(cpu) { return }
    let bit = UInt64(1) << UInt64(cpu)
    withUnsafeMutablePointer(to: &smpIpiProbeDeliveredMaskStorage) { mask in
        var current = smpAtomicLoad(mask)
        while true {
            var expected = current
            let desired = current | bit
            if smpAtomicCompareExchange(mask, expected: &expected, desired: desired) {
                break
            }
            current = expected
        }
    }
}

func smpIpiProbeTargetMask() -> UInt64 {
    withUnsafeMutablePointer(to: &smpIpiProbeTargetMaskStorage) { mask in
        smpAtomicLoad(mask)
    }
}

func smpIpiProbeDeliveredMask() -> UInt64 {
    withUnsafeMutablePointer(to: &smpIpiProbeDeliveredMaskStorage) { mask in
        smpAtomicLoad(mask)
    }
}

func smpPerCpuTlbShootdownReceivedCount(_ cpu: UInt32) -> UInt64 {
    if !smpValidCpu(cpu) { return 0 }
    return withUnsafeMutablePointer(to: &smpTlbShootdownReceivedCount[Int(cpu)]) { count in
        smpAtomicLoad(count)
    }
}

func smpPerCpuTlbShootdownRequestGeneration(_ cpu: UInt32) -> UInt64 {
    if !smpValidCpu(cpu) { return 0 }
    return withUnsafeMutablePointer(to: &smpTlbShootdownRequestGeneration[Int(cpu)]) { generation in
        smpAtomicLoad(generation)
    }
}

func smpPerCpuTlbShootdownAckGeneration(_ cpu: UInt32) -> UInt64 {
    if !smpValidCpu(cpu) { return 0 }
    return withUnsafeMutablePointer(to: &smpTlbShootdownAckGeneration[Int(cpu)]) { generation in
        smpAtomicLoad(generation)
    }
}

func smpBeginTlbShootdownProbe(targetMask: UInt64) -> UInt64 {
    let generation = withUnsafeMutablePointer(to: &smpTlbShootdownProbeGenerationStorage) { current in
        smpAtomicFetchAdd(current, 1) &+ 1
    }
    withUnsafeMutablePointer(to: &smpTlbShootdownProbeTargetMaskStorage) { mask in
        smpAtomicStore(mask, targetMask)
    }
    withUnsafeMutablePointer(to: &smpTlbShootdownProbeAckMaskStorage) { mask in
        smpAtomicStore(mask, 0)
    }
    smpStoreBarrier()
    return generation
}

@discardableResult
func smpPublishTlbShootdownRequest(cpu: UInt32, generation: UInt64) -> Bool {
    if generation == 0 || !smpValidCpu(cpu) { return false }
    withUnsafeMutablePointer(to: &smpTlbShootdownRequestGeneration[Int(cpu)]) { request in
        smpAtomicStore(request, generation)
    }
    smpStoreBarrier()
    return true
}

func smpMarkTlbShootdownProbeAcked(cpu: UInt32) {
    if !smpValidCpu(cpu) { return }
    let bit = UInt64(1) << UInt64(cpu)
    withUnsafeMutablePointer(to: &smpTlbShootdownProbeAckMaskStorage) { mask in
        var current = smpAtomicLoad(mask)
        while true {
            var expected = current
            let desired = current | bit
            if smpAtomicCompareExchange(mask, expected: &expected, desired: desired) {
                break
            }
            current = expected
        }
    }
}

func smpHandleTlbShootdownForCurrentCpu() -> Bool {
    let cpu = currentCpuId()
    if !smpValidCpu(cpu) { return false }
    let idx = Int(cpu)
    let request = withUnsafeMutablePointer(to: &smpTlbShootdownRequestGeneration[idx]) { generation in
        smpAtomicLoad(generation)
    }
    if request == 0 { return false }
    let ack = withUnsafeMutablePointer(to: &smpTlbShootdownAckGeneration[idx]) { generation in
        smpAtomicLoad(generation)
    }
    if ack == request { return false }

    tlbi_all()
    withUnsafeMutablePointer(to: &smpTlbShootdownAckGeneration[idx]) { generation in
        smpAtomicStore(generation, request)
    }
    withUnsafeMutablePointer(to: &smpTlbShootdownReceivedCount[idx]) { count in
        _ = smpAtomicFetchAdd(count, 1)
    }
    smpMarkTlbShootdownProbeAcked(cpu: cpu)
    return true
}

func smpTlbShootdownProbeTargetMask() -> UInt64 {
    withUnsafeMutablePointer(to: &smpTlbShootdownProbeTargetMaskStorage) { mask in
        smpAtomicLoad(mask)
    }
}

func smpTlbShootdownProbeAckMask() -> UInt64 {
    withUnsafeMutablePointer(to: &smpTlbShootdownProbeAckMaskStorage) { mask in
        smpAtomicLoad(mask)
    }
}

func smpPerCpuPmmStressReceivedCount(_ cpu: UInt32) -> UInt64 {
    if !smpValidCpu(cpu) { return 0 }
    return withUnsafeMutablePointer(to: &smpPmmStressReceivedCount[Int(cpu)]) { count in
        smpAtomicLoad(count)
    }
}

func smpPerCpuPmmStressRequestGeneration(_ cpu: UInt32) -> UInt64 {
    if !smpValidCpu(cpu) { return 0 }
    return withUnsafeMutablePointer(to: &smpPmmStressRequestGeneration[Int(cpu)]) { generation in
        smpAtomicLoad(generation)
    }
}

func smpPerCpuPmmStressAckGeneration(_ cpu: UInt32) -> UInt64 {
    if !smpValidCpu(cpu) { return 0 }
    return withUnsafeMutablePointer(to: &smpPmmStressAckGeneration[Int(cpu)]) { generation in
        smpAtomicLoad(generation)
    }
}

func smpBeginPmmStressProbe(targetMask: UInt64) -> UInt64 {
    let generation = withUnsafeMutablePointer(to: &smpPmmStressProbeGenerationStorage) { current in
        smpAtomicFetchAdd(current, 1) &+ 1
    }
    withUnsafeMutablePointer(to: &smpPmmStressProbeTargetMaskStorage) { mask in
        smpAtomicStore(mask, targetMask)
    }
    withUnsafeMutablePointer(to: &smpPmmStressProbeAckMaskStorage) { mask in
        smpAtomicStore(mask, 0)
    }
    withUnsafeMutablePointer(to: &smpPmmStressProbeFailureMaskStorage) { mask in
        smpAtomicStore(mask, 0)
    }
    smpStoreBarrier()
    return generation
}

@discardableResult
func smpPublishPmmStressRequest(cpu: UInt32, generation: UInt64) -> Bool {
    if generation == 0 || !smpValidCpu(cpu) { return false }
    withUnsafeMutablePointer(to: &smpPmmStressRequestGeneration[Int(cpu)]) { request in
        smpAtomicStore(request, generation)
    }
    smpStoreBarrier()
    return true
}

private func smpMarkPmmStressProbeAcked(cpu: UInt32) {
    if !smpValidCpu(cpu) { return }
    let bit = UInt64(1) << UInt64(cpu)
    withUnsafeMutablePointer(to: &smpPmmStressProbeAckMaskStorage) { mask in
        var current = smpAtomicLoad(mask)
        while true {
            var expected = current
            let desired = current | bit
            if smpAtomicCompareExchange(mask, expected: &expected, desired: desired) {
                break
            }
            current = expected
        }
    }
}

private func smpMarkPmmStressProbeFailed(cpu: UInt32) {
    if !smpValidCpu(cpu) { return }
    let bit = UInt64(1) << UInt64(cpu)
    withUnsafeMutablePointer(to: &smpPmmStressProbeFailureMaskStorage) { mask in
        var current = smpAtomicLoad(mask)
        while true {
            var expected = current
            let desired = current | bit
            if smpAtomicCompareExchange(mask, expected: &expected, desired: desired) {
                break
            }
            current = expected
        }
    }
}

func smpHandlePmmStressForCurrentCpu() -> Bool {
    let cpu = currentCpuId()
    if !smpValidCpu(cpu) { return false }
    let idx = Int(cpu)
    let request = withUnsafeMutablePointer(to: &smpPmmStressRequestGeneration[idx]) { generation in
        smpAtomicLoad(generation)
    }
    if request == 0 { return false }
    let ack = withUnsafeMutablePointer(to: &smpPmmStressAckGeneration[idx]) { generation in
        smpAtomicLoad(generation)
    }
    if ack == request { return false }

    if !pmmS4aBoundedStressForCurrentCpu() {
        smpMarkPmmStressProbeFailed(cpu: cpu)
    }
    withUnsafeMutablePointer(to: &smpPmmStressAckGeneration[idx]) { generation in
        smpAtomicStore(generation, request)
    }
    withUnsafeMutablePointer(to: &smpPmmStressReceivedCount[idx]) { count in
        _ = smpAtomicFetchAdd(count, 1)
    }
    smpMarkPmmStressProbeAcked(cpu: cpu)
    return true
}

func smpPmmStressProbeTargetMask() -> UInt64 {
    withUnsafeMutablePointer(to: &smpPmmStressProbeTargetMaskStorage) { mask in
        smpAtomicLoad(mask)
    }
}

func smpPmmStressProbeAckMask() -> UInt64 {
    withUnsafeMutablePointer(to: &smpPmmStressProbeAckMaskStorage) { mask in
        smpAtomicLoad(mask)
    }
}

func smpPmmStressProbeFailureMask() -> UInt64 {
    withUnsafeMutablePointer(to: &smpPmmStressProbeFailureMaskStorage) { mask in
        smpAtomicLoad(mask)
    }
}

func smpPerCpuKernelSchedulerReady(_ cpu: UInt32) -> Bool {
    if !smpValidCpu(cpu) { return false }
    let idx = Int(cpu)
    let flags = withUnsafeMutablePointer(to: &smpCpuState[idx].flags) { flags in
        smpAtomicLoad(flags)
    }
    return (flags & smpCpuFlagOnline) != 0 &&
           (flags & smpCpuFlagKernelSchedulerReady) != 0 &&
           smpCpuState[idx].logicalId == cpu &&
           smpCpuState[idx].currentThread != smpNoThread
}

func smpPerCpuKernelSchedulerActivityCount(_ cpu: UInt32) -> UInt32 {
    if !smpValidCpu(cpu) { return 0 }
    return smpCpuState[Int(cpu)].kernelSchedulerActivityCount
}

func smpPerCpuSchedulerIdle(_ cpu: UInt32) -> Bool {
    if !smpValidCpu(cpu) { return false }
    let idx = Int(cpu)
    let state = smpCpuState[idx]
    let flags = withUnsafeMutablePointer(to: &smpCpuState[idx].flags) { flags in
        smpAtomicLoad(flags)
    }
    return state.currentThread == smpNoThread &&
           state.currentProcess == smpNoProcess &&
           state.runQueueHead == smpNoThread &&
           state.runQueueTail == smpNoThread &&
           state.kernelSchedulerActivityCount == 0 &&
           state.el0SwitchCount == 0 &&
           (flags & smpCpuFlagKernelSchedulerReady) == 0
}

func smpPerCpuSelfTest() -> Bool {
    if smpMaxCpuCount() != 8 { return false }
    if MemoryLayout<SMPPerCpuState>.stride != 64 { return false }

    let aligned = withUnsafePointer(to: &smpCpuState) { table in
        (UInt(bitPattern: table) & 0xF) == 0
    }
    if !aligned { return false }

    var slot = 0
    while slot < smpMaxCpus {
        smpCpuState[slot].flags = 0
        smpCpuState[slot].logicalId = UInt32(slot)
        smpCpuState[slot].timerTicks = UInt64(slot)
        smpCpuState[slot].currentThread = Int32(slot)
        smpCpuState[slot].currentProcess = Int32(slot + 1)
        smpCpuState[slot].runQueueHead = Int32(slot + 2)
        smpCpuState[slot].runQueueTail = Int32(slot + 3)
        smpCpuState[slot].schedulerContext = UInt(slot + 1)
        smpCpuState[slot].kernelSchedulerActivityCount = UInt32(slot + 4)
        smpCpuState[slot].el0SwitchCount = UInt64(slot + 5)
        smpIpiReceivedCount[slot] = UInt64(slot + 6)
        smpIpiLastSourceCpu[slot] = UInt64(slot + 7)
        smpTlbShootdownRequestGeneration[slot] = UInt64(slot + 8)
        smpTlbShootdownAckGeneration[slot] = UInt64(slot + 9)
        smpTlbShootdownReceivedCount[slot] = UInt64(slot + 10)
        smpPmmStressRequestGeneration[slot] = UInt64(slot + 11)
        smpPmmStressAckGeneration[slot] = UInt64(slot + 12)
        smpPmmStressReceivedCount[slot] = UInt64(slot + 13)
        if smpCpuState[slot].logicalId != UInt32(slot) { return false }
        if smpCpuState[slot].timerTicks != UInt64(slot) { return false }
        if smpCpuState[slot].currentThread != Int32(slot) { return false }
        if smpCpuState[slot].currentProcess != Int32(slot + 1) { return false }
        if smpCpuState[slot].runQueueHead != Int32(slot + 2) { return false }
        if smpCpuState[slot].runQueueTail != Int32(slot + 3) { return false }
        if smpCpuState[slot].schedulerContext != UInt(slot + 1) { return false }
        if smpCpuState[slot].kernelSchedulerActivityCount != UInt32(slot + 4) { return false }
        if smpCpuState[slot].el0SwitchCount != UInt64(slot + 5) { return false }
        if smpPerCpuIpiReceivedCount(UInt32(slot)) != UInt64(slot + 6) { return false }
        if smpPerCpuIpiLastSource(UInt32(slot)) != UInt64(slot + 7) { return false }
        if smpPerCpuTlbShootdownRequestGeneration(UInt32(slot)) != UInt64(slot + 8) { return false }
        if smpPerCpuTlbShootdownAckGeneration(UInt32(slot)) != UInt64(slot + 9) { return false }
        if smpPerCpuTlbShootdownReceivedCount(UInt32(slot)) != UInt64(slot + 10) { return false }
        if smpPerCpuPmmStressRequestGeneration(UInt32(slot)) != UInt64(slot + 11) { return false }
        if smpPerCpuPmmStressAckGeneration(UInt32(slot)) != UInt64(slot + 12) { return false }
        if smpPerCpuPmmStressReceivedCount(UInt32(slot)) != UInt64(slot + 13) { return false }
        smpCpuState[slot] = SMPPerCpuState()
        smpIpiReceivedCount[slot] = 0
        smpIpiLastSourceCpu[slot] = UInt64.max
        smpTlbShootdownRequestGeneration[slot] = 0
        smpTlbShootdownAckGeneration[slot] = 0
        smpTlbShootdownReceivedCount[slot] = 0
        smpPmmStressRequestGeneration[slot] = 0
        smpPmmStressAckGeneration[slot] = 0
        smpPmmStressReceivedCount[slot] = 0
        slot += 1
    }

    if !smpEarlyInitCurrentCpu() { return false }

    let cpu = currentCpuId()
    if !smpCpuInitialized(cpu) { return false }

    let idx = Int(cpu)
    let savedTicks = smpCpuState[idx].timerTicks
    let savedThread = smpCpuState[idx].currentThread
    let savedProcess = smpCpuState[idx].currentProcess
    let savedRunQueueHead = smpCpuState[idx].runQueueHead
    let savedRunQueueTail = smpCpuState[idx].runQueueTail
    let savedSchedulerContext = smpCpuState[idx].schedulerContext
    let savedKernelSchedulerActivityCount = smpCpuState[idx].kernelSchedulerActivityCount
    let savedEl0SwitchCount = smpCpuState[idx].el0SwitchCount
    let savedIpiReceivedCount = smpPerCpuIpiReceivedCount(cpu)
    let savedIpiLastSource = smpPerCpuIpiLastSource(cpu)
    let savedIpiProbeTargetMask = smpIpiProbeTargetMask()
    let savedIpiProbeDeliveredMask = smpIpiProbeDeliveredMask()
    let savedTlbShootdownReceivedCount = smpPerCpuTlbShootdownReceivedCount(cpu)
    let savedTlbShootdownRequestGeneration = smpPerCpuTlbShootdownRequestGeneration(cpu)
    let savedTlbShootdownAckGeneration = smpPerCpuTlbShootdownAckGeneration(cpu)
    let savedTlbShootdownProbeGeneration = withUnsafeMutablePointer(to: &smpTlbShootdownProbeGenerationStorage) { generation in
        smpAtomicLoad(generation)
    }
    let savedTlbShootdownProbeTargetMask = smpTlbShootdownProbeTargetMask()
    let savedTlbShootdownProbeAckMask = smpTlbShootdownProbeAckMask()
    let savedPmmStressReceivedCount = smpPerCpuPmmStressReceivedCount(cpu)
    let savedPmmStressRequestGeneration = smpPerCpuPmmStressRequestGeneration(cpu)
    let savedPmmStressAckGeneration = smpPerCpuPmmStressAckGeneration(cpu)
    let savedPmmStressProbeGeneration = withUnsafeMutablePointer(to: &smpPmmStressProbeGenerationStorage) { generation in
        smpAtomicLoad(generation)
    }
    let savedPmmStressProbeTargetMask = smpPmmStressProbeTargetMask()
    let savedPmmStressProbeAckMask = smpPmmStressProbeAckMask()
    let savedPmmStressProbeFailureMask = smpPmmStressProbeFailureMask()
    let savedFlags = withUnsafeMutablePointer(to: &smpCpuState[idx].flags) { flags in
        smpAtomicLoad(flags)
    }

    smpCpuState[idx].timerTicks = 41
    smpRecordTimerTickForCurrentCpu()
    if smpCpuState[idx].timerTicks != 42 { return false }

    smpSetCurrentThreadForCurrentCpu(7)
    if smpCpuState[idx].currentThread != 7 { return false }
    if !smpPerCpuCurrentThreadIs(cpu, 7) { return false }

    smpSetCurrentProcessForCurrentCpu(3)
    if smpCpuState[idx].currentProcess != 3 { return false }

    if !smpSetProcessRunQueueForCpu(cpu, head: 5, tail: 9) { return false }
    if smpPerCpuProcessRunQueueIdle(cpu) { return false }
    if smpPerCpuProcessRunQueueHead(cpu) != 5 { return false }
    if smpPerCpuProcessRunQueueTail(cpu) != 9 { return false }

    if !smpSetProcessSchedulerContextForCpu(cpu, 0x1000) { return false }
    if !smpPerCpuProcessSchedulerContextReady(cpu) { return false }
    if smpPerCpuProcessSchedulerContext(cpu) != 0x1000 { return false }
    if smpCpuState[idx].schedulerContext != 0x1000 { return false }

    smpCpuState[idx].el0SwitchCount = 9
    smpRecordEl0SwitchForCurrentCpu()
    if smpPerCpuEl0SwitchCount(cpu) != 10 { return false }

    smpCpuState[idx].kernelSchedulerActivityCount = 11
    smpRecordKernelSchedulerActivityForCurrentCpu()
    if smpPerCpuKernelSchedulerActivityCount(cpu) != 12 { return false }

    withUnsafeMutablePointer(to: &smpIpiReceivedCount[idx]) { count in
        smpAtomicStore(count, 13)
    }
    smpRecordIpiForCurrentCpu(source: 2)
    if smpPerCpuIpiReceivedCount(cpu) != 14 { return false }
    if smpPerCpuIpiLastSource(cpu) != 2 { return false }

    smpResetIpiProbe(targetMask: 0x5)
    smpMarkIpiProbeDelivered(cpu: 0)
    smpMarkIpiProbeDelivered(cpu: 2)
    if smpIpiProbeTargetMask() != 0x5 { return false }
    if smpIpiProbeDeliveredMask() != 0x5 { return false }

    let tlbMask = UInt64(1) << UInt64(cpu)
    let tlbGeneration = smpBeginTlbShootdownProbe(targetMask: tlbMask)
    if tlbGeneration == 0 { return false }
    if !smpPublishTlbShootdownRequest(cpu: cpu, generation: tlbGeneration) { return false }
    if smpPerCpuTlbShootdownRequestGeneration(cpu) != tlbGeneration { return false }
    if !smpHandleTlbShootdownForCurrentCpu() { return false }
    if smpPerCpuTlbShootdownAckGeneration(cpu) != tlbGeneration { return false }
    if smpPerCpuTlbShootdownReceivedCount(cpu) != (savedTlbShootdownReceivedCount &+ 1) { return false }
    if smpTlbShootdownProbeTargetMask() != tlbMask { return false }
    if smpTlbShootdownProbeAckMask() != tlbMask { return false }

    let pmmMask = UInt64(1) << UInt64(cpu)
    let pmmGeneration = smpBeginPmmStressProbe(targetMask: pmmMask)
    if pmmGeneration == 0 { return false }
    if !smpPublishPmmStressRequest(cpu: cpu, generation: pmmGeneration) { return false }
    if smpPerCpuPmmStressRequestGeneration(cpu) != pmmGeneration { return false }
    if !smpHandlePmmStressForCurrentCpu() { return false }
    if smpPerCpuPmmStressAckGeneration(cpu) != pmmGeneration { return false }
    if smpPerCpuPmmStressReceivedCount(cpu) != (savedPmmStressReceivedCount &+ 1) { return false }
    if smpPmmStressProbeTargetMask() != pmmMask { return false }
    if smpPmmStressProbeAckMask() != pmmMask { return false }
    if smpPmmStressProbeFailureMask() != 0 { return false }

    withUnsafeMutablePointer(to: &smpCpuState[idx].flags) { flags in
        smpAtomicStore(flags, savedFlags | smpCpuFlagOnline)
    }
    smpMarkKernelSchedulerReadyForCurrentCpu()
    if !smpPerCpuKernelSchedulerReady(cpu) { return false }

    smpCpuState[idx].timerTicks = savedTicks
    smpCpuState[idx].currentThread = savedThread
    smpCpuState[idx].currentProcess = savedProcess
    smpCpuState[idx].runQueueHead = savedRunQueueHead
    smpCpuState[idx].runQueueTail = savedRunQueueTail
    smpCpuState[idx].schedulerContext = savedSchedulerContext
    smpCpuState[idx].kernelSchedulerActivityCount = savedKernelSchedulerActivityCount
    smpCpuState[idx].el0SwitchCount = savedEl0SwitchCount
    withUnsafeMutablePointer(to: &smpIpiReceivedCount[idx]) { count in
        smpAtomicStore(count, savedIpiReceivedCount)
    }
    withUnsafeMutablePointer(to: &smpIpiLastSourceCpu[idx]) { source in
        smpAtomicStore(source, savedIpiLastSource)
    }
    smpResetIpiProbe(targetMask: savedIpiProbeTargetMask)
    withUnsafeMutablePointer(to: &smpIpiProbeDeliveredMaskStorage) { mask in
        smpAtomicStore(mask, savedIpiProbeDeliveredMask)
    }
    withUnsafeMutablePointer(to: &smpTlbShootdownReceivedCount[idx]) { count in
        smpAtomicStore(count, savedTlbShootdownReceivedCount)
    }
    withUnsafeMutablePointer(to: &smpTlbShootdownRequestGeneration[idx]) { generation in
        smpAtomicStore(generation, savedTlbShootdownRequestGeneration)
    }
    withUnsafeMutablePointer(to: &smpTlbShootdownAckGeneration[idx]) { generation in
        smpAtomicStore(generation, savedTlbShootdownAckGeneration)
    }
    withUnsafeMutablePointer(to: &smpTlbShootdownProbeGenerationStorage) { generation in
        smpAtomicStore(generation, savedTlbShootdownProbeGeneration)
    }
    withUnsafeMutablePointer(to: &smpTlbShootdownProbeTargetMaskStorage) { mask in
        smpAtomicStore(mask, savedTlbShootdownProbeTargetMask)
    }
    withUnsafeMutablePointer(to: &smpTlbShootdownProbeAckMaskStorage) { mask in
        smpAtomicStore(mask, savedTlbShootdownProbeAckMask)
    }
    withUnsafeMutablePointer(to: &smpPmmStressReceivedCount[idx]) { count in
        smpAtomicStore(count, savedPmmStressReceivedCount)
    }
    withUnsafeMutablePointer(to: &smpPmmStressRequestGeneration[idx]) { generation in
        smpAtomicStore(generation, savedPmmStressRequestGeneration)
    }
    withUnsafeMutablePointer(to: &smpPmmStressAckGeneration[idx]) { generation in
        smpAtomicStore(generation, savedPmmStressAckGeneration)
    }
    withUnsafeMutablePointer(to: &smpPmmStressProbeGenerationStorage) { generation in
        smpAtomicStore(generation, savedPmmStressProbeGeneration)
    }
    withUnsafeMutablePointer(to: &smpPmmStressProbeTargetMaskStorage) { mask in
        smpAtomicStore(mask, savedPmmStressProbeTargetMask)
    }
    withUnsafeMutablePointer(to: &smpPmmStressProbeAckMaskStorage) { mask in
        smpAtomicStore(mask, savedPmmStressProbeAckMask)
    }
    withUnsafeMutablePointer(to: &smpPmmStressProbeFailureMaskStorage) { mask in
        smpAtomicStore(mask, savedPmmStressProbeFailureMask)
    }
    withUnsafeMutablePointer(to: &smpCpuState[idx].flags) { flags in
        smpAtomicStore(flags, savedFlags)
    }
    smpMemoryBarrier()
    return true
}
