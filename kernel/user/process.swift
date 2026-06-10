// SPDX-License-Identifier: Apache-2.0
// process.swift — preemptive EL0 process model.
//
// A real process table scheduled preemptively. Each process has its own address
// space, kernel stack, and saved CPUContext (the M4.5 switch primitive). The
// scheduler runs on the kernel_main stack as a dedicated context: it switches
// INTO a runnable process and regains control when that process yields, blocks,
// is preempted by the timer, or exits — classic per-CPU scheduler context. S2d
// also routes every pReady transition through a CPU-owned run queue scaffold;
// S2f records the CPU that actually dispatched each EL0 slot. Placement still
// chooses CPU0 until S2 deliberately enables secondary EL0 work.
//
// The kernel launches a top process and drives the scheduler until it exits
// (processRunElf). EL0 processes can spawn children and block waiting for them;
// the same scheduler loop runs the children and wakes the parent. This is the
// foundation for fork/execve/waitpid (next steps).
//
// Process teardown reclaims frames: reapProcess frees the address space (every
// user page + its page tables, via address_space_destroy) and the kernel stack
// back to the PMM, and execve frees the replaced image's address space. Without
// this the OS leaked ~2 MiB per command and exhausted RAM after ~100 commands.

private let userStackTop: UInt = 0x9000_0000
private let userStackPages = 4
private let kernelStackPages = 2 // per-process EL1 stack; freed on reap
private let userHeapBase: UInt = 0xA000_0000

// Track B — anonymous mmap arena. The valid user window is [0x8000_0000,
// 0xB000_0000) (user_access.swift). Within it the fixed regions are: the ELF
// image at 0x8000_0000 growing UP (busybox ~1.1 MiB, far short of 0x8800_0000);
// the 4-page user stack at the top of [0x8FFF_C000, 0x9000_0000); and the sbrk
// heap at 0xA000_0000 growing UP. That leaves a 256 MiB gap between the stack
// top (0x9000_0000) and the heap base (0xA000_0000) with nothing in it. We park
// the mmap arena at the MIDPOINT of that gap, 0x9800_0000, and grow it DOWN.
// This keeps 128 MiB of clearance above the stack top and 128 MiB below the
// heap base, so an mmap region can never collide with code, data, stack, or
// heap. The cursor is per-process (pMmapTop), reset on exec, copied on fork.
// Growing down (away from the heap) mirrors the classic Linux mmap layout.
private let userMmapTop: UInt = 0x9800_0000
private let userMmapFloor: UInt = 0x9000_0000 // never grow into the stack region
private let maxProc = 16
private let procNameMax = 16
private let psInfoRecordSize = 32
private let procStatRecordSize = 56 // richer per-process record for /bin/top
private let sysInfoSize = 64        // system-wide stats blob for /bin/top
private let kernelLoadOffset: UInt = 0x80000 // kernel links/loads at ramBase + this

private let trapFrameSPIndex = 31
private let trapFrameELRIndex = 32
private let trapFrameSPSRIndex = 33

// Process states.
private let pUnused: Int32 = 0
private let pReady: Int32 = 1
private let pRunning: Int32 = 2
private let pBlocked: Int32 = 3
private let pZombie: Int32 = 4

private let waitNone = -2 // not waiting
private let waitAny = -1  // any child
private let noProcessSlot: Int32 = -1
private let unassignedCpu: UInt32 = 0xFFFF_FFFF
private let processSchedulerCpuSlots = 8

// Stable context storage for cpu_switch_context.
private var procCtx: UnsafeMutablePointer<CPUContext>! = nil   // [maxProc]
private var schedCtx: UnsafeMutablePointer<CPUContext>! = nil  // [smpMaxCpuCount()]
private var schedCtxCpuCount: UInt32 = 0

// Per-process metadata (parallel arrays; not address-sensitive).
private var pState = [Int32](repeating: 0, count: maxProc)
private var pParent = [Int](repeating: -1, count: maxProc)   // parent slot, -1 = kernel
private var pTtbr0 = [UInt](repeating: 0, count: maxProc)
private var pKstack = [UInt](repeating: 0, count: maxProc) // kernel stack base (2 frames), freed on reap
private var pExit = [Int](repeating: 0, count: maxProc)
private var pKilled = [Bool](repeating: false, count: maxProc)
private var pWait = [Int](repeating: waitNone, count: maxProc) // slot waited on / waitAny
private var pBrk = [UInt](repeating: 0, count: maxProc)
// Track B — descending mmap cursor. Next anonymous mmap is placed just below
// pMmapTop[slot]; it starts at userMmapTop and shrinks toward userMmapFloor.
private var pMmapTop = [UInt](repeating: 0, count: maxProc)

// I2b: per-process file-backed mmap regions (lazy / demand-paged). A region
// reserves VA but maps no frames until first touch; the page-fault handler
// (processHandleFileFault) reads the backing disk extent into the faulting page.
private struct FileVma {
    var active = false
    var base: UInt = 0       // region start VA (page-aligned)
    var pages: UInt = 0      // region length in pages
    var diskImage: Int = 0    // VFS image id that owns the file data
    var diskOffset: UInt = 0 // byte offset of the file's data on the virtio-blk device
    var fileLen: UInt = 0    // content bytes (tail of the last page is zero-filled)
    var prot: Int32 = 0
}
private let maxFileVmas = 8
private var pFileVmas = [FileVma](repeating: FileVma(), count: maxProc * maxFileVmas)
// Cumulative count of file-backed demand faults serviced (observability), and a
// one-shot guard so the "demand paging active" marker is logged just once.
var fileDemandFaults: UInt64 = 0
private var fileDemandLogged = false

private func fileVmasClear(_ slot: Int) {
    for i in 0..<maxFileVmas { pFileVmas[slot * maxFileVmas + i].active = false }
}
private func fileVmasCopy(_ dst: Int, _ src: Int) {
    for i in 0..<maxFileVmas { pFileVmas[dst * maxFileVmas + i] = pFileVmas[src * maxFileVmas + i] }
}
private func fileVmaAdd(_ slot: Int, _ base: UInt, _ pages: UInt, _ diskImage: Int,
                        _ diskOffset: UInt, _ fileLen: UInt, _ prot: Int32) -> Bool {
    for i in 0..<maxFileVmas {
        let idx = slot * maxFileVmas + i
        if !pFileVmas[idx].active {
            pFileVmas[idx] = FileVma(active: true, base: base, pages: pages,
                                     diskImage: diskImage, diskOffset: diskOffset,
                                     fileLen: fileLen, prot: prot)
            return true
        }
    }
    return false // table full
}
private var pNameLen = [Int](repeating: 0, count: maxProc)
private var pName = [UInt8](repeating: 0, count: maxProc * procNameMax)
// Principal / session / capability mask, plus the process's Cell tag, kept as
// one typed record per slot (adding a Cell field is now a struct change, not a
// new parallel array).
private var pSecurity = [ProcessSecurityContext](
    repeating: ProcessSecurityContext(principal: 0, session: 0, caps: 0, cell: globalCell),
    count: maxProc)
// rt-a: a thread shares its creator's address space (TTBR0) instead of owning a
// private one, so its exit must not be treated as an address-space teardown and
// it joins via futex rather than waitpid.
private var pIsThread = [Bool](repeating: false, count: maxProc)

// Accounting for /bin/top. CPU is charged one tick per timer interrupt to
// whichever process is current (idle ticks when none is). Resident pages track
// each process's mapped user footprint (ELF image + stack + heap); COW fork
// copies the logical count even while physical frames are shared, exec resets to
// the new image, and sbrk adds heap growth. Start tick is systemTicks at
// creation, for "uptime of this process".
private var pCpuTicks = [UInt64](repeating: 0, count: maxProc)
private var pStartTick = [UInt64](repeating: 0, count: maxProc)
private var pResPages = [Int](repeating: 0, count: maxProc)
private var idleTicks: UInt64 = 0
// nanosleep deadline (in systemTicks); 0 = not sleeping. A sleeping process
// parks in pBlocked exactly like a futex/waitpid blocker, but only sleepers
// carry a nonzero deadline, so the per-tick wake scan can pick them out without
// disturbing the others.
private var pWakeTick = [UInt64](repeating: 0, count: maxProc)
private var pHomeCpu = [UInt32](repeating: unassignedCpu, count: maxProc)
private var pRunNext = [Int32](repeating: noProcessSlot, count: maxProc)
private var pRunQueued = [Bool](repeating: false, count: maxProc)
private var pLastDispatchCpu = [UInt32](repeating: unassignedCpu, count: maxProc)
private var pDispatchCount = [UInt64](repeating: 0, count: maxProc)
private var pDispatchCpuMask = [UInt64](repeating: 0, count: maxProc)
private var pAddressSpaceCpuMask = [UInt64](repeating: 0, count: maxProc)

private var processRunQueueHead = [Int32](repeating: noProcessSlot, count: processSchedulerCpuSlots)
private var processRunQueueTail = [Int32](repeating: noProcessSlot, count: processSchedulerCpuSlots)
private var processRunQueueEnqueueCount = [UInt64](repeating: 0, count: processSchedulerCpuSlots)
private var processRunQueueDispatchCount = [UInt64](repeating: 0, count: processSchedulerCpuSlots)
private var processDispatchTelemetryCount = [UInt64](repeating: 0, count: processSchedulerCpuSlots)
private var processAddressSpaceActivationCount = [UInt64](repeating: 0, count: processSchedulerCpuSlots)
private var processRunQueueCpuCount: UInt32 = 0

private var lastPairDispatchTelemetryValid = false
private var lastPairDispatchCountA: UInt64 = 0
private var lastPairDispatchCountB: UInt64 = 0
private var lastPairDispatchCpuMaskA: UInt64 = 0
private var lastPairDispatchCpuMaskB: UInt64 = 0
private var lastPairLastDispatchCpuA: UInt32 = unassignedCpu
private var lastPairLastDispatchCpuB: UInt32 = unassignedCpu

private var currentProc = -1 // running slot, or -1 while in the scheduler
private var lastReapedKilled = false

func processInit() {
    let n = MemoryLayout<CPUContext>.stride
    let cpuCount = smpMaxCpuCount()
    guard let c = swiftos_kernel_alloc(UInt(n * maxProc), 16),
          let s = swiftos_kernel_alloc(UInt(n) * UInt(cpuCount), 16) else {
        uartPuts("panic: process context allocation failed\n")
        while true {}
    }
    procCtx = c.bindMemory(to: CPUContext.self, capacity: maxProc)
    schedCtx = s.bindMemory(to: CPUContext.self, capacity: Int(cpuCount))
    schedCtxCpuCount = cpuCount
    processRunQueueCpuCount = cpuCount
    var cpu: UInt32 = 0
    while cpu < cpuCount {
        schedCtx[Int(cpu)] = CPUContext()
        processRunQueueHead[Int(cpu)] = noProcessSlot
        processRunQueueTail[Int(cpu)] = noProcessSlot
        processRunQueueEnqueueCount[Int(cpu)] = 0
        processRunQueueDispatchCount[Int(cpu)] = 0
        processDispatchTelemetryCount[Int(cpu)] = 0
        processAddressSpaceActivationCount[Int(cpu)] = 0
        let context = UInt(bitPattern: schedCtx.advanced(by: Int(cpu)))
        if !smpSetProcessSchedulerContextForCpu(cpu, context) ||
           !smpSetProcessRunQueueForCpu(cpu, head: noProcessSlot, tail: noProcessSlot) {
            uartPuts("panic: process scheduler per-CPU publication failed\n")
            while true {}
        }
        cpu += 1
    }
    for i in 0..<maxProc {
        pState[i] = pUnused
        pHomeCpu[i] = unassignedCpu
        pRunNext[i] = noProcessSlot
        pRunQueued[i] = false
        pLastDispatchCpu[i] = unassignedCpu
        pDispatchCount[i] = 0
        pDispatchCpuMask[i] = 0
        pAddressSpaceCpuMask[i] = 0
    }
    lastPairDispatchTelemetryValid = false
    lastPairDispatchCountA = 0
    lastPairDispatchCountB = 0
    lastPairDispatchCpuMaskA = 0
    lastPairDispatchCpuMaskB = 0
    lastPairLastDispatchCpuA = unassignedCpu
    lastPairLastDispatchCpuB = unassignedCpu
}

private func processSchedulerCpuIndex() -> Int {
    let cpu = currentCpuId()
    if cpu >= schedCtxCpuCount || !processSecondaryEl0GateAllowsCpu(cpu) {
        uartPuts("panic: EL0 process scheduler entered on non-owner CPU\n")
        while true {}
    }
    return Int(cpu)
}

private func schedulerContextForCurrentCpu() -> UnsafeMutableRawPointer {
    UnsafeMutableRawPointer(schedCtx.advanced(by: processSchedulerCpuIndex()))
}

private func schedulerContextAddressForCpu(_ cpu: UInt32) -> UInt {
    if cpu >= schedCtxCpuCount { return 0 }
    return UInt(bitPattern: schedCtx.advanced(by: Int(cpu)))
}

func processSchedulerContextSelfTest() -> Bool {
    if schedCtx == nil { return false }
    if MemoryLayout<CPUContext>.stride != 104 { return false }
    if schedCtxCpuCount != smpMaxCpuCount() { return false }
    if processRunQueueCpuCount != schedCtxCpuCount { return false }
    if processSchedulerCpuSlots != Int(smpMaxCpuCount()) { return false }
    if currentCpuId() >= schedCtxCpuCount { return false }
    if (UInt(bitPattern: schedCtx) & 0xF) != 0 { return false }
    if !smpPerCpuProcessSchedulerContextReady(currentCpuId()) { return false }
    if smpPerCpuEl0SwitchCount(currentCpuId()) != 0 { return false }

    var cpu: UInt32 = 0
    while cpu < schedCtxCpuCount {
        let ctx = schedCtx[Int(cpu)]
        if ctx.x19 != 0 || ctx.x20 != 0 || ctx.x21 != 0 || ctx.x22 != 0 ||
           ctx.x23 != 0 || ctx.x24 != 0 || ctx.x25 != 0 || ctx.x26 != 0 ||
           ctx.x27 != 0 || ctx.x28 != 0 || ctx.fp != 0 || ctx.lr != 0 ||
           ctx.sp != 0 {
            return false
        }
        if smpPerCpuProcessSchedulerContext(cpu) != schedulerContextAddressForCpu(cpu) {
            return false
        }
        if !smpPerCpuProcessRunQueueIdle(cpu) { return false }
        cpu += 1
    }
    return true
}

private func processValidSchedulerCpu(_ cpu: UInt32) -> Bool {
    cpu < processRunQueueCpuCount && cpu < UInt32(processSchedulerCpuSlots)
}

private func processSecondaryEl0GateEnabled() -> Bool {
    false
}

private func processSecondaryEl0GateAllowsCpu(_ cpu: UInt32) -> Bool {
    processValidSchedulerCpu(cpu) && (cpu == 0 || processSecondaryEl0GateEnabled())
}

private func processMirrorRunQueueForCpu(_ cpu: UInt32) {
    if currentCpuId() != cpu { return }
    let idx = Int(cpu)
    smpSetProcessRunQueueForCurrentCpu(head: processRunQueueHead[idx],
                                       tail: processRunQueueTail[idx])
}

private func processHomeCpuForNewReadySlot(_ slot: Int) -> UInt32 {
    if slot < 0 || slot >= maxProc { return unassignedCpu }
    // S2h keeps the placement policy behind an explicit gate. Today the gate is
    // closed, so every runnable EL0 process remains CPU0-owned.
    if !processSecondaryEl0GateEnabled() { return 0 }
    return 0
}

private func clearProcessSchedulerSlot(_ slot: Int) {
    if slot < 0 || slot >= maxProc { return }
    pHomeCpu[slot] = unassignedCpu
    pRunNext[slot] = noProcessSlot
    pRunQueued[slot] = false
    pLastDispatchCpu[slot] = unassignedCpu
    pDispatchCount[slot] = 0
    pDispatchCpuMask[slot] = 0
    pAddressSpaceCpuMask[slot] = 0
}

private func recordProcessDispatch(_ slot: Int, on cpu: UInt32) {
    if slot < 0 || slot >= maxProc || !processValidSchedulerCpu(cpu) {
        uartPuts("panic: invalid EL0 process dispatch telemetry target\n")
        while true {}
    }
    if !processSecondaryEl0GateAllowsCpu(cpu) {
        uartPuts("panic: EL0 process dispatched on secondary before S2\n")
        while true {}
    }
    if pHomeCpu[slot] != cpu {
        uartPuts("panic: EL0 process dispatch CPU mismatch\n")
        while true {}
    }
    pLastDispatchCpu[slot] = cpu
    pDispatchCount[slot] &+= 1
    pDispatchCpuMask[slot] |= UInt64(1) << Int(cpu)
    processDispatchTelemetryCount[Int(cpu)] &+= 1
}

private func recordProcessAddressSpaceActivation(_ slot: Int, on cpu: UInt32) {
    if slot < 0 || slot >= maxProc || !processValidSchedulerCpu(cpu) || pTtbr0[slot] == 0 {
        uartPuts("panic: invalid address-space CPU mask target\n")
        while true {}
    }
    if !processSecondaryEl0GateAllowsCpu(cpu) {
        uartPuts("panic: address space activated on secondary before S3\n")
        while true {}
    }
    if pHomeCpu[slot] != cpu || pLastDispatchCpu[slot] != cpu {
        uartPuts("panic: address-space CPU mask dispatch mismatch\n")
        while true {}
    }
    pAddressSpaceCpuMask[slot] |= UInt64(1) << Int(cpu)
    processAddressSpaceActivationCount[Int(cpu)] &+= 1
}

private func captureLastPairDispatchTelemetry(_ a: Int, _ b: Int) {
    if a < 0 || a >= maxProc || b < 0 || b >= maxProc {
        lastPairDispatchTelemetryValid = false
        return
    }
    lastPairDispatchCountA = pDispatchCount[a]
    lastPairDispatchCountB = pDispatchCount[b]
    lastPairDispatchCpuMaskA = pDispatchCpuMask[a]
    lastPairDispatchCpuMaskB = pDispatchCpuMask[b]
    lastPairLastDispatchCpuA = pLastDispatchCpu[a]
    lastPairLastDispatchCpuB = pLastDispatchCpu[b]
    lastPairDispatchTelemetryValid = true
}

private func markProcessReady(_ slot: Int, cpu: UInt32) {
    if slot < 0 || slot >= maxProc || !processValidSchedulerCpu(cpu) {
        uartPuts("panic: invalid EL0 process run queue target\n")
        while true {}
    }
    if !processSecondaryEl0GateAllowsCpu(cpu) {
        uartPuts("panic: EL0 process scheduled on secondary before S2\n")
        while true {}
    }
    pState[slot] = pReady
    pHomeCpu[slot] = cpu
    if pRunQueued[slot] { return }

    let idx = Int(cpu)
    pRunNext[slot] = noProcessSlot
    if processRunQueueTail[idx] == noProcessSlot {
        processRunQueueHead[idx] = Int32(slot)
    } else {
        pRunNext[Int(processRunQueueTail[idx])] = Int32(slot)
    }
    processRunQueueTail[idx] = Int32(slot)
    pRunQueued[slot] = true
    processRunQueueEnqueueCount[idx] &+= 1
    processMirrorRunQueueForCpu(cpu)
}

private func markProcessReadyOnHomeCpu(_ slot: Int) {
    markProcessReady(slot, cpu: processHomeCpuForNewReadySlot(slot))
}

private func pickReady() -> Int {
    let cpu = UInt32(processSchedulerCpuIndex())
    if !processValidSchedulerCpu(cpu) { return -1 }
    let idx = Int(cpu)
    let head = processRunQueueHead[idx]
    if head == noProcessSlot { return -1 }

    let slot = Int(head)
    processRunQueueHead[idx] = pRunNext[slot]
    if processRunQueueHead[idx] == noProcessSlot {
        processRunQueueTail[idx] = noProcessSlot
    }
    pRunNext[slot] = noProcessSlot
    pRunQueued[slot] = false
    processRunQueueDispatchCount[idx] &+= 1
    processMirrorRunQueueForCpu(cpu)

    if pState[slot] != pReady || pHomeCpu[slot] != cpu {
        uartPuts("panic: EL0 process run queue corrupted\n")
        while true {}
    }
    return slot
}

func processRunQueueScaffoldSelfTest() -> Bool {
    if processRunQueueCpuCount != smpMaxCpuCount() { return false }
    if processSchedulerCpuSlots != Int(smpMaxCpuCount()) { return false }
    let primary = currentCpuId()
    if primary != 0 || !processValidSchedulerCpu(primary) { return false }
    if smpPerCpuProcessRunQueueHead(primary) != noProcessSlot { return false }
    if smpPerCpuProcessRunQueueTail(primary) != noProcessSlot { return false }
    if !smpPerCpuProcessRunQueueIdle(primary) { return false }

    var cpu: UInt32 = 0
    while cpu < processRunQueueCpuCount {
        let idx = Int(cpu)
        if processRunQueueHead[idx] != noProcessSlot { return false }
        if processRunQueueTail[idx] != noProcessSlot { return false }
        if processRunQueueEnqueueCount[idx] != 0 { return false }
        if processRunQueueDispatchCount[idx] != 0 { return false }
        cpu += 1
    }
    return true
}

func processDormantSchedulerCpusSelfTest() -> Bool {
    if processRunQueueCpuCount != smpMaxCpuCount() { return false }
    var cpu: UInt32 = 0
    while cpu < processRunQueueCpuCount {
        let idx = Int(cpu)
        if smpPerCpuProcessSchedulerContext(cpu) != schedulerContextAddressForCpu(cpu) {
            return false
        }
        if !smpPerCpuProcessRunQueueIdle(cpu) { return false }
        if processRunQueueEnqueueCount[idx] != 0 { return false }
        if processRunQueueDispatchCount[idx] != 0 { return false }
        cpu += 1
    }
    return true
}

func processDispatchTelemetrySelfTest() -> Bool {
    if processRunQueueCpuCount != smpMaxCpuCount() { return false }
    if processSchedulerCpuSlots != Int(smpMaxCpuCount()) { return false }
    if lastPairDispatchTelemetryValid { return false }
    if lastPairDispatchCountA != 0 || lastPairDispatchCountB != 0 { return false }
    if lastPairDispatchCpuMaskA != 0 || lastPairDispatchCpuMaskB != 0 { return false }
    if lastPairLastDispatchCpuA != unassignedCpu { return false }
    if lastPairLastDispatchCpuB != unassignedCpu { return false }
    var cpu: UInt32 = 0
    while cpu < processRunQueueCpuCount {
        let idx = Int(cpu)
        if processDispatchTelemetryCount[idx] != 0 { return false }
        if smpPerCpuEl0SwitchCount(cpu) != 0 { return false }
        cpu += 1
    }
    for slot in 0..<maxProc {
        if pLastDispatchCpu[slot] != unassignedCpu { return false }
        if pDispatchCount[slot] != 0 { return false }
        if pDispatchCpuMask[slot] != 0 { return false }
    }
    return true
}

func processSecondaryEl0GateSelfTest() -> Bool {
    if processSecondaryEl0GateEnabled() { return false }
    if processRunQueueCpuCount != smpMaxCpuCount() { return false }
    if !processSecondaryEl0GateAllowsCpu(0) { return false }
    if processSecondaryEl0GateAllowsCpu(smpMaxCpuCount()) { return false }
    if processHomeCpuForNewReadySlot(-1) != unassignedCpu { return false }
    if processHomeCpuForNewReadySlot(maxProc) != unassignedCpu { return false }

    var cpu: UInt32 = 1
    while cpu < processRunQueueCpuCount {
        if processSecondaryEl0GateAllowsCpu(cpu) { return false }
        cpu += 1
    }
    for slot in 0..<maxProc {
        if processHomeCpuForNewReadySlot(slot) != 0 { return false }
    }
    return true
}

func processSecondaryEl0GateHeldSelfTest() -> Bool {
    if !processSecondaryEl0GateSelfTest() { return false }
    let primaryMask = UInt64(1)
    for slot in 0..<maxProc {
        if (pDispatchCpuMask[slot] & ~primaryMask) != 0 { return false }
        if pLastDispatchCpu[slot] != unassignedCpu && pLastDispatchCpu[slot] != 0 {
            return false
        }
        if pHomeCpu[slot] != unassignedCpu && pHomeCpu[slot] != 0 {
            return false
        }
    }

    var cpu: UInt32 = 1
    while cpu < processRunQueueCpuCount {
        let idx = Int(cpu)
        if processRunQueueEnqueueCount[idx] != 0 { return false }
        if processRunQueueDispatchCount[idx] != 0 { return false }
        if processDispatchTelemetryCount[idx] != 0 { return false }
        if smpPerCpuEl0SwitchCount(cpu) != 0 { return false }
        if !smpPerCpuProcessRunQueueIdle(cpu) { return false }
        cpu += 1
    }
    return true
}

func processAddressSpaceCpuMaskSelfTest() -> Bool {
    if processRunQueueCpuCount != smpMaxCpuCount() { return false }
    if processSchedulerCpuSlots != Int(smpMaxCpuCount()) { return false }
    var cpu: UInt32 = 0
    while cpu < processRunQueueCpuCount {
        if processAddressSpaceActivationCount[Int(cpu)] != 0 { return false }
        cpu += 1
    }
    for slot in 0..<maxProc {
        if pAddressSpaceCpuMask[slot] != 0 { return false }
    }
    return true
}

func processAddressSpaceCpuMaskNoSecondarySelfTest() -> Bool {
    let primary = currentCpuId()
    if primary != 0 || !processValidSchedulerCpu(primary) { return false }
    let primaryIdx = Int(primary)
    if processAddressSpaceActivationCount[primaryIdx] == 0 { return false }
    if processAddressSpaceActivationCount[primaryIdx] != processDispatchTelemetryCount[primaryIdx] {
        return false
    }
    let primaryMask = UInt64(1) << Int(primary)
    for slot in 0..<maxProc {
        if (pAddressSpaceCpuMask[slot] & ~primaryMask) != 0 { return false }
    }

    var cpu: UInt32 = 0
    while cpu < processRunQueueCpuCount {
        let idx = Int(cpu)
        if cpu != primary && processAddressSpaceActivationCount[idx] != 0 {
            return false
        }
        cpu += 1
    }
    return true
}

func processCoprocPairDispatchTelemetrySelfTest() -> Bool {
    let primary = currentCpuId()
    if primary != 0 || !processValidSchedulerCpu(primary) { return false }
    if !lastPairDispatchTelemetryValid { return false }
    if lastPairDispatchCountA == 0 || lastPairDispatchCountB == 0 { return false }
    if lastPairLastDispatchCpuA != primary { return false }
    if lastPairLastDispatchCpuB != primary { return false }
    let primaryMask = UInt64(1) << Int(primary)
    if lastPairDispatchCpuMaskA != primaryMask { return false }
    if lastPairDispatchCpuMaskB != primaryMask { return false }
    var cpu: UInt32 = 0
    while cpu < processRunQueueCpuCount {
        if cpu != primary {
            if processDispatchTelemetryCount[Int(cpu)] != 0 { return false }
            if smpPerCpuEl0SwitchCount(cpu) != 0 { return false }
        }
        cpu += 1
    }
    return true
}

func processRunQueueNoSecondaryExecutionSelfTest() -> Bool {
    let primary = currentCpuId()
    if primary != 0 || !processValidSchedulerCpu(primary) { return false }
    if processRunQueueEnqueueCount[Int(primary)] == 0 { return false }
    if processRunQueueDispatchCount[Int(primary)] == 0 { return false }
    if smpPerCpuProcessRunQueueHead(primary) != noProcessSlot { return false }
    if smpPerCpuProcessRunQueueTail(primary) != noProcessSlot { return false }

    var cpu: UInt32 = 0
    while cpu < processRunQueueCpuCount {
        let idx = Int(cpu)
        if processRunQueueHead[idx] != noProcessSlot { return false }
        if processRunQueueTail[idx] != noProcessSlot { return false }
        if cpu != primary {
            if processRunQueueEnqueueCount[idx] != 0 { return false }
            if processRunQueueDispatchCount[idx] != 0 { return false }
            if !smpPerCpuProcessRunQueueIdle(cpu) { return false }
        }
        cpu += 1
    }
    return true
}

func processNoSecondarySchedulerDispatchSelfTest() -> Bool {
    let primary = currentCpuId()
    if primary != 0 || !processValidSchedulerCpu(primary) { return false }
    if processRunQueueEnqueueCount[Int(primary)] == 0 { return false }
    if processRunQueueDispatchCount[Int(primary)] == 0 { return false }

    var cpu: UInt32 = 0
    while cpu < processRunQueueCpuCount {
        let idx = Int(cpu)
        if smpPerCpuProcessSchedulerContext(cpu) != schedulerContextAddressForCpu(cpu) {
            return false
        }
        if cpu != primary {
            if !smpPerCpuProcessRunQueueIdle(cpu) { return false }
            if processRunQueueEnqueueCount[idx] != 0 { return false }
            if processRunQueueDispatchCount[idx] != 0 { return false }
            if smpPerCpuEl0SwitchCount(cpu) != 0 { return false }
        }
        cpu += 1
    }
    return true
}

func processDispatchTelemetryNoSecondarySelfTest() -> Bool {
    let primary = currentCpuId()
    if primary != 0 || !processValidSchedulerCpu(primary) { return false }

    let primaryIdx = Int(primary)
    if processDispatchTelemetryCount[primaryIdx] == 0 { return false }
    if processDispatchTelemetryCount[primaryIdx] != smpPerCpuEl0SwitchCount(primary) {
        return false
    }
    if processDispatchTelemetryCount[primaryIdx] != processRunQueueDispatchCount[primaryIdx] {
        return false
    }

    for slot in 0..<maxProc {
        if pDispatchCount[slot] == 0 {
            if pLastDispatchCpu[slot] != unassignedCpu { return false }
            if pDispatchCpuMask[slot] != 0 { return false }
            continue
        }
        if pLastDispatchCpu[slot] != primary { return false }
        if pHomeCpu[slot] != primary { return false }
        if pDispatchCpuMask[slot] != (UInt64(1) << Int(primary)) { return false }
    }

    var cpu: UInt32 = 0
    while cpu < processRunQueueCpuCount {
        let idx = Int(cpu)
        if cpu != primary {
            if processDispatchTelemetryCount[idx] != 0 { return false }
            if processRunQueueDispatchCount[idx] != 0 { return false }
            if smpPerCpuEl0SwitchCount(cpu) != 0 { return false }
        }
        cpu += 1
    }
    return true
}

func processIsActive() -> Bool { currentProc >= 0 }
func processLastKilledBySignal() -> Bool { lastReapedKilled }
func processCurrentAddressSpace() -> UInt {
    currentProc >= 0 ? pTtbr0[currentProc] : 0
}
func processCurrentSlot() -> Int { currentProc }

/// Pack argv into a kernel buffer as NUL-separated strings ("a\0b\0c\0").
/// Returns (buffer address, total length, argc). Heap-allocated; never freed.
func packArgs(_ args: [StaticString]) -> (UInt, UInt, Int) {
    var total = 0
    for a in args { total += a.utf8CodeUnitCount + 1 }
    guard let raw = swiftos_kernel_alloc(UInt(total), 16) else { return (0, 0, 0) }
    let buf = raw.bindMemory(to: UInt8.self, capacity: total)
    var off = 0
    for a in args {
        a.withUTF8Buffer { b in for c in b { buf[off] = c; off += 1 } }
        buf[off] = 0
        off += 1
    }
    return (UInt(bitPattern: raw), UInt(total), args.count)
}

private func allocSlot() -> Int {
    for i in 0..<maxProc where pState[i] == pUnused { return i }
    return -1
}

private func setProcessName(slot: Int, packed: UInt, argc: Int) {
    if slot < 0 || slot >= maxProc { return }
    let base = slot * procNameMax
    for i in 0..<procNameMax { pName[base + i] = 0 }
    pNameLen[slot] = 0

    guard argc > 0, packed != 0, let src = UnsafePointer<UInt8>(bitPattern: packed) else {
        pName[base] = 0x3F // "?"
        pNameLen[slot] = 1
        return
    }

    var n = 0
    while n < procNameMax - 1 && src[n] != 0 {
        pName[base + n] = src[n]
        n += 1
    }
    if n == 0 {
        pName[base] = 0x3F
        pNameLen[slot] = 1
    } else {
        pNameLen[slot] = n
    }
}

private func copyProcessName(from parent: Int, to child: Int) {
    if parent < 0 || parent >= maxProc || child < 0 || child >= maxProc { return }
    let src = parent * procNameMax
    let dst = child * procNameMax
    for i in 0..<procNameMax { pName[dst + i] = pName[src + i] }
    pNameLen[child] = pNameLen[parent]
}

private func setProcessSecurity(slot: Int, parent: Int) {
    if slot < 0 || slot >= maxProc { return }
    if parent >= 0 && parent < maxProc {
        pSecurity[slot] = pSecurity[parent]
        return
    }
    pSecurity[slot] = securityBootContext()
}

private func copyProcessSecurity(from parent: Int, to child: Int) {
    if parent < 0 || parent >= maxProc || child < 0 || child >= maxProc { return }
    pSecurity[child] = pSecurity[parent] // whole context, including the Cell tag
}

// Build a process from an ELF image. Returns its slot, or -1. `inherit` selects
// how the child's handle table is seeded from the parent (C2): `.all` preserves
// fork-inherits-everything behavior; `.stdioOnly` keeps legacy spawn tight; and
// `.explicit` installs only the provided HandleSpec vector.
private func createProcess(_ image: UInt, _ size: UInt, packed: UInt, packedLen: UInt,
                           argc: Int, parent: Int, inherit: HandleInheritance = .all,
                           inheritSpecsVA: UInt = 0, inheritSpecCount: UInt = 0) -> Int {
    let slot = allocSlot()
    if slot < 0 { return -1 }

    let ttbr0 = address_space_create()
    if ttbr0 == 0 { return -1 }
    let entry = elfLoad(ttbr0, UnsafeRawPointer(bitPattern: image), size)
    if entry == 0 { address_space_destroy(ttbr0); return -1 }

    var va = userStackTop - UInt(userStackPages) * PageAllocator.pageSize
    while va < userStackTop {
        let pa = pmmAllocZeroedPage()
        if pa == 0 || address_space_map(ttbr0, va, pa, Int32(VM_PERM_USER_DATA)) != 0 {
            if pa != 0 { pmmFreePage(pa) }
            address_space_destroy(ttbr0)
            return -1
        }
        va += PageAllocator.pageSize
    }

    let kstack = pmmAllocPages(kernelStackPages)
    if kstack == 0 { address_space_destroy(ttbr0); return -1 }
    let kstackTop = kstack + UInt(kernelStackPages) * PageAllocator.pageSize

    var userSP = userStackTop
    if packedLen > 0 && argc > 0 {
        let built = userStackBuild(ttbr0, userStackTop,
                                     UnsafePointer<CChar>(bitPattern: packed), packedLen, Int32(argc))
        if built != 0 { userSP = built }
    }

    let ctx = procCtx.advanced(by: slot)
    ctx.pointee = CPUContext()
    ctx.pointee.x19 = UInt64(entry)
    ctx.pointee.x20 = UInt64(userSP)
    ctx.pointee.x21 = UInt64(ttbr0)
    ctx.pointee.lr = UInt64(user_thread_launch_addr())
    ctx.pointee.sp = UInt64(kstackTop)

    pParent[slot] = parent
    pTtbr0[slot] = ttbr0
    pKstack[slot] = kstack
    pExit[slot] = 0
    pKilled[slot] = false
    pWait[slot] = waitNone
    pBrk[slot] = userHeapBase
    pMmapTop[slot] = userMmapTop
    fileVmasClear(slot)
    pIsThread[slot] = false
    // elfLoad (above) recorded the image's mapped page count; stack mapping used
    // the PMM directly, so it is still valid. RES = image + user stack pages.
    pCpuTicks[slot] = 0
    pStartTick[slot] = systemTicks
    pResPages[slot] = Int(elfLastLoadPages()) + userStackPages
    pWakeTick[slot] = 0
    setProcessName(slot: slot, packed: packed, argc: argc)
    setProcessSecurity(slot: slot, parent: parent)
    vfsProcessInit(slot: slot, parent: parent, inherit: inherit,
                   specsVA: inheritSpecsVA, specCount: inheritSpecCount)
    markProcessReadyOnHomeCpu(slot)
    return slot
}

private func buildExecImage(_ image: UInt, _ size: UInt, packed: UInt, packedLen: UInt,
                            argc: Int) -> (UInt, UInt, UInt) {
    let ttbr0 = address_space_create()
    if ttbr0 == 0 { return (0, 0, 0) }
    let entry = elfLoad(ttbr0, UnsafeRawPointer(bitPattern: image), size)
    if entry == 0 { address_space_destroy(ttbr0); return (0, 0, 0) }

    var va = userStackTop - UInt(userStackPages) * PageAllocator.pageSize
    while va < userStackTop {
        let pa = pmmAllocZeroedPage()
        if pa == 0 || address_space_map(ttbr0, va, pa, Int32(VM_PERM_USER_DATA)) != 0 {
            if pa != 0 { pmmFreePage(pa) }
            address_space_destroy(ttbr0)
            return (0, 0, 0)
        }
        va += PageAllocator.pageSize
    }

    var userSP = userStackTop
    if packedLen > 0 && argc > 0 {
        let built = userStackBuild(ttbr0, userStackTop,
                                     UnsafePointer<CChar>(bitPattern: packed), packedLen, Int32(argc))
        if built != 0 { userSP = built }
    }
    return (ttbr0, entry, userSP)
}

// Switch from the current process back into the scheduler. Returns when this
// process is scheduled again.
//
// The switch plus the surrounding currentProc/pState bookkeeping is not atomic.
// If a timer IRQ fired mid-switch it would run processOnTick → yieldToScheduler
// re-entrantly and overwrite the very context being saved/restored, corrupting
// the resumed trap frame (observed as a wild SP/PC panic). So mask IRQs across
// the switch; restore the caller's prior IRQ state once this process is resumed
// — preemptive callers (processOnTick) entered with IRQs already masked, while
// cooperative callers in a blocking syscall entered with them enabled.
private func yieldToScheduler() {
    let daif = irq_save()
    let schedulerContext = schedulerContextForCurrentCpu()
    cpu_switch_context(UnsafeMutableRawPointer(procCtx.advanced(by: currentProc)),
                       schedulerContext)
    irq_restore(daif)
}

private func wakeParent(of slot: Int) {
    let pp = pParent[slot]
    if pp >= 0 && pState[pp] == pBlocked && (pWait[pp] == slot || pWait[pp] == waitAny) {
        markProcessReadyOnHomeCpu(pp)
    }
}

/// Reap a zombie slot: return its frames to the PMM and mark the slot unused.
/// The caller must already hold the exit status it needs (this clears nothing
/// but ownership). Safe because a zombie never runs again, so its address space
/// and kernel stack are quiescent; address_space_destroy switches off the
/// doomed TTBR0 first if it happens to be the one currently installed.
private func reapProcess(_ slot: Int) {
    if slot < 0 || slot >= maxProc { return }
    if pTtbr0[slot] != 0 {
        address_space_destroy(pTtbr0[slot])
        pTtbr0[slot] = 0
    }
    if pKstack[slot] != 0 {
        var pa = pKstack[slot]
        for _ in 0..<kernelStackPages {
            pmmFreePage(pa)
            pa += PageAllocator.pageSize
        }
        pKstack[slot] = 0
    }
    pState[slot] = pUnused
    clearProcessSchedulerSlot(slot)
}

// Run the scheduler until `until()` is satisfied (e.g. a target is a zombie).
//
// The loop runs with IRQs masked so a timer tick can never preempt a switch-in
// (currentProc/pState are already updated for the target, but the switch is not
// yet complete). A process re-enables IRQs itself once it truly runs (eret to
// EL0, or irq_restore in yieldToScheduler). Only the idle wait briefly unmasks.
private func schedule(until done: () -> Bool) {
    let daif = irq_save()
    while !done() {
        let s = pickReady()
        if s < 0 {
            // Nothing runnable yet: unmask so the timer/UART IRQ can be serviced
            // (and possibly make something ready), then re-mask. Safe because
            // currentProc == -1 here — processOnTick is a no-op and no switch is
            // in flight.
            enable_irq()
            wfi()
            disable_irq()
            continue
        }
        currentProc = s
        smpSetCurrentProcessForCurrentCpu(Int32(s))
        pState[s] = pRunning
        let cpu = UInt32(processSchedulerCpuIndex())
        recordProcessDispatch(s, on: cpu)
        // cpu_switch_context swaps registers only — install the process's
        // address space so its EL0 user VAs resolve when it eret's.
        address_space_switch(pTtbr0[s])
        recordProcessAddressSpaceActivation(s, on: cpu)
        smpRecordEl0SwitchForCurrentCpu()
        let schedulerContext = schedulerContextForCurrentCpu()
        cpu_switch_context(schedulerContext,
                           UnsafeMutableRawPointer(procCtx.advanced(by: s)))
        smpSetCurrentProcessForCurrentCpu(-1)
        currentProc = -1
    }
    irq_restore(daif)
}

/// Launch an ELF as a top-level process (child of the kernel) and run the
/// scheduler until it exits; reap it and return its exit code.
func processRunElf(_ image: UInt, _ size: UInt, packed: UInt, packedLen: UInt, argc: Int) -> Int {
    let slot = createProcess(image, size, packed: packed, packedLen: packedLen, argc: argc, parent: -1)
    if slot < 0 {
        uartPuts("panic: createProcess failed\n")
        while true {}
    }
    schedule(until: { pState[slot] == pZombie })
    let code = pExit[slot]
    lastReapedKilled = pKilled[slot]
    reapProcess(slot)
    return code
}

/// Run two top-level processes concurrently; return when both have exited.
func processRunPair(_ imageA: UInt, _ sizeA: UInt, _ pa: UInt, _ na: UInt, _ ca: Int,
                    _ imageB: UInt, _ sizeB: UInt, _ pb: UInt, _ nb: UInt, _ cb: Int) {
    let a = createProcess(imageA, sizeA, packed: pa, packedLen: na, argc: ca, parent: -1)
    let b = createProcess(imageB, sizeB, packed: pb, packedLen: nb, argc: cb, parent: -1)
    if a < 0 || b < 0 {
        uartPuts("panic: createProcess (pair) failed\n")
        while true {}
    }
    schedule(until: { pState[a] == pZombie && pState[b] == pZombie })
    captureLastPairDispatchTelemetry(a, b)
    reapProcess(a)
    reapProcess(b)
}

private func processSpawnChildWithInheritance(_ image: UInt, _ size: UInt, packed: UInt,
                                              packedLen: UInt, argc: Int,
                                              inherit: HandleInheritance,
                                              specsVA: UInt = 0, specCount: UInt = 0) -> Int {
    let parent = currentProc
    guard parent >= 0 else { return -22 }
    let valid = vfsValidateHandleInheritance(parent: parent, inherit: inherit,
                                             specsVA: specsVA, specCount: specCount)
    if valid < 0 { return valid }
    let child = createProcess(image, size, packed: packed, packedLen: packedLen, argc: argc,
                              parent: parent, inherit: inherit,
                              inheritSpecsVA: specsVA, inheritSpecCount: specCount)
    if child < 0 { return -11 } // EAGAIN
    pState[parent] = pBlocked
    pWait[parent] = child
    yieldToScheduler() // scheduler runs the child; we resume once it exits
    let code = pExit[child]
    pWait[parent] = waitNone
    reapProcess(child)
    return code
}

/// spawn(path) child: create it with stdio only, block until it exits, return its exit status.
func processSpawnChild(_ image: UInt, _ size: UInt, packed: UInt, packedLen: UInt, argc: Int) -> Int {
    return processSpawnChildWithInheritance(image, size, packed: packed, packedLen: packedLen,
                                            argc: argc, inherit: .stdioOnly)
}

/// spawn_handles(path) child: start from an empty handle table and inherit exactly
/// the caller-provided HandleSpec vector.
func processSpawnChildWithHandles(_ image: UInt, _ size: UInt, packed: UInt, packedLen: UInt,
                                  argc: Int, specsVA: UInt, specCount: UInt) -> Int {
    return processSpawnChildWithInheritance(image, size, packed: packed, packedLen: packedLen,
                                            argc: argc, inherit: .explicit,
                                            specsVA: specsVA, specCount: specCount)
}

func processCurrentPid() -> Int { currentProc >= 0 ? currentProc + 1 : 0 }

func processYieldForIO() {
    if currentProc < 0 { return }
    markProcessReadyOnHomeCpu(currentProc)
    yieldToScheduler()
}

/// fork(): COW-clone the current process. The child gets a cloned address space
/// whose user pages initially share frames with the parent, plus a copy of the
/// parent's trap frame with x0=0, so it "returns from fork()" into EL0 at the
/// same point seeing 0; the parent gets the child pid.
func processFork(_ frame: UnsafeMutablePointer<UInt>) -> Int {
    let parent = currentProc
    guard parent >= 0 else { return -11 }
    let child = allocSlot()
    if child < 0 { return -11 } // EAGAIN

    let childTtbr0 = address_space_clone(pTtbr0[parent])
    if childTtbr0 == 0 { return -12 } // ENOMEM

    let kstack = pmmAllocPages(kernelStackPages)
    if kstack == 0 { address_space_destroy(childTtbr0); return -12 }
    let kstackTop = kstack + UInt(kernelStackPages) * PageAllocator.pageSize

    // Copy the parent's 288-byte trap frame to the top of the child kstack.
    let frameWords = 36
    let childFrameAddr = kstackTop - 288
    let childFrame = UnsafeMutablePointer<UInt>(bitPattern: childFrameAddr)!
    for i in 0..<frameWords { childFrame[i] = frame[i] }
    childFrame[0] = 0 // child's fork() returns 0

    let ctx = procCtx.advanced(by: child)
    ctx.pointee = CPUContext()
    ctx.pointee.sp = UInt64(childFrameAddr)
    ctx.pointee.lr = UInt64(trap_return_addr())

    pParent[child] = parent
    pTtbr0[child] = childTtbr0
    pKstack[child] = kstack
    pExit[child] = 0
    pKilled[child] = false
    pWait[child] = waitNone
    pBrk[child] = pBrk[parent]
    // The COW clone preserves every mapped user page (including mmap'd regions),
    // so the child inherits the parent's mmap cursor verbatim.
    pMmapTop[child] = pMmapTop[parent]
    fileVmasCopy(child, parent)
    pIsThread[child] = false
    // The COW address-space clone preserves the child's logical mapped
    // footprint; physical frames are copied lazily on write. CPU/time start
    // fresh.
    pCpuTicks[child] = 0
    pStartTick[child] = systemTicks
    pResPages[child] = pResPages[parent]
    pWakeTick[child] = 0
    copyProcessName(from: parent, to: child)
    copyProcessSecurity(from: parent, to: child)
    vfsProcessInit(slot: child, parent: parent)
    markProcessReadyOnHomeCpu(child)
    return child + 1 // pid
}

/// thread_create(entryVA, argVA, stackTopVA): spawn a new EL0 thread that SHARES
/// the current process's address space (same TTBR0, hence the same code, data,
/// and heap), runs `entry(arg)` on the caller-supplied user stack, and is
/// schedulable alongside its siblings. This is "fork without copying the address
/// space", plus an explicit entry point and stack — the kernel primitive a
/// userland threading runtime is built on. Returns the new thread's pid, or a
/// negative errno. The shared address space is never torn down here; it outlives
/// every thread (page reclamation is a global follow-up, as for processes).
func processThreadCreate(entryVA: UInt, argVA: UInt, stackTopVA: UInt) -> Int {
    let creator = currentProc
    guard creator >= 0 else { return -22 } // EINVAL: no active process
    // The entry PC and the top of the thread's stack must be valid user VAs in
    // the (shared) address space; reject obvious garbage early.
    if userReadableBuffer(entryVA, 4) == nil { return -14 } // EFAULT
    // The stack grows down from stackTopVA; require the word just below the top
    // to be a writable user VA in the shared space.
    if stackTopVA < 16 || userWritableBuffer(stackTopVA - 16, 16) == nil { return -14 }

    let slot = allocSlot()
    if slot < 0 { return -11 } // EAGAIN: process table full

    let kstack = pmmAllocPages(2)
    if kstack == 0 { return -12 } // ENOMEM
    let kstackTop = kstack + 2 * PageAllocator.pageSize

    // Craft a first-run context that lands in user_thread_launch_arg, which
    // installs the shared TTBR0 and eret's to entry(arg) on the given stack.
    let ctx = procCtx.advanced(by: slot)
    ctx.pointee = CPUContext()
    ctx.pointee.x19 = UInt64(entryVA)             // entry PC
    ctx.pointee.x20 = UInt64(stackTopVA)          // SP_EL0
    ctx.pointee.x21 = UInt64(pTtbr0[creator])     // shared address space
    ctx.pointee.x22 = UInt64(argVA)               // entry argument (x0)
    ctx.pointee.lr = UInt64(user_thread_launch_arg_addr())
    ctx.pointee.sp = UInt64(kstackTop)

    // Parent is the creator's parent so the thread is a sibling, not a child:
    // it must not be reapable by the creator's waitpid (threads join via futex).
    pParent[slot] = pParent[creator]
    pTtbr0[slot] = pTtbr0[creator] // SHARED — not a clone
    pExit[slot] = 0
    pKilled[slot] = false
    pWait[slot] = waitNone
    pBrk[slot] = pBrk[creator]
    // A thread shares the creator's address space; seed it with the same mmap
    // cursor. (Concurrent mmap from multiple threads sharing one TTBR0 would
    // need a shared cursor + lock — a follow-up; single-core today.)
    pMmapTop[slot] = pMmapTop[creator]
    fileVmasCopy(slot, creator)
    pIsThread[slot] = true
    pWakeTick[slot] = 0
    copyProcessName(from: creator, to: slot)
    copyProcessSecurity(from: creator, to: slot)
    // Share VFS state by snapshotting the creator's fd table + cwd (the demo only
    // needs shared stdout; full fd-table aliasing is a follow-up — see NOTES).
    vfsProcessInit(slot: slot, parent: creator)
    markProcessReadyOnHomeCpu(slot)
    return slot + 1 // thread id (a pid in the shared table)
}

/// FUTEX_WAIT backend: block the current thread until a FUTEX_WAKE marks it
/// ready again. Mirrors processYieldForIO but parks in pBlocked (it must not be
/// rescheduled until explicitly woken). Returns once rescheduled.
func processBlockOnFutex() {
    let me = currentProc
    if me < 0 { return }
    pState[me] = pBlocked
    yieldToScheduler()
}

/// FUTEX_WAKE backend: mark a futex-blocked thread runnable again.
func processWakeFromFutex(_ slot: Int) {
    if slot < 0 || slot >= maxProc { return }
    if pState[slot] == pBlocked { markProcessReadyOnHomeCpu(slot) }
}

/// nanosleep(seconds, nanos): block the current process until at least the
/// requested time has elapsed, yielding the CPU meanwhile. The deadline is
/// recorded in systemTicks and the per-tick wake scan (processOnTick) marks the
/// process ready once it passes. Resolution is one timer tick (1/timerHz s), so
/// a sub-tick request still parks for one tick. Always sleeps the full duration
/// (blocked syscalls are not signal-interrupted today). Returns 0.
func processNanosleep(seconds: UInt, nanos: UInt) -> Int {
    let me = currentProc
    guard me >= 0 else { return -22 } // EINVAL: no active process
    let hz = UInt64(timerHz)
    var ticks = UInt64(seconds) &* hz &+ (UInt64(nanos) &* hz) / 1_000_000_000
    if ticks == 0 {
        if seconds == 0 && nanos == 0 { return 0 } // nothing requested
        ticks = 1 // round a sub-tick request up to one tick (≥ one yield)
    }
    pWakeTick[me] = systemTicks + ticks
    pState[me] = pBlocked
    yieldToScheduler()
    pWakeTick[me] = 0
    return 0
}

/// waitpid(pid, *status, opts): reap a (matching) zombie child, blocking until
/// one is available. Returns the child pid, or -10 (ECHILD) if no such child.
func processWaitpid(_ pid: Int, _ statusVA: UInt) -> Int {
    let parent = currentProc
    guard parent >= 0 else { return -10 }
    if statusVA != 0 && userWritableBuffer(statusVA, 4) == nil { return -22 }
    let wantSlot = pid > 0 ? pid - 1 : waitAny

    while true {
        var found = -1
        var live = 0
        for i in 0..<maxProc where pState[i] != pUnused && pParent[i] == parent {
            if wantSlot != waitAny && i != wantSlot { continue }
            live += 1
            if pState[i] == pZombie { found = i; break }
        }
        if found >= 0 {
            let code = pExit[found]
            let killed = pKilled[found]
            reapProcess(found)
            pWait[parent] = waitNone
            if statusVA != 0, let sp = userWritableBuffer(statusVA, 4) {
                // WEXITSTATUS = (s >> 8) & 0xff; signal in low 7 bits.
                let s: Int32 = killed ? Int32(code - 128) : Int32((code & 0xff) << 8)
                UnsafeMutableRawPointer(sp).storeBytes(of: s, as: Int32.self)
            }
            return found + 1
        }
        if live == 0 { return -10 } // ECHILD
        pState[parent] = pBlocked
        pWait[parent] = wantSlot
        yieldToScheduler()
    }
}

/// execve(path, argv, envp): replace the current process image and return from
/// this syscall directly into the new EL0 entry point. envp is ignored today.
func processExec(image: UInt, size: UInt, packed: UInt, packedLen: UInt,
                 argc: Int, frame: UnsafeMutablePointer<UInt>) -> Int {
    let me = currentProc
    guard me >= 0 else { return -22 }

    let (ttbr0, entry, userSP) = buildExecImage(image, size, packed: packed, packedLen: packedLen, argc: argc)
    if ttbr0 == 0 { return -12 } // ENOMEM / invalid image during bring-up

    // The old image is fully replaced; reclaim its frames once we are no longer
    // running on its tables. The kernel stack is reused across exec, so it is
    // not freed here — only the address space.
    let oldTtbr0 = pTtbr0[me]
    pTtbr0[me] = ttbr0
    pBrk[me] = userHeapBase
    pMmapTop[me] = userMmapTop // fresh image: empty mmap arena
    fileVmasClear(me)
    // New image replaces the resident set (old pages are dropped with the old
    // address space); accumulated CPU time and the start tick survive the exec.
    pResPages[me] = Int(elfLastLoadPages()) + userStackPages
    // POSIX: close-on-exec descriptors are dropped across exec. ash relocates
    // its saved fds above 10 with F_DUPFD_CLOEXEC and relies on this.
    vfsCloseCloexec(slot: me)
    setProcessName(slot: me, packed: packed, argc: argc)
    frame[trapFrameSPIndex] = userSP
    frame[trapFrameELRIndex] = entry
    frame[trapFrameSPSRIndex] = 0
    address_space_switch(ttbr0)
    address_space_destroy(oldTtbr0) // now on the new space; old tables are dead
    return 0
}

/// SYS_psinfo: copy fixed-size process records into a caller-provided buffer.
/// Record layout (32 bytes): pid:u32, ppid:u32, state:u32, name[20].
func processSnapshot(buffer: UInt, capacity: UInt) -> Int {
    var total = 0
    let writable = capacity > UInt(maxProc) ? maxProc : Int(capacity)
    if writable > 0 {
        guard let dst = userWritableBuffer(buffer, UInt(writable * psInfoRecordSize)) else {
            return -22
        }
        let raw = UnsafeMutableRawPointer(dst)
        for i in 0..<maxProc where pState[i] != pUnused {
            if total < writable {
                let rec = raw.advanced(by: total * psInfoRecordSize)
                let ppid = pParent[i] >= 0 ? UInt32(pParent[i] + 1) : UInt32(0)
                rec.storeBytes(of: UInt32(i + 1), toByteOffset: 0, as: UInt32.self)
                rec.storeBytes(of: ppid, toByteOffset: 4, as: UInt32.self)
                rec.storeBytes(of: UInt32(bitPattern: pState[i]), toByteOffset: 8, as: UInt32.self)

                let nameDst = rec.advanced(by: 12).assumingMemoryBound(to: UInt8.self)
                var j = 0
                let nameBase = i * procNameMax
                while j < 20 {
                    nameDst[j] = j < pNameLen[i] ? pName[nameBase + j] : 0
                    j += 1
                }
            }
            total += 1
        }
    } else {
        for i in 0..<maxProc where pState[i] != pUnused { total += 1 }
    }
    return total
}

/// SYS_procstat: copy richer fixed-size process records for /bin/top.
/// Record layout (56 bytes, naturally aligned): pid:u32, ppid:u32, state:u32,
/// principal:u32, cpuTicks:u64, startTick:u64, resBytes:u64, name[16].
func processStatSnapshot(buffer: UInt, capacity: UInt) -> Int {
    var total = 0
    let writable = capacity > UInt(maxProc) ? maxProc : Int(capacity)
    if writable > 0 {
        guard let dst = userWritableBuffer(buffer, UInt(writable * procStatRecordSize)) else {
            return -22
        }
        let raw = UnsafeMutableRawPointer(dst)
        let frameBytes = UInt64(PageAllocator.pageSize)
        for i in 0..<maxProc where pState[i] != pUnused {
            if total < writable {
                let rec = raw.advanced(by: total * procStatRecordSize)
                let ppid = pParent[i] >= 0 ? UInt32(pParent[i] + 1) : UInt32(0)
                rec.storeBytes(of: UInt32(i + 1), toByteOffset: 0, as: UInt32.self)
                rec.storeBytes(of: ppid, toByteOffset: 4, as: UInt32.self)
                rec.storeBytes(of: UInt32(bitPattern: pState[i]), toByteOffset: 8, as: UInt32.self)
                rec.storeBytes(of: pSecurity[i].principal, toByteOffset: 12, as: UInt32.self)
                rec.storeBytes(of: pCpuTicks[i], toByteOffset: 16, as: UInt64.self)
                rec.storeBytes(of: pStartTick[i], toByteOffset: 24, as: UInt64.self)
                rec.storeBytes(of: UInt64(pResPages[i]) * frameBytes, toByteOffset: 32, as: UInt64.self)

                let nameDst = rec.advanced(by: 40).assumingMemoryBound(to: UInt8.self)
                var j = 0
                let nameBase = i * procNameMax
                while j < 16 {
                    nameDst[j] = j < pNameLen[i] ? pName[nameBase + j] : 0
                    j += 1
                }
            }
            total += 1
        }
    } else {
        for i in 0..<maxProc where pState[i] != pUnused { total += 1 }
    }
    return total
}

/// SYS_sysinfo: copy a system-wide stats blob for /bin/top.
/// Layout (64 bytes, naturally aligned): uptimeTicks:u64, idleTicks:u64,
/// memTotal:u64, memFree:u64, kernelImage:u64, kernelHeap:u64, hz:u32,
/// procTotal:u32, procRunning:u32, reserved:u32.
func processSysInfo(buffer: UInt) -> Int {
    guard let dst = userWritableBuffer(buffer, UInt(sysInfoSize)) else { return -22 }
    let raw = UnsafeMutableRawPointer(dst)

    var total = 0
    var running = 0
    for i in 0..<maxProc where pState[i] != pUnused {
        total += 1
        if pState[i] == pRunning || pState[i] == pReady { running += 1 }
    }

    let frameBytes = UInt64(PageAllocator.pageSize)
    let memFree = UInt64(pmmFreeCount()) * frameBytes
    let memTotal = UInt64(platform.ramSize)
    // The kernel statically occupies [ramBase + kernelLoadOffset .. __image_end):
    // code + data + bss + boot stack + early heap reservation.
    let imageBytes = UInt64(swiftos_image_end() - (platform.ramBase + kernelLoadOffset))
    let heapBytes = UInt64(swiftos_kernel_heap_used_bytes())

    raw.storeBytes(of: systemTicks, toByteOffset: 0, as: UInt64.self)
    raw.storeBytes(of: idleTicks, toByteOffset: 8, as: UInt64.self)
    raw.storeBytes(of: memTotal, toByteOffset: 16, as: UInt64.self)
    raw.storeBytes(of: memFree, toByteOffset: 24, as: UInt64.self)
    raw.storeBytes(of: imageBytes, toByteOffset: 32, as: UInt64.self)
    raw.storeBytes(of: heapBytes, toByteOffset: 40, as: UInt64.self)
    raw.storeBytes(of: timerHz, toByteOffset: 48, as: UInt32.self)
    raw.storeBytes(of: UInt32(total), toByteOffset: 52, as: UInt32.self)
    raw.storeBytes(of: UInt32(running), toByteOffset: 56, as: UInt32.self)
    raw.storeBytes(of: UInt32(0), toByteOffset: 60, as: UInt32.self)
    return 0
}

/// SYS_security_info: copy the current process security context.
/// Record layout (16 bytes): principal:u32, session:u32, caps:u64.
/// The capability mask of the running process (M13). Used by the VFS to check
/// file access against the process's principal context. The kernel itself
/// (no active process) is fully privileged.
func processCurrentCaps() -> UInt64 {
    currentProc >= 0 ? pSecurity[currentProc].caps : ~UInt64(0)
}

/// The principal id of the running process (M13c). Used by the VFS to stamp the
/// owner on tmpfs nodes it creates. The kernel itself (no active process) acts
/// as the boot/root principal 1.
func processCurrentPrincipal() -> UInt32 {
    currentProc >= 0 ? pSecurity[currentProc].principal : 1
}

func processSecurityInfo(buffer: UInt) -> Int {
    let me = currentProc
    guard me >= 0 else { return -22 }
    guard let dst = userWritableBuffer(buffer, 16) else { return -22 }
    let raw = UnsafeMutableRawPointer(dst)
    raw.storeBytes(of: pSecurity[me].principal, toByteOffset: 0, as: UInt32.self)
    raw.storeBytes(of: pSecurity[me].session, toByteOffset: 4, as: UInt32.self)
    raw.storeBytes(of: pSecurity[me].caps, toByteOffset: 8, as: UInt64.self)
    return 0
}

/// SYS_login: replace the current process's security context after the caller
/// has authenticated a principal (M12b). Privileged: only a process holding
/// capConsole (the boot/login context) may do this, so an ordinary program
/// cannot grant itself a principal or capabilities. The new context is
/// inherited across the subsequent execve into the user's shell.
func processLogin(principal: UInt32, session: UInt32, caps: UInt64) -> Int {
    let me = currentProc
    guard me >= 0 else { return -22 }            // EINVAL
    if (pSecurity[me].caps & capConsole) == 0 { return -1 } // EPERM
    pSecurity[me].principal = principal
    pSecurity[me].session = session
    pSecurity[me].caps = caps
    return 0
}

/// Timer preemption hook (called from the IRQ handler after the GIC EOI).
/// `fromEL0` is true when the timer interrupted user code, false at EL1.
func processOnTick(fromEL0: Bool) {
    if currentCpuId() != 0 {
        uartPuts("panic: processOnTick entered on non-owner CPU\n")
        while true {}
    }

    // Wake any sleepers whose deadline has passed. Runs first and unconditionally
    // (even when currentProc == -1 during the scheduler's idle wfi) so a sleep
    // resumes promptly on an otherwise idle system. Only nanosleep blockers carry
    // a nonzero pWakeTick, so futex/waitpid/IO blockers are left untouched.
    for i in 0..<maxProc where pState[i] == pBlocked && pWakeTick[i] != 0 {
        if systemTicks >= pWakeTick[i] {
            markProcessReadyOnHomeCpu(i)
            pWakeTick[i] = 0
        }
    }

    // CPU accounting for /bin/top. Charge a tick as *user* time to the running
    // process only when the timer interrupted EL0 (it was executing user code);
    // EL1 ticks — the scheduler's idle wfi, and a process parked in a wfi-based
    // blocking syscall (poll/read) — count as idle. So a process sleeping on
    // input shows ~0% CPU and an idle system shows ~100% idle, while a CPU-bound
    // EL0 loop shows ~100%. (Kernel "system" time is bucketed into idle; a
    // separate sy% would need to distinguish syscall work from a wfi wait.)
    if fromEL0 && currentProc >= 0 {
        pCpuTicks[currentProc] &+= 1
    } else {
        idleTicks &+= 1
    }
    if currentProc >= 0 && pState[currentProc] == pRunning {
        markProcessReadyOnHomeCpu(currentProc)
        yieldToScheduler()
    }
}

/// SYS_exit: zombify the current process, wake a waiting parent, leave the CPU.
func processExit(_ code: Int) {
    let me = currentProc
    vfsProcessCloseAll(slot: me)
    // rt-a: a thread has no waitpid joiner (siblings join via futex), so it must
    // not linger as an unreapable zombie — free its slot directly. The shared
    // address space stays mapped for the surviving threads. Drop any stale futex
    // wait record first so a later wake cannot resurrect a reused slot.
    if pIsThread[me] {
        futexForgetSlot(me)
        pState[me] = pUnused
        clearProcessSchedulerSlot(me)
        yieldToScheduler()
        while true { wfi() }
    }
    pExit[me] = code
    pKilled[me] = false
    pState[me] = pZombie
    wakeParent(of: me)
    yieldToScheduler()
    while true { wfi() }
}

/// Fatal-signal termination of the current process (status 128+signo).
func processTerminateBySignal(_ sig: Int) {
    let me = currentProc
    vfsProcessCloseAll(slot: me)
    pExit[me] = 128 + sig
    pKilled[me] = true
    pState[me] = pZombie
    wakeParent(of: me)
    yieldToScheduler()
    while true { wfi() }
}

/// sbrk(incr): grow the current process's heap, mapping pages from the PMM.
func processSbrk(_ incr: Int) -> UInt {
    let fail = UInt(bitPattern: -1)
    guard currentProc >= 0 else { return fail }
    let me = currentProc
    let old = pBrk[me]
    if incr == 0 { return old }

    let newBreak = UInt(bitPattern: Int(bitPattern: old) + incr)
    if newBreak < userHeapBase { return fail }

    let mask = PageAllocator.pageSize - 1
    let oldTop = (old + mask) & ~mask
    let newTop = (newBreak + mask) & ~mask
    if newTop > oldTop {
        var va = oldTop
        while va < newTop {
            let pa = pmmAllocZeroedPage()
            if pa == 0 || address_space_map(pTtbr0[me], va, pa, Int32(VM_PERM_USER_DATA)) != 0 {
                if pa != 0 { pmmFreePage(pa) }
                if va > oldTop {
                    _ = address_space_munmap(pTtbr0[me], oldTop, (va - oldTop) / PageAllocator.pageSize)
                }
                return fail
            }
            va += PageAllocator.pageSize
        }
        pResPages[me] += Int((newTop - oldTop) / PageAllocator.pageSize)
    }
    pBrk[me] = newBreak
    return old
}

// --- Track B: anonymous mmap / munmap / mprotect ----------------------------
// The return convention mirrors raw-syscall mmap: a success is the base VA, a
// failure is a small negative errno encoded as UInt (in [-4095, -1]); the
// userland bridge converts that to MAP_FAILED + errno. munmap/mprotect return 0
// or a negative errno (Int) and route through the normal errno path.

private func roundUpPages(_ len: UInt) -> UInt {
    let mask = PageAllocator.pageSize - 1
    return ((len + mask) & ~mask) / PageAllocator.pageSize
}

/// mmap(NULL, len, prot, MAP_ANONYMOUS|MAP_PRIVATE): reserve `len` (rounded up to
/// whole pages) of fresh, zero-filled anonymous memory in the descending mmap
/// arena and return its base VA. prot is a PROT_* bitmask; PROT_WRITE|PROT_EXEC
/// (W^X) and PROT_NONE are rejected with EINVAL. Errors are returned as a
/// negative errno encoded in the UInt result.
func processMmap(_ len: UInt, _ prot: Int32) -> UInt {
    func err(_ e: Int) -> UInt { UInt(bitPattern: e) }
    guard currentProc >= 0 else { return err(-22) } // EINVAL
    let me = currentProc
    if len == 0 { return err(-22) }
    // W^X / PROT_NONE up front (also enforced in protPageDesc, defensively).
    if (prot & PROT_WRITE) != 0 && (prot & PROT_EXEC) != 0 { return err(-22) }
    if (prot & (PROT_READ | PROT_WRITE | PROT_EXEC)) == 0 { return err(-22) }

    let pages = roundUpPages(len)
    let bytes = pages * PageAllocator.pageSize
    // Carve the region just below the cursor, growing down. Guard against
    // underflow and against running into the stack region.
    if pMmapTop[me] < userMmapFloor + bytes { return err(-12) } // ENOMEM: arena full
    let base = pMmapTop[me] - bytes

    let rc = address_space_mmap(pTtbr0[me], base, pages, prot)
    if rc != 0 { return err(Int(rc)) }
    pMmapTop[me] = base
    pResPages[me] += Int(pages)
    return base
}

/// I2: file-backed read-only mmap (demand-paged). Reserve [0, len) of the
/// disk-backed file open on `fd` in the descending mmap arena and record its
/// backing, but map NO frames now — pages fault in lazily on first access
/// (processHandleFileFault), so resident memory grows only with pages actually
/// touched. Returns the base VA, or a negative errno encoded in the UInt result.
/// (NOTE: munmap of a lazily-reserved region is not yet wired to deactivate its
/// VMA; the model-serving path maps once and exits, which is covered.)
func processMmapFile(_ fd: Int, _ len: UInt, _ prot: Int32) -> UInt {
    func err(_ e: Int) -> UInt { UInt(bitPattern: e) }
    guard currentProc >= 0 else { return err(-22) } // EINVAL
    let me = currentProc
    if len == 0 { return err(-22) }
    // Read-only file views only for now (model weights); write/exec is future work.
    if prot != PROT_READ { return err(-22) }
    let (ok, diskImage, diskOff, dataLen) = vfsFileExtent(fd: fd)
    if !ok { return err(-13) } // EACCES: not a readable disk-backed file
    let mapLen = len > UInt(dataLen) ? UInt(dataLen) : len
    if mapLen == 0 { return err(-22) }
    let pages = roundUpPages(mapLen)
    let bytes = pages * PageAllocator.pageSize
    if pMmapTop[me] < userMmapFloor + bytes { return err(-12) } // ENOMEM: arena full
    let base = pMmapTop[me] - bytes
    if !fileVmaAdd(me, base, pages, diskImage, UInt(diskOff), mapLen, prot) { return err(-12) }
    pMmapTop[me] = base
    return base
}

/// I2b: service a demand fault on a lazily-reserved file-backed region. Returns
/// true if `faultVA` fell in such a region and the missing page was mapped in
/// read-only from disk; false otherwise (the caller treats that as a real fault,
/// e.g. a write to a read-only page, which falls through to COW / panic).
func processHandleFileFault(_ faultVA: UInt) -> Bool {
    let me = currentProc
    guard me >= 0 else { return false }
    let pageSize = PageAllocator.pageSize
    let pageVA = faultVA & ~(pageSize - 1)
    for i in 0..<maxFileVmas {
        let v = pFileVmas[me * maxFileVmas + i]
        if !v.active { continue }
        if pageVA < v.base || pageVA >= v.base + v.pages * pageSize { continue }
        let contentStart = ((pageVA - v.base) / pageSize) * pageSize
        let remaining = v.fileLen > contentStart ? v.fileLen - contentStart : 0
        let contentLen = remaining < pageSize ? remaining : pageSize
        if addressSpaceMapFilePage(pTtbr0[me], pageVA, v.diskImage, v.diskOffset + contentStart, contentLen, v.prot) {
            pResPages[me] += 1
            fileDemandFaults += 1
            if !fileDemandLogged {
                fileDemandLogged = true
                klog(.info, "vm", "demand-paged file mmap active")
            }
            return true
        }
        return false // region matched but the page was already mapped (real fault)
    }
    return false
}

/// munmap(addr, len): unmap and free `len` (rounded up) bytes at `addr`. addr
/// must be page-aligned and lie in the mmap arena. Returns 0 or a negative errno.
func processMunmap(_ addr: UInt, _ len: UInt) -> Int {
    guard currentProc >= 0 else { return -22 }
    let me = currentProc
    if len == 0 { return -22 }
    if (addr & (PageAllocator.pageSize - 1)) != 0 { return -22 } // EINVAL: unaligned
    let pages = roundUpPages(len)
    let bytes = pages * PageAllocator.pageSize
    // Must sit wholly inside the arena [pMmapTop, userMmapTop).
    if addr < pMmapTop[me] || addr >= userMmapTop { return -22 }
    if addr > userMmapTop - bytes { return -22 } // range would overrun the arena top

    // Count live pages before freeing so resident accounting stays correct
    // (munmap of a hole is allowed and frees nothing there).
    var live = 0
    var i: UInt = 0
    while i < pages {
        if address_space_translate(pTtbr0[me], addr + i * PageAllocator.pageSize) != 0 { live += 1 }
        i += 1
    }
    let rc = address_space_munmap(pTtbr0[me], addr, pages)
    if rc != 0 { return Int(rc) }
    pResPages[me] -= live
    // I6: a lazily-reserved file VMA must not survive its munmap — the cursor
    // reclaim below can hand the same VA range to a future mmap, and a stale
    // VMA would demand-fill the new mapping from the OLD file's disk extent.
    // Any overlap deactivates the whole VMA (and frees its slot). A partial
    // munmap therefore drops demand paging for the VMA's remaining pages:
    // already-materialized ones stay mapped, untouched ones become fatal on
    // access — acceptable for the map-whole/unmap-whole file pattern, and
    // documented here until a VMA split is needed.
    for vi in 0..<maxFileVmas {
        let idx = me * maxFileVmas + vi
        if !pFileVmas[idx].active { continue }
        let vBase = pFileVmas[idx].base
        let vEnd = vBase + pFileVmas[idx].pages * PageAllocator.pageSize
        if addr < vEnd && addr + bytes > vBase { pFileVmas[idx].active = false }
    }
    // Cursor reclaim: if the freed region sat at the bottom of the arena, hand
    // the VA space back so a later mmap can reuse it. (Interior holes are left
    // as gaps — a free-list is a follow-up; the JIT pattern maps once.)
    if addr == pMmapTop[me] { pMmapTop[me] += bytes }
    return 0
}

/// mprotect(addr, len, prot): change protection on an existing mapping. addr
/// must be page-aligned and in the mmap arena; every page in the range must be
/// mapped. PROT_WRITE|PROT_EXEC (W^X) and PROT_NONE are rejected. This is the
/// JIT lever: write code as RW, then flip the region to RX. Returns 0 or errno.
func processMprotect(_ addr: UInt, _ len: UInt, _ prot: Int32) -> Int {
    guard currentProc >= 0 else { return -22 }
    let me = currentProc
    if len == 0 { return -22 }
    if (addr & (PageAllocator.pageSize - 1)) != 0 { return -22 }
    // W^X invariant enforced HERE (syscall entry) as well as in protPageDesc.
    if (prot & PROT_WRITE) != 0 && (prot & PROT_EXEC) != 0 { return -22 } // EINVAL
    if (prot & (PROT_READ | PROT_WRITE | PROT_EXEC)) == 0 { return -22 }
    let pages = roundUpPages(len)
    let bytes = pages * PageAllocator.pageSize
    if addr < pMmapTop[me] || addr >= userMmapTop { return -22 }
    if addr > userMmapTop - bytes { return -22 }
    return Int(address_space_mprotect(pTtbr0[me], addr, pages, prot))
}
