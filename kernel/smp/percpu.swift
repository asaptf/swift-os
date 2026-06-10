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
        smpCpuState[slot] = SMPPerCpuState()
        smpIpiReceivedCount[slot] = 0
        smpIpiLastSourceCpu[slot] = UInt64.max
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
    withUnsafeMutablePointer(to: &smpCpuState[idx].flags) { flags in
        smpAtomicStore(flags, savedFlags)
    }
    smpMemoryBarrier()
    return true
}
