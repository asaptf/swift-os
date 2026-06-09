// SPDX-License-Identifier: Apache-2.0
// percpu.swift - fixed per-CPU state scaffold for SMP bring-up.
//
// The storage stays heap-free and fixed-size so secondary CPUs can mark their
// own early state without touching allocator-backed scheduler/VFS structures.

private let smpMaxCpus = 8

private let smpCpuFlagInitialized: UInt64 = 1 << 0
private let smpCpuFlagOnline: UInt64 = 1 << 1
private let smpNoThread: Int32 = -1
private let smpNoProcess: Int32 = -1
private let smpUninitializedCpu: UInt32 = 0xFFFF_FFFF

@_alignment(16) private struct SMPPerCpuState {
    var flags: UInt64 = 0
    var logicalId: UInt32 = smpUninitializedCpu
    var reserved0: UInt32 = 0
    var timerTicks: UInt64 = 0
    var idleTicks: UInt64 = 0
    var currentThread: Int32 = smpNoThread
    var currentProcess: Int32 = smpNoProcess
    var runQueueHead: Int32 = smpNoThread
    var runQueueTail: Int32 = smpNoThread
    var schedulerContext: UInt = 0
    var reserved1: UInt64 = 0
}

// Fixed static storage: no Swift Array, no heap, and safe to address before any
// future secondary CPU is allowed to call allocator-backed code.
private var smpCpuState: InlineArray<8, SMPPerCpuState> = .init(repeating: SMPPerCpuState())

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
    smpCpuState[idx].reserved0 = 0
    smpCpuState[idx].timerTicks = 0
    smpCpuState[idx].idleTicks = 0
    smpCpuState[idx].currentThread = smpNoThread
    smpCpuState[idx].currentProcess = smpNoProcess
    smpCpuState[idx].runQueueHead = smpNoThread
    smpCpuState[idx].runQueueTail = smpNoThread
    smpCpuState[idx].schedulerContext = 0
    smpCpuState[idx].reserved1 = 0

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

func smpRecordTimerTickForCurrentCpu() {
    let cpu = currentCpuId()
    if !smpValidCpu(cpu) { return }
    smpCpuState[Int(cpu)].timerTicks &+= 1
}

func smpPerCpuTimerTicks(_ cpu: UInt32) -> UInt64 {
    if !smpValidCpu(cpu) { return 0 }
    return smpCpuState[Int(cpu)].timerTicks
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
        if smpCpuState[slot].logicalId != UInt32(slot) { return false }
        if smpCpuState[slot].timerTicks != UInt64(slot) { return false }
        if smpCpuState[slot].currentThread != Int32(slot) { return false }
        if smpCpuState[slot].currentProcess != Int32(slot + 1) { return false }
        smpCpuState[slot] = SMPPerCpuState()
        slot += 1
    }

    if !smpEarlyInitCurrentCpu() { return false }

    let cpu = currentCpuId()
    if !smpCpuInitialized(cpu) { return false }

    let idx = Int(cpu)
    let savedTicks = smpCpuState[idx].timerTicks
    let savedThread = smpCpuState[idx].currentThread
    let savedProcess = smpCpuState[idx].currentProcess

    smpCpuState[idx].timerTicks = 41
    smpRecordTimerTickForCurrentCpu()
    if smpCpuState[idx].timerTicks != 42 { return false }

    smpSetCurrentThreadForCurrentCpu(7)
    if smpCpuState[idx].currentThread != 7 { return false }

    smpSetCurrentProcessForCurrentCpu(3)
    if smpCpuState[idx].currentProcess != 3 { return false }

    smpCpuState[idx].timerTicks = savedTicks
    smpCpuState[idx].currentThread = savedThread
    smpCpuState[idx].currentProcess = savedProcess
    smpMemoryBarrier()
    return true
}
