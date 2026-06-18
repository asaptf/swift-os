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
private let userStackPages = 16
private let kernelStackPages = 2 // per-process EL1 stack; freed on reap
private let userHeapBase: UInt = 0xA000_0000

// Track B — anonymous mmap arena. The valid user window is [0x8000_0000,
// 0x4_0000_0000) (user_access.swift, 16 GiB). Fixed regions: the ELF image at
// 0x8000_0000 growing UP (Node is ~57 MiB; busybox ~1.1 MiB); the 16-page user
// stack at the top of [0x8FFF_0000, 0x9000_0000); the sbrk heap from 0xA000_0000
// growing UP and capped just below the mmap floor (so ~1.5 GiB of heap); and the
// anonymous mmap arena filling [0x1_0000_0000, 0x4_0000_0000) (12 GiB), growing
// DOWN from the top. The arena is virtual address space — pages commit from the
// PMM on touch, so the 12 GiB ceiling never reserves physical RAM; it just lets
// V8 place its large heap/code reservations without exhausting the arena (the
// previous 128 MiB arena did, intermittently, surfacing as a fatal V8 OOM). The
// cursor is per-process (pMmapTop), reset on exec, copied on fork. Growing down
// (away from the heap) mirrors the classic Linux mmap layout.
private let userMmapTop: UInt = 0x4_0000_0000
private let userMmapFloor: UInt = 0x1_0000_0000 // heap/mmap boundary; arena grows down from the top
private let maxProc = 16
private let procNameMax = 16
private let psInfoRecordSize = 32
private let procStatRecordSize = 56 // richer per-process record for /bin/top
private let sysInfoLegacySize = 64  // original system-wide stats blob for /bin/top
private let sysInfoCpuMax = 8
private let sysInfoSize = sysInfoLegacySize + 8 + (sysInfoCpuMax * 16)
private let kernelLoadOffset: UInt = 0x80000 // kernel links/loads at ramBase + this

private let trapFrameSPIndex = 31
private let trapFrameELRIndex = 32
private let trapFrameSPSRIndex = 33
private let trapFrameBytes = 816
private let trapFrameWords = trapFrameBytes / 8
private let signalFrameMagic: UInt = 0x5349_4746_5241_4D45 // "SIGFRAME"
private let signalFrameHeaderWords = 2
private let signalFrameWords = signalFrameHeaderWords + trapFrameWords
private let signalFrameBytes = signalFrameWords * 8

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
private let s5cPlacementStressRounds: UInt64 = 3
private let s5cPlacementStressCpu0TailCount: UInt64 = 2

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

// NPM8: anonymous reservations for V8-style reserve/commit/decommit flows.
// A PROT_NONE mmap records VA only; mprotect later commits pages by allocating
// zero-filled frames, and mprotect(PROT_NONE) decommits live pages while leaving
// the reservation active.
private struct AnonVma {
    var active = false
    var base: UInt = 0
    var pages: UInt = 0
}
// V8/cppgc keep many anonymous mmap regions live at once (the heap cage, each
// cppgc/Oilpan page, the code range, per-thread stacks, ...) — far more than the
// old cap of 16, which made anonVmaAdd fail -> mmap ENOMEM -> intermittent V8
// "out of memory" at init (the cppgc/Oilpan allocation failure). 512 covers Node.
private let maxAnonVmas = 512
private var pAnonVmas = [AnonVma](repeating: AnonVma(), count: maxProc * maxAnonVmas)

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

private func anonVmasClear(_ slot: Int) {
    for i in 0..<maxAnonVmas { pAnonVmas[slot * maxAnonVmas + i].active = false }
}
private func anonVmasCopy(_ dst: Int, _ src: Int) {
    for i in 0..<maxAnonVmas { pAnonVmas[dst * maxAnonVmas + i] = pAnonVmas[src * maxAnonVmas + i] }
}
private func anonVmaAdd(_ slot: Int, _ base: UInt, _ pages: UInt) -> Bool {
    for i in 0..<maxAnonVmas {
        let idx = slot * maxAnonVmas + i
        if !pAnonVmas[idx].active {
            pAnonVmas[idx] = AnonVma(active: true, base: base, pages: pages)
            return true
        }
    }
    return false
}
private func anonVmaContains(_ slot: Int, _ addr: UInt, _ pages: UInt) -> Bool {
    let len = pages * PageAllocator.pageSize
    for i in 0..<maxAnonVmas {
        let v = pAnonVmas[slot * maxAnonVmas + i]
        if !v.active { continue }
        let vEnd = v.base + v.pages * PageAllocator.pageSize
        if addr >= v.base && addr <= vEnd && len <= vEnd - addr { return true }
    }
    return false
}
private func anonVmaOverlaps(_ slot: Int, _ addr: UInt, _ pages: UInt) -> Bool {
    let end = addr + pages * PageAllocator.pageSize
    for i in 0..<maxAnonVmas {
        let v = pAnonVmas[slot * maxAnonVmas + i]
        if !v.active { continue }
        let vEnd = v.base + v.pages * PageAllocator.pageSize
        if addr < vEnd && end > v.base { return true }
    }
    return false
}
private func anonVmasDeactivateOverlap(_ slot: Int, _ addr: UInt, _ pages: UInt) {
    let end = addr + pages * PageAllocator.pageSize
    for i in 0..<maxAnonVmas {
        let idx = slot * maxAnonVmas + i
        if !pAnonVmas[idx].active { continue }
        let vBase = pAnonVmas[idx].base
        let vEnd = vBase + pAnonVmas[idx].pages * PageAllocator.pageSize
        if addr < vEnd && end > vBase { pAnonVmas[idx].active = false }
    }
}
// Partial munmap with VMA split. Unlike anonVmasDeactivateOverlap (which drops
// the whole VMA on any overlap), this trims the unmapped sub-range out of each
// overlapping anon VMA and re-adds the surviving head/tail segments. Required by
// V8's aligned allocator: OS::Allocate over-allocates, then munmaps the
// unaligned prefix/suffix — the aligned middle must remain a tracked VMA so a
// later mprotect(commit) can demand-fill it. The re-added segments never overlap
// the unmapped range, so they are safe to encounter later in the same scan.
private func anonVmasUnmapRange(_ slot: Int, _ addr: UInt, _ pages: UInt) {
    let uStart = addr
    let uEnd = addr + pages * PageAllocator.pageSize
    for i in 0..<maxAnonVmas {
        let idx = slot * maxAnonVmas + i
        if !pAnonVmas[idx].active { continue }
        let vBase = pAnonVmas[idx].base
        let vEnd = vBase + pAnonVmas[idx].pages * PageAllocator.pageSize
        if uStart >= vEnd || uEnd <= vBase { continue } // no overlap
        pAnonVmas[idx].active = false
        if vBase < uStart {
            _ = anonVmaAdd(slot, vBase, (uStart - vBase) / PageAllocator.pageSize)
        }
        if uEnd < vEnd {
            _ = anonVmaAdd(slot, uEnd, (vEnd - uEnd) / PageAllocator.pageSize)
        }
    }
}
private var pNameLen = [Int](repeating: 0, count: maxProc)
private var pName = [UInt8](repeating: 0, count: maxProc * procNameMax)
// Principal / session / capability mask, plus the process's Cell tag, kept as
// one typed record per slot (adding a Cell field is now a struct change, not a
// new parallel array).
private var pSecurity = [ProcessSecurityContext](
    repeating: ProcessSecurityContext(principal: 0, session: 0, caps: 0, cell: globalCell,
                                      realPrincipal: 0, realSession: 0, realCaps: 0),
    count: maxProc)
// rt-a: a thread shares its creator's address space (TTBR0) instead of owning a
// private one, so its exit must not be treated as an address-space teardown and
// it joins via futex rather than waitpid.
private var pIsThread = [Bool](repeating: false, count: maxProc)
private var pSignalFrameActive = [Bool](repeating: false, count: maxProc)
private var pSignalFrameSP = [UInt](repeating: 0, count: maxProc)
// HC36: per-process pending-signal bitmask (index = signo). Signals are now
// targeted at a specific process slot (e.g. a PTY's foreground process) rather
// than a single global foreground, and delivered when that slot next returns to
// EL0. Dispositions/restorers remain process-global in signal.swift for now.
private var pPendingSignals = [UInt32](repeating: 0, count: maxProc)

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
private var pSchedulerQuiesced = [Bool](repeating: true, count: maxProc)
// QW3: true once a slot has been reparented to the kernel (-1) at RUNTIME because
// its real parent was reaped while it was still live. Distinguishes a runtime
// orphan that nobody will waitpid() (collect it in the scheduler when it exits)
// from a process born top-level with parent -1 (its orchestrator reaps it).
private var pReparentedOrphan = [Bool](repeating: false, count: maxProc)

private var processRunQueueHead = [Int32](repeating: noProcessSlot, count: processSchedulerCpuSlots)
private var processRunQueueTail = [Int32](repeating: noProcessSlot, count: processSchedulerCpuSlots)
private var processRunQueueLockWord = [UInt64](repeating: 0, count: processSchedulerCpuSlots)
private var processRunQueueLockAcquireCount = [UInt64](repeating: 0, count: processSchedulerCpuSlots)
private var processRunQueueLockContentionCount = [UInt64](repeating: 0, count: processSchedulerCpuSlots)
private var processRunQueueEnqueueCount = [UInt64](repeating: 0, count: processSchedulerCpuSlots)
private var processRunQueueDispatchCount = [UInt64](repeating: 0, count: processSchedulerCpuSlots)
private var processDispatchTelemetryCount = [UInt64](repeating: 0, count: processSchedulerCpuSlots)
private var processAddressSpaceActivationCount = [UInt64](repeating: 0, count: processSchedulerCpuSlots)
private var processRunQueueCpuCount: UInt32 = 0
private var processSecondarySchedulerRunMask: UInt64 = 0
private var processSecondarySchedulerActiveMask: UInt64 = 0
private var processSecondarySchedulerStopMask: UInt64 = 0

private var lastPairDispatchTelemetryValid = false
private var lastPairDispatchCountA: UInt64 = 0
private var lastPairDispatchCountB: UInt64 = 0
private var lastPairDispatchCpuMaskA: UInt64 = 0
private var lastPairDispatchCpuMaskB: UInt64 = 0
private var lastPairLastDispatchCpuA: UInt32 = unassignedCpu
private var lastPairLastDispatchCpuB: UInt32 = unassignedCpu
private var lastS5bBatchDispatchTelemetryValid = false
private var lastS5bBatchDispatchCountA: UInt64 = 0
private var lastS5bBatchDispatchCountB: UInt64 = 0
private var lastS5bBatchDispatchCountC: UInt64 = 0
private var lastS5bBatchDispatchCpuMaskA: UInt64 = 0
private var lastS5bBatchDispatchCpuMaskB: UInt64 = 0
private var lastS5bBatchDispatchCpuMaskC: UInt64 = 0
private var lastS5bBatchLastDispatchCpuA: UInt32 = unassignedCpu
private var lastS5bBatchLastDispatchCpuB: UInt32 = unassignedCpu
private var lastS5bBatchLastDispatchCpuC: UInt32 = unassignedCpu
private var lastS5cStressTelemetryValid = false
private var lastS5cStressRounds: UInt64 = 0
private var lastS5cStressProcessCount: UInt64 = 0
private var lastS5cStressPrimaryDispatchCount: UInt64 = 0
private var lastS5cStressSecondaryDispatchCount: UInt64 = 0
private var lastS5cStressPrimaryCpuMask: UInt64 = 0
private var lastS5cStressSecondaryCpuMask: UInt64 = 0
private var lastS5cStressSecondaryCpu: UInt32 = unassignedCpu
private var lastS5cStressRunQueueLockAcquireCount: UInt64 = 0
private var lastS5cStressRunQueueLockContentionCount: UInt64 = 0
private var lastS5dFanoutTelemetryValid = false
private var lastS5dFanoutProcessCount: UInt64 = 0
private var lastS5dFanoutSchedulerCpuMask: UInt64 = 0
private var lastS5dFanoutDispatchCpuMask: UInt64 = 0
private var lastS5dFanoutSecondaryCpuMask: UInt64 = 0
private var lastS5dFanoutDispatchCount: UInt64 = 0
private var lastS5dFanoutExactCpuMatchCount: UInt64 = 0
private var s5dFanoutSlots = [Int](repeating: -1, count: processSchedulerCpuSlots)
private var lastS5eThreadFanoutTelemetryValid = false
private var lastS5eThreadCreateCount: UInt64 = 0
private var lastS5eThreadExitCount: UInt64 = 0
private var lastS5eThreadSharedAddressSpaceCount: UInt64 = 0
private var lastS5eThreadHomeCpuMask: UInt64 = 0
private var lastS5eThreadDispatchCpuMask: UInt64 = 0
private var lastS5eThreadSecondaryCpuMask: UInt64 = 0
private var lastS5eThreadDispatchCount: UInt64 = 0
private var lastS5eThreadExactCpuMatchCount: UInt64 = 0
private var lastS5eThreadFutexLockAcquireCount: UInt64 = 0
private var lastS5eThreadFutexLockContentionCount: UInt64 = 0
private var lastS5eThreadTelemetryLockAcquireCount: UInt64 = 0
private var lastS5eThreadTelemetryLockContentionCount: UInt64 = 0
private var s5eThreadPlacementActive = false
private var s5eNextThreadCpu: UInt32 = 1
private var s5eThreadTelemetryLockWord: UInt64 = 0
private var s5eThreadTelemetryLockAcquireCount: UInt64 = 0
private var s5eThreadTelemetryLockContentionCount: UInt64 = 0
private var lastS5fRunAnyTelemetryValid = false
private var lastS5fRunAnyProcessCount: UInt64 = 0
private var lastS5fRunAnySchedulerCpuMask: UInt64 = 0
private var lastS5fRunAnyDispatchCpuMask: UInt64 = 0
private var lastS5fRunAnySecondaryCpuMask: UInt64 = 0
private var lastS5fRunAnyDispatchCount: UInt64 = 0
private var lastS5fRunAnyExactCpuMatchCount: UInt64 = 0
private var lastS5fRunAnyPolicySelectionCount: UInt64 = 0
private var s5fRunAnyPlacementActive = false
private var s5fNextPlacementCpu: UInt32 = 0
private var s5fRunAnySlots = [Int](repeating: -1, count: maxProc)

private var currentProcByCpu = [Int](repeating: -1, count: processSchedulerCpuSlots)
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
    processAtomicStore(&processSecondarySchedulerRunMask, 0)
    processAtomicStore(&processSecondarySchedulerActiveMask, 0)
    processAtomicStore(&processSecondarySchedulerStopMask, 0)
    var cpu: UInt32 = 0
    while cpu < cpuCount {
        schedCtx[Int(cpu)] = CPUContext()
        processRunQueueHead[Int(cpu)] = noProcessSlot
        processRunQueueTail[Int(cpu)] = noProcessSlot
        processRunQueueLockWord[Int(cpu)] = 0
        processRunQueueLockAcquireCount[Int(cpu)] = 0
        processRunQueueLockContentionCount[Int(cpu)] = 0
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
        pSchedulerQuiesced[i] = true
        pReparentedOrphan[i] = false
        pSignalFrameActive[i] = false
        pSignalFrameSP[i] = 0
        pPendingSignals[i] = 0
    }
    for cpuSlot in 0..<processSchedulerCpuSlots {
        currentProcByCpu[cpuSlot] = -1
    }
    lastPairDispatchTelemetryValid = false
    lastPairDispatchCountA = 0
    lastPairDispatchCountB = 0
    lastPairDispatchCpuMaskA = 0
    lastPairDispatchCpuMaskB = 0
    lastPairLastDispatchCpuA = unassignedCpu
    lastPairLastDispatchCpuB = unassignedCpu
    lastS5bBatchDispatchTelemetryValid = false
    lastS5bBatchDispatchCountA = 0
    lastS5bBatchDispatchCountB = 0
    lastS5bBatchDispatchCountC = 0
    lastS5bBatchDispatchCpuMaskA = 0
    lastS5bBatchDispatchCpuMaskB = 0
    lastS5bBatchDispatchCpuMaskC = 0
    lastS5bBatchLastDispatchCpuA = unassignedCpu
    lastS5bBatchLastDispatchCpuB = unassignedCpu
    lastS5bBatchLastDispatchCpuC = unassignedCpu
    lastS5cStressTelemetryValid = false
    lastS5cStressRounds = 0
    lastS5cStressProcessCount = 0
    lastS5cStressPrimaryDispatchCount = 0
    lastS5cStressSecondaryDispatchCount = 0
    lastS5cStressPrimaryCpuMask = 0
    lastS5cStressSecondaryCpuMask = 0
    lastS5cStressSecondaryCpu = unassignedCpu
    lastS5cStressRunQueueLockAcquireCount = 0
    lastS5cStressRunQueueLockContentionCount = 0
    lastS5dFanoutTelemetryValid = false
    lastS5dFanoutProcessCount = 0
    lastS5dFanoutSchedulerCpuMask = 0
    lastS5dFanoutDispatchCpuMask = 0
    lastS5dFanoutSecondaryCpuMask = 0
    lastS5dFanoutDispatchCount = 0
    lastS5dFanoutExactCpuMatchCount = 0
    for cpuSlot in 0..<processSchedulerCpuSlots {
        s5dFanoutSlots[cpuSlot] = -1
    }
    resetLastS5eThreadFanoutTelemetry()
    s5eThreadTelemetryLockWord = 0
    s5eThreadTelemetryLockAcquireCount = 0
    s5eThreadTelemetryLockContentionCount = 0
    resetLastS5fRunAnyTelemetry()
}

private func processAtomicLoad(_ value: inout UInt64) -> UInt64 {
    withUnsafeMutablePointer(to: &value) { smpAtomicLoad($0) }
}

private func processAtomicStore(_ value: inout UInt64, _ newValue: UInt64) {
    withUnsafeMutablePointer(to: &value) { smpAtomicStore($0, newValue) }
}

private func processRunQueueAtomicLoad(_ value: inout UInt64) -> UInt64 {
    withUnsafeMutablePointer(to: &value) { smpAtomicLoad($0) }
}

private func processRunQueueLock(_ cpu: UInt32) -> UInt64 {
    if !processValidSchedulerCpu(cpu) {
        uartPuts("panic: invalid EL0 run queue lock CPU\n")
        while true {}
    }
    let daif = irq_save()
    let idx = Int(cpu)
    var contended = false
    while true {
        var expected: UInt64 = 0
        let acquired = withUnsafeMutablePointer(to: &processRunQueueLockWord[idx]) { word in
            smpAtomicCompareExchange(word, expected: &expected, desired: 1)
        }
        if acquired {
            if contended {
                withUnsafeMutablePointer(to: &processRunQueueLockContentionCount[idx]) { count in
                    _ = smpAtomicFetchAdd(count, 1)
                }
            }
            withUnsafeMutablePointer(to: &processRunQueueLockAcquireCount[idx]) { count in
                _ = smpAtomicFetchAdd(count, 1)
            }
            smpMemoryBarrier()
            return daif
        }
        contended = true
        smpLoadBarrier()
    }
}

private func processRunQueueUnlock(_ cpu: UInt32, _ daif: UInt64) {
    if !processValidSchedulerCpu(cpu) {
        uartPuts("panic: invalid EL0 run queue unlock CPU\n")
        while true {}
    }
    smpMemoryBarrier()
    withUnsafeMutablePointer(to: &processRunQueueLockWord[Int(cpu)]) { word in
        smpAtomicStore(word, 0)
    }
    irq_restore(daif)
}

private func processRunQueueLockAcquireTotal() -> UInt64 {
    var total: UInt64 = 0
    var cpu: UInt32 = 0
    while cpu < processRunQueueCpuCount {
        total &+= processRunQueueAtomicLoad(&processRunQueueLockAcquireCount[Int(cpu)])
        cpu += 1
    }
    return total
}

private func processRunQueueLockContentionTotal() -> UInt64 {
    var total: UInt64 = 0
    var cpu: UInt32 = 0
    while cpu < processRunQueueCpuCount {
        total &+= processRunQueueAtomicLoad(&processRunQueueLockContentionCount[Int(cpu)])
        cpu += 1
    }
    return total
}

private func processS5eThreadTelemetryLock() -> UInt64 {
    let daif = irq_save()
    var contended = false
    while true {
        var expected: UInt64 = 0
        let acquired = withUnsafeMutablePointer(to: &s5eThreadTelemetryLockWord) { word in
            smpAtomicCompareExchange(word, expected: &expected, desired: 1)
        }
        if acquired {
            if contended {
                withUnsafeMutablePointer(to: &s5eThreadTelemetryLockContentionCount) { count in
                    _ = smpAtomicFetchAdd(count, 1)
                }
            }
            withUnsafeMutablePointer(to: &s5eThreadTelemetryLockAcquireCount) { count in
                _ = smpAtomicFetchAdd(count, 1)
            }
            smpMemoryBarrier()
            return daif
        }
        contended = true
        smpLoadBarrier()
    }
}

private func processS5eThreadTelemetryUnlock(_ daif: UInt64) {
    smpMemoryBarrier()
    withUnsafeMutablePointer(to: &s5eThreadTelemetryLockWord) { word in
        smpAtomicStore(word, 0)
    }
    irq_restore(daif)
}

private func processS5eThreadTelemetryLockAcquireCount() -> UInt64 {
    processRunQueueAtomicLoad(&s5eThreadTelemetryLockAcquireCount)
}

private func processS5eThreadTelemetryLockContentionCount() -> UInt64 {
    processRunQueueAtomicLoad(&s5eThreadTelemetryLockContentionCount)
}

private func processCpuBit(_ cpu: UInt32) -> UInt64 {
    if cpu >= 64 { return 0 }
    return UInt64(1) << Int(cpu)
}

private func processCurrentCpuIndex() -> Int {
    let cpu = currentCpuId()
    if cpu >= UInt32(processSchedulerCpuSlots) {
        uartPuts("panic: invalid process CPU index\n")
        while true {}
    }
    return Int(cpu)
}

private func currentProcessSlot() -> Int {
    currentProcByCpu[processCurrentCpuIndex()]
}

private func clearSignalFrameState(_ slot: Int) {
    if slot < 0 || slot >= maxProc { return }
    pSignalFrameActive[slot] = false
    pSignalFrameSP[slot] = 0
}

// --- per-process pending signals (HC36) ---------------------------------------
// Storage lives here (next to the rest of the per-slot process state and the
// only place that knows maxProc); signal.swift drives policy through these.

/// Mark `sig` pending for process `slot`. No-op for an invalid slot or signo.
func processSignalMarkPending(_ slot: Int, _ sig: Int) {
    guard slot >= 0 && slot < maxProc, sig > 0 && sig < 32 else { return }
    pPendingSignals[slot] |= (UInt32(1) << UInt32(sig))
}

/// Clear the pending bit for `sig` on process `slot`.
func processSignalClearPending(_ slot: Int, _ sig: Int) {
    guard slot >= 0 && slot < maxProc, sig > 0 && sig < 32 else { return }
    pPendingSignals[slot] &= ~(UInt32(1) << UInt32(sig))
}

/// True if `sig` is pending for process `slot`.
func processSignalIsPending(_ slot: Int, _ sig: Int) -> Bool {
    guard slot >= 0 && slot < maxProc, sig > 0 && sig < 32 else { return false }
    return (pPendingSignals[slot] & (UInt32(1) << UInt32(sig))) != 0
}

/// True if any signal is pending for process `slot`.
func processSignalHasPending(_ slot: Int) -> Bool {
    guard slot >= 0 && slot < maxProc else { return false }
    return pPendingSignals[slot] != 0
}

/// Drop all pending signals for `slot` (fork child / exec / fresh slot).
func processSignalClearAllPending(_ slot: Int) {
    guard slot >= 0 && slot < maxProc else { return }
    pPendingSignals[slot] = 0
}

private func setCurrentProcessSlot(_ slot: Int) {
    currentProcByCpu[processCurrentCpuIndex()] = slot
    smpSetCurrentProcessForCurrentCpu(Int32(slot))
}

private func processSecondaryRunMask() -> UInt64 {
    processAtomicLoad(&processSecondarySchedulerRunMask)
}

private func processSecondaryActiveMask() -> UInt64 {
    processAtomicLoad(&processSecondarySchedulerActiveMask)
}

private func processSecondaryStopMask() -> UInt64 {
    processAtomicLoad(&processSecondarySchedulerStopMask)
}

private func processCpuCanSchedule(_ cpu: UInt32) -> Bool {
    if cpu == 0 { return processValidSchedulerCpu(cpu) }
    if !processValidSchedulerCpu(cpu) { return false }
    return (processSecondaryRunMask() & processCpuBit(cpu)) != 0
}

private func processFirstSecondarySchedulerCpu() -> UInt32 {
    let primary = currentCpuId()
    var cpu: UInt32 = 0
    while cpu < processRunQueueCpuCount {
        if cpu != primary &&
           processValidSchedulerCpu(cpu) &&
           smpCpuOnline(cpu) &&
           smpPerCpuTimerTicks(cpu) != 0 {
            return cpu
        }
        cpu += 1
    }
    return unassignedCpu
}

private func processWaitForSecondaryActive(_ cpu: UInt32, active: Bool) -> Bool {
    let bit = processCpuBit(cpu)
    let start = read_cntpct_el0()
    var timeout = read_cntfrq_el0() * 2
    if timeout == 0 { timeout = 100_000_000 }
    while read_cntpct_el0() &- start < timeout {
        let isActive = (processSecondaryActiveMask() & bit) != 0
        if isActive == active { return true }
        if active {
            _ = gicSendSoftwareGeneratedInterruptToCpu(smpIpiInterruptId, cpu)
        }
        cpu_sev()
    }
    return false
}

private func processStartSecondaryScheduler(cpu: UInt32) {
    if cpu == 0 || !processValidSchedulerCpu(cpu) { return }
    let bit = processCpuBit(cpu)
    processAtomicStore(&processSecondarySchedulerStopMask, processSecondaryStopMask() & ~bit)
    processAtomicStore(&processSecondarySchedulerRunMask, processSecondaryRunMask() | bit)
    smpStoreBarrier()
    cpu_sev()
    if !processWaitForSecondaryActive(cpu, active: true) {
        uartPuts("panic: secondary EL0 scheduler did not start\n")
        while true {}
    }
}

private func processStopSecondaryScheduler(cpu: UInt32) {
    if cpu == 0 || !processValidSchedulerCpu(cpu) { return }
    let bit = processCpuBit(cpu)
    processAtomicStore(&processSecondarySchedulerStopMask, processSecondaryStopMask() | bit)
    smpStoreBarrier()
    cpu_sev()
    if !processWaitForSecondaryActive(cpu, active: false) {
        uartPuts("panic: secondary EL0 scheduler did not stop\n")
        while true {}
    }
    processAtomicStore(&processSecondarySchedulerRunMask, processSecondaryRunMask() & ~bit)
    processAtomicStore(&processSecondarySchedulerStopMask, processSecondaryStopMask() & ~bit)
}

func processSecondarySchedulerActiveForCurrentCpu() -> Bool {
    let cpu = currentCpuId()
    if cpu == 0 || !processValidSchedulerCpu(cpu) { return false }
    return (processSecondaryActiveMask() & processCpuBit(cpu)) != 0
}

func processSecondarySchedulerCanTickForCurrentCpu() -> Bool {
    let cpu = currentCpuId()
    if cpu == 0 || !processValidSchedulerCpu(cpu) { return false }
    let bit = processCpuBit(cpu)
    if (processSecondaryActiveMask() & bit) == 0 { return false }
    if (processSecondaryRunMask() & bit) == 0 { return false }
    if (processSecondaryStopMask() & bit) != 0 { return false }
    return true
}

func processSecondarySchedulerService() {
    let cpu = currentCpuId()
    if cpu == 0 || !processValidSchedulerCpu(cpu) { return }
    let bit = processCpuBit(cpu)
    if (processSecondaryRunMask() & bit) == 0 { return }

    processAtomicStore(&processSecondarySchedulerActiveMask, processSecondaryActiveMask() | bit)
    smpStoreBarrier()
    schedule(until: { (processSecondaryStopMask() & bit) != 0 })
    processAtomicStore(&processSecondarySchedulerActiveMask, processSecondaryActiveMask() & ~bit)
    smpStoreBarrier()
}

private func processSchedulerCpuIndex() -> Int {
    let cpu = currentCpuId()
    if cpu >= schedCtxCpuCount || !processCpuCanSchedule(cpu) {
        uartPuts("panic: EL0 process scheduler entered on inactive CPU\n")
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
    processSecondaryRunMask() != 0
}

private func processSecondaryEl0GateAllowsCpu(_ cpu: UInt32) -> Bool {
    processCpuCanSchedule(cpu)
}

private func processMirrorRunQueueForCpu(_ cpu: UInt32) {
    let idx = Int(cpu)
    _ = smpSetProcessRunQueueForCpu(cpu, head: processRunQueueHead[idx],
                                    tail: processRunQueueTail[idx])
}

private func processHomeCpuForNewReadySlot(_ slot: Int) -> UInt32 {
    if slot < 0 || slot >= maxProc { return unassignedCpu }
    if s5fRunAnyPlacementActive {
        return processNextS5fRunAnyHomeCpu()
    }
    // Default placement remains CPU0. The restricted S2h coproc path passes an
    // explicit home CPU while its secondary scheduler run mask is open; S5f is
    // the first gated path that exercises the default placement policy itself.
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

private func removeProcessFromRunQueue(_ slot: Int) {
    if slot < 0 || slot >= maxProc || !pRunQueued[slot] { return }
    let cpu = pHomeCpu[slot]
    if !processValidSchedulerCpu(cpu) {
        uartPuts("panic: invalid EL0 process run queue removal CPU\n")
        while true {}
    }

    let idx = Int(cpu)
    let daif = processRunQueueLock(cpu)
    var prev = noProcessSlot
    var cur = processRunQueueHead[idx]
    while cur != noProcessSlot {
        if cur == Int32(slot) {
            let next = pRunNext[slot]
            if prev == noProcessSlot {
                processRunQueueHead[idx] = next
            } else {
                pRunNext[Int(prev)] = next
            }
            if processRunQueueTail[idx] == Int32(slot) {
                processRunQueueTail[idx] = prev
            }
            pRunNext[slot] = noProcessSlot
            pRunQueued[slot] = false
            processMirrorRunQueueForCpu(cpu)
            processRunQueueUnlock(cpu, daif)
            return
        }
        prev = cur
        cur = pRunNext[Int(cur)]
    }
    processRunQueueUnlock(cpu, daif)
    uartPuts("panic: queued EL0 process missing from run queue\n")
    while true {}
}

private func recordProcessDispatch(_ slot: Int, on cpu: UInt32) {
    if slot < 0 || slot >= maxProc || !processValidSchedulerCpu(cpu) {
        uartPuts("panic: invalid EL0 process dispatch telemetry target\n")
        while true {}
    }
    if !processCpuCanSchedule(cpu) {
        uartPuts("panic: EL0 process dispatched on inactive CPU\n")
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
    if !processCpuCanSchedule(cpu) {
        uartPuts("panic: address space activated on inactive CPU\n")
        while true {}
    }
    if pHomeCpu[slot] != cpu || pLastDispatchCpu[slot] != cpu {
        uartPuts("panic: address-space CPU mask dispatch mismatch\n")
        while true {}
    }
    pAddressSpaceCpuMask[slot] |= UInt64(1) << Int(cpu)
    processAddressSpaceActivationCount[Int(cpu)] &+= 1
}

private func processAddressSpaceActiveCpuMaskForSlot(_ slot: Int) -> UInt64 {
    let currentMask = addressSpaceCurrentCpuTlbMask()
    if slot < 0 || slot >= maxProc { return currentMask }

    var mask = pAddressSpaceCpuMask[slot]
    if slot == currentProcessSlot() {
        mask |= currentMask
    }
    return mask == 0 ? currentMask : mask
}

func processCurrentAddressSpaceActiveCpuMask() -> UInt64 {
    let current = currentProcessSlot()
    if current < 0 { return addressSpaceCurrentCpuTlbMask() }
    return processAddressSpaceActiveCpuMaskForSlot(current)
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

private func captureLastS5bBatchDispatchTelemetry(_ a: Int, _ b: Int, _ c: Int) {
    if a < 0 || a >= maxProc || b < 0 || b >= maxProc || c < 0 || c >= maxProc {
        lastS5bBatchDispatchTelemetryValid = false
        return
    }
    lastS5bBatchDispatchCountA = pDispatchCount[a]
    lastS5bBatchDispatchCountB = pDispatchCount[b]
    lastS5bBatchDispatchCountC = pDispatchCount[c]
    lastS5bBatchDispatchCpuMaskA = pDispatchCpuMask[a]
    lastS5bBatchDispatchCpuMaskB = pDispatchCpuMask[b]
    lastS5bBatchDispatchCpuMaskC = pDispatchCpuMask[c]
    lastS5bBatchLastDispatchCpuA = pLastDispatchCpu[a]
    lastS5bBatchLastDispatchCpuB = pLastDispatchCpu[b]
    lastS5bBatchLastDispatchCpuC = pLastDispatchCpu[c]
    lastS5bBatchDispatchTelemetryValid = true
}

private func captureLastS5cPlacementStressTelemetry(rounds: UInt64, processCount: UInt64,
                                                    primaryDispatchCount: UInt64,
                                                    secondaryDispatchCount: UInt64,
                                                    primaryCpuMask: UInt64,
                                                    secondaryCpuMask: UInt64,
                                                    secondaryCpu: UInt32) {
    lastS5cStressRounds = rounds
    lastS5cStressProcessCount = processCount
    lastS5cStressPrimaryDispatchCount = primaryDispatchCount
    lastS5cStressSecondaryDispatchCount = secondaryDispatchCount
    lastS5cStressPrimaryCpuMask = primaryCpuMask
    lastS5cStressSecondaryCpuMask = secondaryCpuMask
    lastS5cStressSecondaryCpu = secondaryCpu
    lastS5cStressRunQueueLockAcquireCount = processRunQueueLockAcquireTotal()
    lastS5cStressRunQueueLockContentionCount = processRunQueueLockContentionTotal()
    lastS5cStressTelemetryValid = true
}

private func captureLastS5dFanoutTelemetry(processCount: UInt64,
                                           schedulerCpuMask: UInt64,
                                           dispatchCpuMask: UInt64,
                                           secondaryCpuMask: UInt64,
                                           dispatchCount: UInt64,
                                           exactCpuMatchCount: UInt64) {
    lastS5dFanoutProcessCount = processCount
    lastS5dFanoutSchedulerCpuMask = schedulerCpuMask
    lastS5dFanoutDispatchCpuMask = dispatchCpuMask
    lastS5dFanoutSecondaryCpuMask = secondaryCpuMask
    lastS5dFanoutDispatchCount = dispatchCount
    lastS5dFanoutExactCpuMatchCount = exactCpuMatchCount
    lastS5dFanoutTelemetryValid = true
}

private func resetLastS5eThreadFanoutTelemetry() {
    lastS5eThreadFanoutTelemetryValid = false
    lastS5eThreadCreateCount = 0
    lastS5eThreadExitCount = 0
    lastS5eThreadSharedAddressSpaceCount = 0
    lastS5eThreadHomeCpuMask = 0
    lastS5eThreadDispatchCpuMask = 0
    lastS5eThreadSecondaryCpuMask = 0
    lastS5eThreadDispatchCount = 0
    lastS5eThreadExactCpuMatchCount = 0
    lastS5eThreadFutexLockAcquireCount = 0
    lastS5eThreadFutexLockContentionCount = 0
    lastS5eThreadTelemetryLockAcquireCount = 0
    lastS5eThreadTelemetryLockContentionCount = 0
    s5eThreadPlacementActive = false
    s5eNextThreadCpu = 1
}

private func processNextS5eThreadHomeCpu() -> UInt32 {
    let primary = currentCpuId()
    let runMask = processSecondaryRunMask()
    if runMask == 0 { return primary }

    var start = s5eNextThreadCpu
    if start == 0 || start >= processRunQueueCpuCount { start = 1 }
    var offset: UInt32 = 0
    while offset < processRunQueueCpuCount {
        var cpu = start + offset
        if cpu >= processRunQueueCpuCount { cpu = 1 + (cpu - processRunQueueCpuCount) }
        if cpu != primary &&
           processValidSchedulerCpu(cpu) &&
           (runMask & processCpuBit(cpu)) != 0 &&
           smpCpuOnline(cpu) &&
           smpPerCpuTimerTicks(cpu) != 0 {
            s5eNextThreadCpu = cpu + 1
            if s5eNextThreadCpu >= processRunQueueCpuCount { s5eNextThreadCpu = 1 }
            return cpu
        }
        offset += 1
    }
    return primary
}

private func recordS5eThreadCreate(creator: Int, slot: Int, homeCpu: UInt32) {
    if !s5eThreadPlacementActive { return }
    let daif = processS5eThreadTelemetryLock()
    lastS5eThreadCreateCount &+= 1
    if creator >= 0 && creator < maxProc &&
       slot >= 0 && slot < maxProc &&
       pTtbr0[slot] == pTtbr0[creator] {
        lastS5eThreadSharedAddressSpaceCount &+= 1
    }
    lastS5eThreadHomeCpuMask |= processCpuBit(homeCpu)
    if homeCpu != 0 && homeCpu != unassignedCpu {
        lastS5eThreadSecondaryCpuMask |= processCpuBit(homeCpu)
    }
    processS5eThreadTelemetryUnlock(daif)
}

private func recordS5eThreadExit(_ slot: Int) {
    if !s5eThreadPlacementActive || slot < 0 || slot >= maxProc { return }
    let daif = processS5eThreadTelemetryLock()
    let home = pHomeCpu[slot]
    let homeMask = processCpuBit(home)
    lastS5eThreadExitCount &+= 1
    lastS5eThreadDispatchCpuMask |= pDispatchCpuMask[slot]
    lastS5eThreadDispatchCount &+= pDispatchCount[slot]
    if home != 0 && home != unassignedCpu {
        lastS5eThreadSecondaryCpuMask |= homeMask
    }
    if pDispatchCpuMask[slot] == homeMask && pDispatchCount[slot] != 0 {
        lastS5eThreadExactCpuMatchCount &+= 1
    }
    processS5eThreadTelemetryUnlock(daif)
}

private func captureLastS5eThreadFanoutTelemetry() {
    let daif = processS5eThreadTelemetryLock()
    lastS5eThreadFutexLockAcquireCount = futexS5eLockAcquireCount()
    lastS5eThreadFutexLockContentionCount = futexS5eLockContentionCount()
    lastS5eThreadTelemetryLockAcquireCount = processS5eThreadTelemetryLockAcquireCount()
    lastS5eThreadTelemetryLockContentionCount = processS5eThreadTelemetryLockContentionCount()
    lastS5eThreadFanoutTelemetryValid = true
    processS5eThreadTelemetryUnlock(daif)
}

private func s5eThreadFanoutWorkersExited() -> Bool {
    let daif = processS5eThreadTelemetryLock()
    let created = lastS5eThreadCreateCount
    let exited = lastS5eThreadExitCount
    processS5eThreadTelemetryUnlock(daif)
    return created >= 2 && exited >= created
}

private func resetLastS5fRunAnyTelemetry() {
    lastS5fRunAnyTelemetryValid = false
    lastS5fRunAnyProcessCount = 0
    lastS5fRunAnySchedulerCpuMask = 0
    lastS5fRunAnyDispatchCpuMask = 0
    lastS5fRunAnySecondaryCpuMask = 0
    lastS5fRunAnyDispatchCount = 0
    lastS5fRunAnyExactCpuMatchCount = 0
    lastS5fRunAnyPolicySelectionCount = 0
    s5fRunAnyPlacementActive = false
    s5fNextPlacementCpu = 0
    for slot in 0..<maxProc {
        s5fRunAnySlots[slot] = -1
    }
}

private func processNextS5fRunAnyHomeCpu() -> UInt32 {
    let primary = currentCpuId()
    var schedulerMask = processCpuBit(primary) | processSecondaryRunMask()
    if schedulerMask == 0 { schedulerMask = processCpuBit(primary) }

    var start = s5fNextPlacementCpu
    if start >= processRunQueueCpuCount { start = 0 }
    var offset: UInt32 = 0
    while offset < processRunQueueCpuCount {
        var cpu = start + offset
        if cpu >= processRunQueueCpuCount { cpu -= processRunQueueCpuCount }
        let bit = processCpuBit(cpu)
        if (schedulerMask & bit) != 0 &&
           processValidSchedulerCpu(cpu) &&
           cpu < platform.cpuCount &&
           (cpu == primary || (smpCpuOnline(cpu) && smpPerCpuTimerTicks(cpu) != 0)) {
            s5fNextPlacementCpu = cpu + 1
            if s5fNextPlacementCpu >= processRunQueueCpuCount { s5fNextPlacementCpu = 0 }
            lastS5fRunAnyPolicySelectionCount &+= 1
            return cpu
        }
        offset += 1
    }

    lastS5fRunAnyPolicySelectionCount &+= 1
    return primary
}

private func captureLastS5fRunAnyTelemetry(processCount: UInt64,
                                           schedulerCpuMask: UInt64,
                                           dispatchCpuMask: UInt64,
                                           secondaryCpuMask: UInt64,
                                           dispatchCount: UInt64,
                                           exactCpuMatchCount: UInt64) {
    lastS5fRunAnyProcessCount = processCount
    lastS5fRunAnySchedulerCpuMask = schedulerCpuMask
    lastS5fRunAnyDispatchCpuMask = dispatchCpuMask
    lastS5fRunAnySecondaryCpuMask = secondaryCpuMask
    lastS5fRunAnyDispatchCount = dispatchCount
    lastS5fRunAnyExactCpuMatchCount = exactCpuMatchCount
    lastS5fRunAnyTelemetryValid = true
}

private func markProcessReady(_ slot: Int, cpu: UInt32) {
    if slot < 0 || slot >= maxProc || !processValidSchedulerCpu(cpu) {
        uartPuts("panic: invalid EL0 process run queue target\n")
        while true {}
    }
    if !processCpuCanSchedule(cpu) {
        uartPuts("panic: EL0 process scheduled on inactive CPU\n")
        while true {}
    }
    pState[slot] = pReady
    pHomeCpu[slot] = cpu

    let idx = Int(cpu)
    let daif = processRunQueueLock(cpu)
    if pRunQueued[slot] {
        processRunQueueUnlock(cpu, daif)
        return
    }

    let tail = processRunQueueTail[idx]
    pRunNext[slot] = noProcessSlot
    if tail == noProcessSlot {
        processRunQueueHead[idx] = Int32(slot)
    } else if tail >= 0 && tail < Int32(maxProc) {
        pRunNext[Int(tail)] = Int32(slot)
    } else {
        processRunQueueUnlock(cpu, daif)
        uartPuts("panic: EL0 process run queue tail corrupted\n")
        while true {}
    }
    processRunQueueTail[idx] = Int32(slot)
    pRunQueued[slot] = true
    processRunQueueEnqueueCount[idx] &+= 1
    processMirrorRunQueueForCpu(cpu)
    processRunQueueUnlock(cpu, daif)

    if cpu != currentCpuId() {
        cpu_sev()
    }
}

private func markProcessReadyOnHomeCpu(_ slot: Int) {
    if slot < 0 || slot >= maxProc { return }
    let home = pHomeCpu[slot] == unassignedCpu ? processHomeCpuForNewReadySlot(slot) : pHomeCpu[slot]
    markProcessReady(slot, cpu: home)
}

private func pickReady() -> Int {
    let cpu = UInt32(processSchedulerCpuIndex())
    if !processValidSchedulerCpu(cpu) { return -1 }
    let idx = Int(cpu)
    let daif = processRunQueueLock(cpu)
    let head = processRunQueueHead[idx]
    if head == noProcessSlot {
        processRunQueueUnlock(cpu, daif)
        return -1
    }

    let slot = Int(head)
    processRunQueueHead[idx] = pRunNext[slot]
    if processRunQueueHead[idx] == noProcessSlot {
        processRunQueueTail[idx] = noProcessSlot
    }
    pRunNext[slot] = noProcessSlot
    pRunQueued[slot] = false
    processRunQueueDispatchCount[idx] &+= 1
    processMirrorRunQueueForCpu(cpu)

    let corrupted = pState[slot] != pReady || pHomeCpu[slot] != cpu
    processRunQueueUnlock(cpu, daif)

    if corrupted {
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
    if lastS5bBatchDispatchTelemetryValid { return false }
    if lastS5bBatchDispatchCountA != 0 ||
       lastS5bBatchDispatchCountB != 0 ||
       lastS5bBatchDispatchCountC != 0 {
        return false
    }
    if lastS5bBatchDispatchCpuMaskA != 0 ||
       lastS5bBatchDispatchCpuMaskB != 0 ||
       lastS5bBatchDispatchCpuMaskC != 0 {
        return false
    }
    if lastS5bBatchLastDispatchCpuA != unassignedCpu ||
       lastS5bBatchLastDispatchCpuB != unassignedCpu ||
       lastS5bBatchLastDispatchCpuC != unassignedCpu {
        return false
    }
    if lastS5cStressTelemetryValid { return false }
    if lastS5cStressRounds != 0 || lastS5cStressProcessCount != 0 {
        return false
    }
    if lastS5cStressPrimaryDispatchCount != 0 ||
       lastS5cStressSecondaryDispatchCount != 0 {
        return false
    }
    if lastS5cStressPrimaryCpuMask != 0 ||
       lastS5cStressSecondaryCpuMask != 0 {
        return false
    }
    if lastS5cStressSecondaryCpu != unassignedCpu {
        return false
    }
    if lastS5dFanoutTelemetryValid { return false }
    if lastS5dFanoutProcessCount != 0 ||
       lastS5dFanoutSchedulerCpuMask != 0 ||
       lastS5dFanoutDispatchCpuMask != 0 ||
       lastS5dFanoutSecondaryCpuMask != 0 ||
       lastS5dFanoutDispatchCount != 0 ||
       lastS5dFanoutExactCpuMatchCount != 0 {
        return false
    }
    for slot in 0..<processSchedulerCpuSlots {
        if s5dFanoutSlots[slot] != -1 { return false }
    }
    if lastS5eThreadFanoutTelemetryValid { return false }
    if lastS5eThreadCreateCount != 0 ||
       lastS5eThreadExitCount != 0 ||
       lastS5eThreadSharedAddressSpaceCount != 0 ||
       lastS5eThreadHomeCpuMask != 0 ||
       lastS5eThreadDispatchCpuMask != 0 ||
       lastS5eThreadSecondaryCpuMask != 0 ||
       lastS5eThreadDispatchCount != 0 ||
       lastS5eThreadExactCpuMatchCount != 0 ||
       lastS5eThreadFutexLockAcquireCount != 0 ||
       lastS5eThreadFutexLockContentionCount != 0 ||
       lastS5eThreadTelemetryLockAcquireCount != 0 ||
       lastS5eThreadTelemetryLockContentionCount != 0 {
        return false
    }
    if s5eThreadPlacementActive || s5eNextThreadCpu != 1 {
        return false
    }
    if s5eThreadTelemetryLockWord != 0 ||
       s5eThreadTelemetryLockAcquireCount != 0 ||
       s5eThreadTelemetryLockContentionCount != 0 {
        return false
    }
    if lastS5fRunAnyTelemetryValid { return false }
    if lastS5fRunAnyProcessCount != 0 ||
       lastS5fRunAnySchedulerCpuMask != 0 ||
       lastS5fRunAnyDispatchCpuMask != 0 ||
       lastS5fRunAnySecondaryCpuMask != 0 ||
       lastS5fRunAnyDispatchCount != 0 ||
       lastS5fRunAnyExactCpuMatchCount != 0 ||
       lastS5fRunAnyPolicySelectionCount != 0 {
        return false
    }
    if s5fRunAnyPlacementActive || s5fNextPlacementCpu != 0 {
        return false
    }
    for slot in 0..<maxProc {
        if s5fRunAnySlots[slot] != -1 { return false }
    }
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
    if processSecondaryRunMask() != 0 { return false }
    if processSecondaryActiveMask() != 0 { return false }
    if processSecondaryStopMask() != 0 { return false }

    var cpu: UInt32 = 0
    while cpu < processRunQueueCpuCount {
        let idx = Int(cpu)
        if processRunQueueHead[idx] != noProcessSlot { return false }
        if processRunQueueTail[idx] != noProcessSlot { return false }
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

func processAddressSpaceCpuMaskPostRunSelfTest() -> Bool {
    let primary = currentCpuId()
    if primary != 0 || !processValidSchedulerCpu(primary) { return false }

    var sawPrimaryActivation = false
    var sawSecondaryActivation = false
    var cpu: UInt32 = 0
    while cpu < processRunQueueCpuCount {
        let idx = Int(cpu)
        if processAddressSpaceActivationCount[idx] != processDispatchTelemetryCount[idx] {
            return false
        }
        if cpu >= platform.cpuCount && processAddressSpaceActivationCount[idx] != 0 {
            return false
        }
        if cpu == primary {
            sawPrimaryActivation = processAddressSpaceActivationCount[idx] != 0
        } else if processAddressSpaceActivationCount[idx] != 0 {
            sawSecondaryActivation = true
            if smpPerCpuEl0SwitchCount(cpu) == 0 { return false }
        }
        cpu += 1
    }
    if !sawPrimaryActivation { return false }
    if platform.cpuCount > 1 && !sawSecondaryActivation { return false }

    for slot in 0..<maxProc {
        if pState[slot] == pUnused {
            if pAddressSpaceCpuMask[slot] != 0 { return false }
        } else if (pAddressSpaceCpuMask[slot] & ~pDispatchCpuMask[slot]) != 0 {
            return false
        }
    }
    return true
}

func processCoprocPairDispatchTelemetrySelfTest() -> Bool {
    let primary = currentCpuId()
    if primary != 0 || !processValidSchedulerCpu(primary) { return false }
    if !lastPairDispatchTelemetryValid { return false }
    if lastPairDispatchCountA == 0 || lastPairDispatchCountB == 0 { return false }
    let primaryMask = UInt64(1) << Int(primary)
    let secondary = processFirstSecondarySchedulerCpu()
    if secondary == unassignedCpu {
        if lastPairLastDispatchCpuA != primary { return false }
        if lastPairLastDispatchCpuB != primary { return false }
        if lastPairDispatchCpuMaskA != primaryMask { return false }
        if lastPairDispatchCpuMaskB != primaryMask { return false }
    } else {
        let secondaryMask = UInt64(1) << Int(secondary)
        let combined = lastPairDispatchCpuMaskA | lastPairDispatchCpuMaskB
        if (combined & primaryMask) == 0 { return false }
        if (combined & secondaryMask) == 0 { return false }
        if lastPairDispatchCpuMaskA == lastPairDispatchCpuMaskB { return false }
        if lastPairLastDispatchCpuA != primary && lastPairLastDispatchCpuA != secondary {
            return false
        }
        if lastPairLastDispatchCpuB != primary && lastPairLastDispatchCpuB != secondary {
            return false
        }
        if processDispatchTelemetryCount[Int(secondary)] == 0 { return false }
        if smpPerCpuEl0SwitchCount(secondary) == 0 { return false }
        if (processSecondaryRunMask() & secondaryMask) != 0 { return false }
        if (processSecondaryActiveMask() & secondaryMask) != 0 { return false }
    }
    var cpu: UInt32 = 0
    while cpu < processRunQueueCpuCount {
        if platform.cpuCount == 1 || cpu >= platform.cpuCount {
            if cpu != primary {
                if processDispatchTelemetryCount[Int(cpu)] != 0 { return false }
                if smpPerCpuEl0SwitchCount(cpu) != 0 { return false }
            }
        }
        cpu += 1
    }
    return true
}

private func processS5bPlacementTelemetryFail(_ code: UInt64) -> Bool {
    uartPuts("S5b placement telemetry fail ")
    uartPutUInt(code)
    uartPuts("\n")
    return false
}

func processS5bPlacementTelemetrySelfTest() -> Bool {
    let primary = currentCpuId()
    if primary != 0 || !processValidSchedulerCpu(primary) {
        return processS5bPlacementTelemetryFail(1)
    }
    if !lastS5bBatchDispatchTelemetryValid {
        return processS5bPlacementTelemetryFail(2)
    }
    if lastS5bBatchDispatchCountA == 0 ||
       lastS5bBatchDispatchCountB == 0 ||
       lastS5bBatchDispatchCountC == 0 {
        return processS5bPlacementTelemetryFail(3)
    }

    let primaryMask = processCpuBit(primary)
    let secondary = processFirstSecondarySchedulerCpu()
    if secondary == unassignedCpu {
        if lastS5bBatchLastDispatchCpuA != primary ||
           lastS5bBatchLastDispatchCpuB != primary ||
           lastS5bBatchLastDispatchCpuC != primary {
            return processS5bPlacementTelemetryFail(4)
        }
        if lastS5bBatchDispatchCpuMaskA != primaryMask ||
           lastS5bBatchDispatchCpuMaskB != primaryMask ||
           lastS5bBatchDispatchCpuMaskC != primaryMask {
            return processS5bPlacementTelemetryFail(5)
        }
    } else {
        let secondaryMask = lastS5bBatchDispatchCpuMaskB
        if secondaryMask == 0 || (secondaryMask & primaryMask) != 0 {
            return processS5bPlacementTelemetryFail(6)
        }
        var batchSecondary = unassignedCpu
        var cpu: UInt32 = 0
        while cpu < processRunQueueCpuCount {
            if secondaryMask == processCpuBit(cpu) {
                batchSecondary = cpu
                break
            }
            cpu += 1
        }
        if batchSecondary == unassignedCpu ||
           !processValidSchedulerCpu(batchSecondary) ||
           !smpCpuOnline(batchSecondary) {
            return processS5bPlacementTelemetryFail(7)
        }
        if lastS5bBatchLastDispatchCpuA != primary {
            return processS5bPlacementTelemetryFail(8)
        }
        if lastS5bBatchDispatchCpuMaskA != primaryMask {
            return processS5bPlacementTelemetryFail(9)
        }
        if lastS5bBatchDispatchCpuMaskB != secondaryMask {
            return processS5bPlacementTelemetryFail(10)
        }
        if lastS5bBatchDispatchCpuMaskC != primaryMask {
            return processS5bPlacementTelemetryFail(11)
        }
        if processRunQueueEnqueueCount[Int(batchSecondary)] == 0 {
            return processS5bPlacementTelemetryFail(12)
        }
        if processRunQueueDispatchCount[Int(batchSecondary)] == 0 {
            return processS5bPlacementTelemetryFail(13)
        }
        if processDispatchTelemetryCount[Int(batchSecondary)] <
           lastS5bBatchDispatchCountB {
            return processS5bPlacementTelemetryFail(14)
        }
        if smpPerCpuEl0SwitchCount(batchSecondary) == 0 {
            return processS5bPlacementTelemetryFail(15)
        }
        if (processSecondaryRunMask() & secondaryMask) != 0 {
            return processS5bPlacementTelemetryFail(16)
        }
        if (processSecondaryActiveMask() & secondaryMask) != 0 {
            return processS5bPlacementTelemetryFail(17)
        }
    }

    var cpu: UInt32 = 0
    while cpu < processRunQueueCpuCount {
        let idx = Int(cpu)
        if processRunQueueHead[idx] != noProcessSlot {
            return processS5bPlacementTelemetryFail(18)
        }
        if processRunQueueTail[idx] != noProcessSlot {
            return processS5bPlacementTelemetryFail(19)
        }
        if !smpPerCpuProcessRunQueueIdle(cpu) {
            return processS5bPlacementTelemetryFail(20)
        }
        if cpu >= platform.cpuCount && processDispatchTelemetryCount[idx] != 0 {
            return processS5bPlacementTelemetryFail(21)
        }
        cpu += 1
    }
    return true
}

private func processS5cPlacementStressFail(_ code: UInt64) -> Bool {
    uartPuts("S5c placement stress fail ")
    uartPutUInt(code)
    uartPuts("\n")
    return false
}

func processS5cPlacementStressSelfTest() -> Bool {
    let primary = currentCpuId()
    if primary != 0 || !processValidSchedulerCpu(primary) {
        return processS5cPlacementStressFail(1)
    }
    if !lastS5cStressTelemetryValid {
        return processS5cPlacementStressFail(2)
    }
    if lastS5cStressRounds != s5cPlacementStressRounds {
        return processS5cPlacementStressFail(3)
    }
    let expectedProcessCount =
        (s5cPlacementStressRounds * 2) + s5cPlacementStressCpu0TailCount
    if lastS5cStressProcessCount != expectedProcessCount {
        return processS5cPlacementStressFail(4)
    }
    if lastS5cStressPrimaryDispatchCount == 0 ||
       lastS5cStressSecondaryDispatchCount == 0 {
        return processS5cPlacementStressFail(5)
    }

    let primaryMask = processCpuBit(primary)
    if lastS5cStressPrimaryCpuMask != primaryMask {
        return processS5cPlacementStressFail(6)
    }

    let secondary = processFirstSecondarySchedulerCpu()
    if secondary == unassignedCpu {
        if lastS5cStressSecondaryCpu != primary {
            return processS5cPlacementStressFail(7)
        }
        if lastS5cStressSecondaryCpuMask != primaryMask {
            return processS5cPlacementStressFail(8)
        }
    } else {
        if lastS5cStressSecondaryCpu == primary ||
           lastS5cStressSecondaryCpu == unassignedCpu {
            return processS5cPlacementStressFail(9)
        }
        if !processValidSchedulerCpu(lastS5cStressSecondaryCpu) ||
           !smpCpuOnline(lastS5cStressSecondaryCpu) {
            return processS5cPlacementStressFail(10)
        }
        let secondaryMask = processCpuBit(lastS5cStressSecondaryCpu)
        if lastS5cStressSecondaryCpuMask != secondaryMask {
            return processS5cPlacementStressFail(11)
        }
        let secondaryIdx = Int(lastS5cStressSecondaryCpu)
        if processRunQueueEnqueueCount[secondaryIdx] < s5cPlacementStressRounds {
            return processS5cPlacementStressFail(12)
        }
        if processRunQueueDispatchCount[secondaryIdx] <
           lastS5cStressSecondaryDispatchCount {
            return processS5cPlacementStressFail(13)
        }
        if processDispatchTelemetryCount[secondaryIdx] <
           lastS5cStressSecondaryDispatchCount {
            return processS5cPlacementStressFail(14)
        }
        if smpPerCpuEl0SwitchCount(lastS5cStressSecondaryCpu) == 0 {
            return processS5cPlacementStressFail(15)
        }
        if (processSecondaryRunMask() & secondaryMask) != 0 {
            return processS5cPlacementStressFail(16)
        }
        if (processSecondaryActiveMask() & secondaryMask) != 0 {
            return processS5cPlacementStressFail(17)
        }
    }

    if lastS5cStressRunQueueLockAcquireCount == 0 {
        return processS5cPlacementStressFail(18)
    }

    var cpu: UInt32 = 0
    while cpu < processRunQueueCpuCount {
        let idx = Int(cpu)
        if processRunQueueLockWord[idx] != 0 {
            return processS5cPlacementStressFail(19)
        }
        if processRunQueueHead[idx] != noProcessSlot {
            return processS5cPlacementStressFail(20)
        }
        if processRunQueueTail[idx] != noProcessSlot {
            return processS5cPlacementStressFail(21)
        }
        if !smpPerCpuProcessRunQueueIdle(cpu) {
            return processS5cPlacementStressFail(22)
        }
        if cpu >= platform.cpuCount && processDispatchTelemetryCount[idx] != 0 {
            return processS5cPlacementStressFail(23)
        }
        cpu += 1
    }
    return true
}

private func processS5dFanoutFail(_ code: UInt64) -> Bool {
    uartPuts("S5d fanout fail ")
    uartPutUInt(code)
    uartPuts("\n")
    return false
}

func processS5dFanoutSelfTest() -> Bool {
    let primary = currentCpuId()
    if primary != 0 || !processValidSchedulerCpu(primary) {
        return processS5dFanoutFail(1)
    }
    if !lastS5dFanoutTelemetryValid {
        return processS5dFanoutFail(2)
    }
    let primaryMask = processCpuBit(primary)
    if (lastS5dFanoutSchedulerCpuMask & primaryMask) == 0 {
        return processS5dFanoutFail(3)
    }
    if lastS5dFanoutDispatchCpuMask != lastS5dFanoutSchedulerCpuMask {
        return processS5dFanoutFail(4)
    }
    if lastS5dFanoutExactCpuMatchCount != lastS5dFanoutProcessCount {
        return processS5dFanoutFail(5)
    }
    if lastS5dFanoutDispatchCount < lastS5dFanoutProcessCount {
        return processS5dFanoutFail(6)
    }
    if platform.cpuCount > 1 {
        if lastS5dFanoutSecondaryCpuMask == 0 {
            return processS5dFanoutFail(7)
        }
        if (lastS5dFanoutSecondaryCpuMask & primaryMask) != 0 {
            return processS5dFanoutFail(8)
        }
    } else if lastS5dFanoutSecondaryCpuMask != 0 {
        return processS5dFanoutFail(9)
    }

    var expectedCount: UInt64 = 0
    var cpu: UInt32 = 0
    while cpu < processRunQueueCpuCount {
        let bit = processCpuBit(cpu)
        if (lastS5dFanoutSchedulerCpuMask & bit) != 0 {
            expectedCount &+= 1
            if cpu >= platform.cpuCount || !processValidSchedulerCpu(cpu) {
                return processS5dFanoutFail(10)
            }
            if cpu != primary && !smpCpuOnline(cpu) {
                return processS5dFanoutFail(11)
            }
            if processDispatchTelemetryCount[Int(cpu)] == 0 {
                return processS5dFanoutFail(12)
            }
            if smpPerCpuEl0SwitchCount(cpu) == 0 {
                return processS5dFanoutFail(13)
            }
        }
        cpu += 1
    }
    if expectedCount != lastS5dFanoutProcessCount {
        return processS5dFanoutFail(14)
    }

    if (processSecondaryRunMask() & lastS5dFanoutSecondaryCpuMask) != 0 {
        return processS5dFanoutFail(15)
    }
    if (processSecondaryActiveMask() & lastS5dFanoutSecondaryCpuMask) != 0 {
        return processS5dFanoutFail(16)
    }
    if (processSecondaryStopMask() & lastS5dFanoutSecondaryCpuMask) != 0 {
        return processS5dFanoutFail(17)
    }

    cpu = 0
    while cpu < processRunQueueCpuCount {
        let idx = Int(cpu)
        if processRunQueueLockWord[idx] != 0 {
            return processS5dFanoutFail(18)
        }
        if processRunQueueHead[idx] != noProcessSlot {
            return processS5dFanoutFail(19)
        }
        if processRunQueueTail[idx] != noProcessSlot {
            return processS5dFanoutFail(20)
        }
        if !smpPerCpuProcessRunQueueIdle(cpu) {
            return processS5dFanoutFail(21)
        }
        if cpu >= platform.cpuCount && processDispatchTelemetryCount[idx] != 0 {
            return processS5dFanoutFail(22)
        }
        cpu += 1
    }
    return true
}

private func processS5eThreadFanoutFail(_ code: UInt64) -> Bool {
    uartPuts("S5e thread fanout fail ")
    uartPutUInt(code)
    uartPuts("\n")
    return false
}

func processS5eThreadFanoutSelfTest() -> Bool {
    let primary = currentCpuId()
    if primary != 0 || !processValidSchedulerCpu(primary) {
        return processS5eThreadFanoutFail(1)
    }
    if !lastS5eThreadFanoutTelemetryValid {
        return processS5eThreadFanoutFail(2)
    }
    if s5eThreadPlacementActive {
        return processS5eThreadFanoutFail(3)
    }
    if lastS5eThreadCreateCount != 2 ||
       lastS5eThreadExitCount != 2 ||
       lastS5eThreadSharedAddressSpaceCount != 2 {
        return processS5eThreadFanoutFail(4)
    }
    if lastS5eThreadDispatchCount < lastS5eThreadExitCount {
        return processS5eThreadFanoutFail(5)
    }
    if lastS5eThreadDispatchCpuMask == 0 ||
       lastS5eThreadHomeCpuMask == 0 ||
       lastS5eThreadDispatchCpuMask != lastS5eThreadHomeCpuMask {
        return processS5eThreadFanoutFail(6)
    }
    if lastS5eThreadExactCpuMatchCount != lastS5eThreadExitCount {
        return processS5eThreadFanoutFail(7)
    }
    if lastS5eThreadFutexLockAcquireCount == 0 ||
       !futexS5eLockBoundaryHeldSelfTest() ||
       !futexS5eWaitTableIdleSelfTest() {
        return processS5eThreadFanoutFail(8)
    }
    if lastS5eThreadTelemetryLockAcquireCount == 0 ||
       s5eThreadTelemetryLockWord != 0 {
        return processS5eThreadFanoutFail(9)
    }

    let primaryMask = processCpuBit(primary)
    if platform.cpuCount > 1 {
        if lastS5eThreadSecondaryCpuMask == 0 {
            return processS5eThreadFanoutFail(10)
        }
        if (lastS5eThreadSecondaryCpuMask & primaryMask) != 0 {
            return processS5eThreadFanoutFail(11)
        }
        if (lastS5eThreadDispatchCpuMask & lastS5eThreadSecondaryCpuMask) !=
           lastS5eThreadSecondaryCpuMask {
            return processS5eThreadFanoutFail(12)
        }
    } else if lastS5eThreadSecondaryCpuMask != 0 ||
              lastS5eThreadDispatchCpuMask != primaryMask {
        return processS5eThreadFanoutFail(13)
    }

    if (processSecondaryRunMask() & lastS5eThreadSecondaryCpuMask) != 0 {
        return processS5eThreadFanoutFail(14)
    }
    if (processSecondaryActiveMask() & lastS5eThreadSecondaryCpuMask) != 0 {
        return processS5eThreadFanoutFail(15)
    }
    if (processSecondaryStopMask() & lastS5eThreadSecondaryCpuMask) != 0 {
        return processS5eThreadFanoutFail(16)
    }

    var cpu: UInt32 = 0
    while cpu < processRunQueueCpuCount {
        let idx = Int(cpu)
        let bit = processCpuBit(cpu)
        if processRunQueueLockWord[idx] != 0 {
            return processS5eThreadFanoutFail(17)
        }
        if processRunQueueHead[idx] != noProcessSlot ||
           processRunQueueTail[idx] != noProcessSlot ||
           !smpPerCpuProcessRunQueueIdle(cpu) {
            return processS5eThreadFanoutFail(18)
        }
        if (lastS5eThreadDispatchCpuMask & bit) != 0 {
            if cpu >= platform.cpuCount || !processValidSchedulerCpu(cpu) {
                return processS5eThreadFanoutFail(19)
            }
            if cpu != primary && !smpCpuOnline(cpu) {
                return processS5eThreadFanoutFail(20)
            }
            if processDispatchTelemetryCount[idx] == 0 ||
               smpPerCpuEl0SwitchCount(cpu) == 0 {
                return processS5eThreadFanoutFail(21)
            }
        } else if cpu >= platform.cpuCount && processDispatchTelemetryCount[idx] != 0 {
            return processS5eThreadFanoutFail(22)
        }
        cpu += 1
    }
    return true
}

private func processS5fRunAnyPlacementFail(_ code: UInt64) -> Bool {
    uartPuts("S5f run-any placement fail ")
    uartPutUInt(code)
    uartPuts("\n")
    return false
}

func processS5fRunAnyPlacementSelfTest() -> Bool {
    let primary = currentCpuId()
    if primary != 0 || !processValidSchedulerCpu(primary) {
        return processS5fRunAnyPlacementFail(1)
    }
    if !lastS5fRunAnyTelemetryValid {
        return processS5fRunAnyPlacementFail(2)
    }
    if s5fRunAnyPlacementActive {
        return processS5fRunAnyPlacementFail(3)
    }
    if lastS5fRunAnyProcessCount == 0 ||
       lastS5fRunAnyPolicySelectionCount != lastS5fRunAnyProcessCount {
        return processS5fRunAnyPlacementFail(4)
    }
    let primaryMask = processCpuBit(primary)
    if (lastS5fRunAnySchedulerCpuMask & primaryMask) == 0 {
        return processS5fRunAnyPlacementFail(5)
    }
    if lastS5fRunAnyDispatchCpuMask != lastS5fRunAnySchedulerCpuMask {
        return processS5fRunAnyPlacementFail(6)
    }
    if lastS5fRunAnyExactCpuMatchCount != lastS5fRunAnyProcessCount {
        return processS5fRunAnyPlacementFail(7)
    }
    if lastS5fRunAnyDispatchCount < lastS5fRunAnyProcessCount {
        return processS5fRunAnyPlacementFail(8)
    }
    if platform.cpuCount > 1 {
        if lastS5fRunAnySecondaryCpuMask == 0 {
            return processS5fRunAnyPlacementFail(9)
        }
        if (lastS5fRunAnySecondaryCpuMask & primaryMask) != 0 {
            return processS5fRunAnyPlacementFail(10)
        }
        if (lastS5fRunAnySchedulerCpuMask & ~primaryMask) != lastS5fRunAnySecondaryCpuMask {
            return processS5fRunAnyPlacementFail(11)
        }
    } else if lastS5fRunAnySecondaryCpuMask != 0 ||
              lastS5fRunAnyDispatchCpuMask != primaryMask {
        return processS5fRunAnyPlacementFail(12)
    }

    if (processSecondaryRunMask() & lastS5fRunAnySecondaryCpuMask) != 0 {
        return processS5fRunAnyPlacementFail(13)
    }
    if (processSecondaryActiveMask() & lastS5fRunAnySecondaryCpuMask) != 0 {
        return processS5fRunAnyPlacementFail(14)
    }
    if (processSecondaryStopMask() & lastS5fRunAnySecondaryCpuMask) != 0 {
        return processS5fRunAnyPlacementFail(15)
    }

    var expectedCount: UInt64 = 0
    var cpu: UInt32 = 0
    while cpu < processRunQueueCpuCount {
        let idx = Int(cpu)
        let bit = processCpuBit(cpu)
        if processRunQueueLockWord[idx] != 0 {
            return processS5fRunAnyPlacementFail(16)
        }
        if processRunQueueHead[idx] != noProcessSlot ||
           processRunQueueTail[idx] != noProcessSlot ||
           !smpPerCpuProcessRunQueueIdle(cpu) {
            return processS5fRunAnyPlacementFail(17)
        }
        if (lastS5fRunAnySchedulerCpuMask & bit) != 0 {
            expectedCount &+= 1
            if cpu >= platform.cpuCount || !processValidSchedulerCpu(cpu) {
                return processS5fRunAnyPlacementFail(18)
            }
            if cpu != primary && !smpCpuOnline(cpu) {
                return processS5fRunAnyPlacementFail(19)
            }
            if processDispatchTelemetryCount[idx] == 0 ||
               smpPerCpuEl0SwitchCount(cpu) == 0 {
                return processS5fRunAnyPlacementFail(20)
            }
        } else if cpu >= platform.cpuCount && processDispatchTelemetryCount[idx] != 0 {
            return processS5fRunAnyPlacementFail(21)
        }
        cpu += 1
    }
    if expectedCount == 0 || expectedCount > lastS5fRunAnyProcessCount {
        return processS5fRunAnyPlacementFail(22)
    }
    return true
}

func processMultiCpuSchedulerPostRunSelfTest() -> Bool {
    let primary = currentCpuId()
    if primary != 0 || !processValidSchedulerCpu(primary) { return false }
    if processRunQueueEnqueueCount[Int(primary)] == 0 { return false }
    if processRunQueueDispatchCount[Int(primary)] == 0 { return false }
    if processDispatchTelemetryCount[Int(primary)] == 0 { return false }
    if processDispatchTelemetryCount[Int(primary)] != smpPerCpuEl0SwitchCount(primary) {
        return false
    }
    if processSecondaryRunMask() != 0 { return false }
    if processSecondaryActiveMask() != 0 { return false }

    var sawSecondaryDispatch = false
    var cpu: UInt32 = 0
    while cpu < processRunQueueCpuCount {
        let idx = Int(cpu)
        if processRunQueueHead[idx] != noProcessSlot { return false }
        if processRunQueueTail[idx] != noProcessSlot { return false }
        if !smpPerCpuProcessRunQueueIdle(cpu) { return false }
        if cpu != primary && processDispatchTelemetryCount[idx] != 0 {
            sawSecondaryDispatch = true
            if smpPerCpuEl0SwitchCount(cpu) == 0 { return false }
        }
        cpu += 1
    }
    return platform.cpuCount > 1 ? sawSecondaryDispatch : true
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

func processAddressSpaceTlbFlushFacadeSelfTest() -> Bool {
    if !addressSpaceTlbFlushFacadeSelfTest() { return false }
    return processCurrentAddressSpaceActiveCpuMask() == addressSpaceCurrentCpuTlbMask()
}

func processAddressSpaceTlbFlushPostRunSelfTest() -> Bool {
    let primary = currentCpuId()
    if primary != 0 || !processValidSchedulerCpu(primary) { return false }
    for slot in 0..<maxProc {
        if pState[slot] == pUnused { continue }
        if (processAddressSpaceActiveCpuMaskForSlot(slot) & ~pDispatchCpuMask[slot]) != 0 {
            return false
        }
    }
    return processAddressSpaceCpuMaskPostRunSelfTest()
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

func processIsActive() -> Bool { currentProcessSlot() >= 0 }
func processLastKilledBySignal() -> Bool { lastReapedKilled }
func processCurrentAddressSpace() -> UInt {
    let current = currentProcessSlot()
    return current >= 0 ? pTtbr0[current] : 0
}
func processCurrentSlot() -> Int { currentProcessSlot() }

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
    for i in 0..<maxProc where pState[i] == pUnused && pSchedulerQuiesced[i] { return i }
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

private func buildUserEntryStack(_ ttbr0: UInt, packed: UInt, packedLen: UInt,
                                 argc: Int, envPacked: UInt = 0,
                                 envPackedLen: UInt = 0, envc: Int = 0) -> UInt {
    let argvPtr = (packedLen > 0 && argc > 0) ? UnsafePointer<CChar>(bitPattern: packed) : nil
    let envPtr = (envPackedLen > 0 && envc > 0) ? UnsafePointer<CChar>(bitPattern: envPacked) : nil
    if argc > 0 && argvPtr == nil { return 0 }
    if envc > 0 && envPtr == nil { return 0 }

    // Absent argv/envp must still produce a mapped, valid argc=0/envp=NULL
    // process-entry frame instead of an unmapped SP.
    return userStackBuild(ttbr0, userStackTop, argvPtr, packedLen, Int32(argc),
                          envPtr, envPackedLen, Int32(envc))
}

// Build a process from an ELF image. Returns its slot, or -1. `inherit` selects
// how the child's handle table is seeded from the parent (C2): `.all` preserves
// fork-inherits-everything behavior; `.stdioOnly` keeps legacy spawn tight; and
// `.explicit` installs only the provided HandleSpec vector.
private func createProcess(_ image: UInt, _ size: UInt, packed: UInt, packedLen: UInt,
                           argc: Int, parent: Int, inherit: HandleInheritance = .all,
                           inheritSpecsVA: UInt = 0, inheritSpecCount: UInt = 0,
                           homeCpu: UInt32 = unassignedCpu) -> Int {
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

    let userSP = buildUserEntryStack(ttbr0, packed: packed, packedLen: packedLen, argc: argc)
    if userSP == 0 {
        address_space_destroy(ttbr0)
        return -1
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
    anonVmasClear(slot)
    pIsThread[slot] = false
    clearSignalFrameState(slot)
    processSignalClearAllPending(slot)
    // elfLoad (above) recorded the image's mapped page count; stack mapping used
    // the PMM directly, so it is still valid. RES = image + user stack pages.
    pCpuTicks[slot] = 0
    pStartTick[slot] = systemTicks
    pResPages[slot] = Int(elfLastLoadPages()) + userStackPages
    pWakeTick[slot] = 0
    pSchedulerQuiesced[slot] = false
    pReparentedOrphan[slot] = false
    pHomeCpu[slot] = unassignedCpu
    pRunNext[slot] = noProcessSlot
    pRunQueued[slot] = false
    pLastDispatchCpu[slot] = unassignedCpu
    pDispatchCount[slot] = 0
    pDispatchCpuMask[slot] = 0
    pAddressSpaceCpuMask[slot] = 0
    setProcessName(slot: slot, packed: packed, argc: argc)
    setProcessSecurity(slot: slot, parent: parent)
    vfsProcessInit(slot: slot, parent: parent, inherit: inherit,
                   specsVA: inheritSpecsVA, specCount: inheritSpecCount)
    let targetCpu = homeCpu == unassignedCpu ? processHomeCpuForNewReadySlot(slot) : homeCpu
    markProcessReady(slot, cpu: targetCpu)
    return slot
}

private func buildExecImage(_ image: UInt, _ size: UInt, packed: UInt, packedLen: UInt,
                            argc: Int, envPacked: UInt, envPackedLen: UInt,
                            envc: Int) -> (UInt, UInt, UInt) {
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

    let userSP = buildUserEntryStack(ttbr0, packed: packed, packedLen: packedLen,
                                     argc: argc, envPacked: envPacked,
                                     envPackedLen: envPackedLen, envc: envc)
    if userSP == 0 {
        address_space_destroy(ttbr0)
        return (0, 0, 0)
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
    let current = currentProcessSlot()
    if current < 0 {
        uartPuts("panic: yieldToScheduler without current process\n")
        while true {}
    }
    let daif = irq_save()
    let schedulerContext = schedulerContextForCurrentCpu()
    cpu_switch_context(UnsafeMutableRawPointer(procCtx.advanced(by: current)),
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
    if !pSchedulerQuiesced[slot] {
        uartPuts("panic: reapProcess before scheduler quiescence\n")
        while true {}
    }
    if pTtbr0[slot] != 0 {
        address_space_destroy(pTtbr0[slot])
        pTtbr0[slot] = 0
    }
    clearSignalFrameState(slot)
    processSignalClearAllPending(slot)
    if pKstack[slot] != 0 {
        var pa = pKstack[slot]
        for _ in 0..<kernelStackPages {
            pmmFreePage(pa)
            pa += PageAllocator.pageSize
        }
        pKstack[slot] = 0
    }
    // QW3: adopt this slot's children. A child that has ALREADY exited and is
    // quiesced is an orphan nobody will ever waitpid() — reap it directly here
    // rather than leak its zombie slot. Re-scan after every reap because reaping
    // a child can reparent (and recursively reap) its own descendants, mutating
    // pParent under us; the scan is bounded by the live-tree depth (<= maxProc).
    var collected = true
    while collected {
        collected = false
        for i in 0..<maxProc
        where pParent[i] == slot && pState[i] == pZombie && pSchedulerQuiesced[i] {
            reapProcess(i)
            collected = true
        }
    }
    // Any still-live children become kernel orphans. Flag them so a later exit is
    // collected by the in-scheduler reaper (nobody waitpid()s a -1 parent).
    for i in 0..<maxProc where pParent[i] == slot {
        pParent[i] = -1
        pReparentedOrphan[i] = true
    }
    pState[slot] = pUnused
    clearProcessSchedulerSlot(slot)
    pSchedulerQuiesced[slot] = true
    pReparentedOrphan[slot] = false
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
        setCurrentProcessSlot(s)
        pState[s] = pRunning
        pSchedulerQuiesced[s] = false
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
        address_space_switch(mmu_kernel_ttbr0())
        if pState[s] == pZombie || pState[s] == pUnused {
            pSchedulerQuiesced[s] = true
            smpStoreBarrier()
        }
        setCurrentProcessSlot(-1)
        // QW3: collect a runtime-orphaned zombie (reparented to the kernel when
        // its real parent was reaped) that no one will ever waitpid(). This is
        // gated to pReparentedOrphan so it never races an orchestrator that is
        // schedule(until:)-waiting on a top-level zombie it created with parent
        // -1 (those are NOT flagged and are reaped by the orchestrator).
        if pState[s] == pZombie && pSchedulerQuiesced[s]
           && pParent[s] == -1 && pReparentedOrphan[s] {
            reapProcess(s)
        }
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
    schedule(until: { pState[slot] == pZombie && pSchedulerQuiesced[slot] })
    let code = pExit[slot]
    lastReapedKilled = pKilled[slot]
    reapProcess(slot)
    return code
}

/// Kernel-internal observability: number of process slots currently in use
/// (state != pUnused). Used by the QW3 orphan-reap self-test (no ABI surface).
func processLiveSlotCount() -> Int {
    var n = 0
    for i in 0..<maxProc where pState[i] != pUnused { n += 1 }
    return n
}

/// QW3 self-test driver: launch `image` as a top-level process (parent -1) that
/// forks a child and exits WITHOUT waiting (orphaning it), reap that parent —
/// which adopts the still-live child to the kernel and flags it an orphan — then
/// drive the scheduler until every user slot is free again, i.e. until the kernel
/// has collected the orphaned child's zombie. Returns false if the parent could
/// not be launched. Hangs (caught by the test driver's timeout) only if the
/// orphan is never collected — exactly the leak this milestone fixes.
func processOrphanReapRound(_ image: UInt, _ size: UInt,
                            packed: UInt, packedLen: UInt, argc: Int) -> Bool {
    let p = createProcess(image, size, packed: packed, packedLen: packedLen,
                          argc: argc, parent: -1)
    if p < 0 { return false }
    schedule(until: { pState[p] == pZombie && pSchedulerQuiesced[p] })
    reapProcess(p)
    schedule(until: { processLiveSlotCount() == 0 })
    return true
}

/// Run two top-level processes concurrently; return when both have exited.
func processRunPair(_ imageA: UInt, _ sizeA: UInt, _ pa: UInt, _ na: UInt, _ ca: Int,
                    _ imageB: UInt, _ sizeB: UInt, _ pb: UInt, _ nb: UInt, _ cb: Int) {
    let secondary = processFirstSecondarySchedulerCpu()
    if secondary != unassignedCpu {
        processStartSecondaryScheduler(cpu: secondary)
    }
    let a = createProcess(imageA, sizeA, packed: pa, packedLen: na, argc: ca,
                          parent: -1, inherit: .all, inheritSpecsVA: 0,
                          inheritSpecCount: 0, homeCpu: 0)
    let bHome = secondary == unassignedCpu ? UInt32(0) : secondary
    let b = createProcess(imageB, sizeB, packed: pb, packedLen: nb, argc: cb,
                          parent: -1, inherit: .all, inheritSpecsVA: 0,
                          inheritSpecCount: 0, homeCpu: bHome)
    if a < 0 || b < 0 {
        uartPuts("panic: createProcess (pair) failed\n")
        while true {}
    }
    schedule(until: { pState[a] == pZombie && pSchedulerQuiesced[a] &&
                      pState[b] == pZombie && pSchedulerQuiesced[b] })
    if secondary != unassignedCpu {
        processStopSecondaryScheduler(cpu: secondary)
    }
    captureLastPairDispatchTelemetry(a, b)
    reapProcess(a)
    reapProcess(b)
}

/// Run a bounded S5b placement batch under the restricted secondary EL0 gate.
func processRunS5bPlacementBatch(_ image: UInt, _ size: UInt,
                                 _ pa: UInt, _ na: UInt, _ ca: Int,
                                 _ pb: UInt, _ nb: UInt, _ cb: Int,
                                 _ pc: UInt, _ nc: UInt, _ cc: Int) {
    let secondary = processFirstSecondarySchedulerCpu()
    if secondary != unassignedCpu {
        processStartSecondaryScheduler(cpu: secondary)
    }
    let a = createProcess(image, size, packed: pa, packedLen: na, argc: ca,
                          parent: -1, inherit: .all, inheritSpecsVA: 0,
                          inheritSpecCount: 0, homeCpu: 0)
    let secondaryHome = secondary == unassignedCpu ? UInt32(0) : secondary
    let b = createProcess(image, size, packed: pb, packedLen: nb, argc: cb,
                          parent: -1, inherit: .all, inheritSpecsVA: 0,
                          inheritSpecCount: 0, homeCpu: secondaryHome)
    if a < 0 || b < 0 {
        uartPuts("panic: createProcess (S5b placement batch) failed\n")
        while true {}
    }
    schedule(until: { pState[a] == pZombie && pSchedulerQuiesced[a] &&
                      pState[b] == pZombie && pSchedulerQuiesced[b] })
    if secondary != unassignedCpu {
        processStopSecondaryScheduler(cpu: secondary)
    }
    let cHome: UInt32 = 0
    let c = createProcess(image, size, packed: pc, packedLen: nc, argc: cc,
                          parent: -1, inherit: .all, inheritSpecsVA: 0,
                          inheritSpecCount: 0, homeCpu: cHome)
    if c < 0 {
        uartPuts("panic: createProcess (S5b placement batch tail) failed\n")
        while true {}
    }
    schedule(until: { pState[c] == pZombie && pSchedulerQuiesced[c] })
    smpLoadBarrier()
    captureLastS5bBatchDispatchTelemetry(a, b, c)
    reapProcess(a)
    reapProcess(b)
    reapProcess(c)
}

/// Run repeated independent EL0 placement rounds through the restricted gate.
func processRunS5cPlacementStress(_ image: UInt, _ size: UInt,
                                  _ primaryPacked: UInt, _ primaryPackedLen: UInt, _ primaryArgc: Int,
                                  _ secondaryPacked: UInt, _ secondaryPackedLen: UInt, _ secondaryArgc: Int,
                                  _ tailPacked: UInt, _ tailPackedLen: UInt, _ tailArgc: Int) {
    let primary = currentCpuId()
    let secondary = processFirstSecondarySchedulerCpu()
    let secondaryHome = secondary == unassignedCpu ? primary : secondary

    if secondary != unassignedCpu {
        processStartSecondaryScheduler(cpu: secondary)
    }

    var rounds: UInt64 = 0
    var processCount: UInt64 = 0
    var primaryDispatchCount: UInt64 = 0
    var secondaryDispatchCount: UInt64 = 0
    var primaryCpuMask: UInt64 = 0
    var secondaryCpuMask: UInt64 = 0

    while rounds < s5cPlacementStressRounds {
        let a = createProcess(image, size, packed: primaryPacked,
                              packedLen: primaryPackedLen, argc: primaryArgc,
                              parent: -1, inherit: .all, inheritSpecsVA: 0,
                              inheritSpecCount: 0, homeCpu: primary)
        let b = createProcess(image, size, packed: secondaryPacked,
                              packedLen: secondaryPackedLen, argc: secondaryArgc,
                              parent: -1, inherit: .all, inheritSpecsVA: 0,
                              inheritSpecCount: 0, homeCpu: secondaryHome)
        if a < 0 || b < 0 {
            uartPuts("panic: createProcess (S5c placement stress) failed\n")
            while true {}
        }

        schedule(until: { pState[a] == pZombie && pSchedulerQuiesced[a] &&
                          pState[b] == pZombie && pSchedulerQuiesced[b] })
        smpLoadBarrier()
        primaryDispatchCount &+= pDispatchCount[a]
        secondaryDispatchCount &+= pDispatchCount[b]
        primaryCpuMask |= pDispatchCpuMask[a]
        secondaryCpuMask |= pDispatchCpuMask[b]
        processCount &+= 2
        reapProcess(a)
        reapProcess(b)
        rounds &+= 1
    }

    if secondary != unassignedCpu {
        processStopSecondaryScheduler(cpu: secondary)
    }

    var tails: UInt64 = 0
    while tails < s5cPlacementStressCpu0TailCount {
        let c = createProcess(image, size, packed: tailPacked,
                              packedLen: tailPackedLen, argc: tailArgc,
                              parent: -1, inherit: .all, inheritSpecsVA: 0,
                              inheritSpecCount: 0, homeCpu: primary)
        if c < 0 {
            uartPuts("panic: createProcess (S5c placement stress tail) failed\n")
            while true {}
        }
        schedule(until: { pState[c] == pZombie && pSchedulerQuiesced[c] })
        smpLoadBarrier()
        primaryDispatchCount &+= pDispatchCount[c]
        primaryCpuMask |= pDispatchCpuMask[c]
        processCount &+= 1
        reapProcess(c)
        tails &+= 1
    }

    captureLastS5cPlacementStressTelemetry(
        rounds: rounds,
        processCount: processCount,
        primaryDispatchCount: primaryDispatchCount,
        secondaryDispatchCount: secondaryDispatchCount,
        primaryCpuMask: primaryCpuMask,
        secondaryCpuMask: secondaryCpuMask,
        secondaryCpu: secondaryHome)
}

/// Run one independent EL0 process on each available scheduler CPU.
func processRunS5dFanout(_ image: UInt, _ size: UInt,
                         _ packed: UInt, _ packedLen: UInt, _ argc: Int) {
    let primary = currentCpuId()
    var idx = 0
    while idx < processSchedulerCpuSlots {
        s5dFanoutSlots[idx] = -1
        idx += 1
    }

    var startedSecondaryMask: UInt64 = 0
    var schedulerCpuMask = processCpuBit(primary)
    var processCount = 0

    let primarySlot = createProcess(image, size, packed: packed, packedLen: packedLen,
                                    argc: argc, parent: -1, inherit: .all,
                                    inheritSpecsVA: 0, inheritSpecCount: 0,
                                    homeCpu: primary)
    if primarySlot < 0 {
        uartPuts("panic: createProcess (S5d fanout primary) failed\n")
        while true {}
    }
    s5dFanoutSlots[processCount] = primarySlot
    processCount += 1

    var cpu: UInt32 = 1
    while cpu < processRunQueueCpuCount &&
          cpu < platform.cpuCount &&
          processCount < processSchedulerCpuSlots {
        if processValidSchedulerCpu(cpu) &&
           smpCpuOnline(cpu) &&
           smpPerCpuTimerTicks(cpu) != 0 {
            processStartSecondaryScheduler(cpu: cpu)
            let bit = processCpuBit(cpu)
            startedSecondaryMask |= bit
            schedulerCpuMask |= bit

            let slot = createProcess(image, size, packed: packed, packedLen: packedLen,
                                     argc: argc, parent: -1, inherit: .all,
                                     inheritSpecsVA: 0, inheritSpecCount: 0,
                                     homeCpu: cpu)
            if slot < 0 {
                uartPuts("panic: createProcess (S5d fanout secondary) failed\n")
                while true {}
            }
            s5dFanoutSlots[processCount] = slot
            processCount += 1
        }
        cpu += 1
    }

    schedule(until: {
        var slotIndex = 0
        while slotIndex < processCount {
            let slot = s5dFanoutSlots[slotIndex]
            if slot < 0 ||
               pState[slot] != pZombie ||
               !pSchedulerQuiesced[slot] {
                return false
            }
            slotIndex += 1
        }
        return true
    })

    cpu = 1
    while cpu < processRunQueueCpuCount && cpu < platform.cpuCount {
        let bit = processCpuBit(cpu)
        if (startedSecondaryMask & bit) != 0 {
            processStopSecondaryScheduler(cpu: cpu)
        }
        cpu += 1
    }

    smpLoadBarrier()
    var dispatchCpuMask: UInt64 = 0
    var secondaryCpuMask: UInt64 = 0
    var dispatchCount: UInt64 = 0
    var exactCpuMatchCount: UInt64 = 0
    idx = 0
    while idx < processCount {
        let slot = s5dFanoutSlots[idx]
        let home = pHomeCpu[slot]
        let homeMask = processCpuBit(home)
        if home != primary {
            secondaryCpuMask |= homeMask
        }
        dispatchCpuMask |= pDispatchCpuMask[slot]
        dispatchCount &+= pDispatchCount[slot]
        if pDispatchCpuMask[slot] == homeMask && pDispatchCount[slot] != 0 {
            exactCpuMatchCount &+= 1
        }
        idx += 1
    }
    captureLastS5dFanoutTelemetry(
        processCount: UInt64(processCount),
        schedulerCpuMask: schedulerCpuMask,
        dispatchCpuMask: dispatchCpuMask,
        secondaryCpuMask: secondaryCpuMask,
        dispatchCount: dispatchCount,
        exactCpuMatchCount: exactCpuMatchCount)

    idx = 0
    while idx < processCount {
        reapProcess(s5dFanoutSlots[idx])
        s5dFanoutSlots[idx] = -1
        idx += 1
    }
}

/// Run the native thread/futex demo while S5e places created threads on
/// secondary scheduler CPUs that share the same TTBR0 as the creator.
func processRunS5eThreadFanout(_ image: UInt, _ size: UInt,
                               _ packed: UInt, _ packedLen: UInt, _ argc: Int) -> Int {
    let primary = currentCpuId()
    var startedSecondaryMask: UInt64 = 0
    resetLastS5eThreadFanoutTelemetry()

    var cpu: UInt32 = 1
    while cpu < processRunQueueCpuCount && cpu < platform.cpuCount {
        if processValidSchedulerCpu(cpu) &&
           smpCpuOnline(cpu) &&
           smpPerCpuTimerTicks(cpu) != 0 {
            processStartSecondaryScheduler(cpu: cpu)
            startedSecondaryMask |= processCpuBit(cpu)
        }
        cpu += 1
    }

    s5eThreadPlacementActive = true
    let slot = createProcess(image, size, packed: packed, packedLen: packedLen,
                             argc: argc, parent: -1, inherit: .all,
                             inheritSpecsVA: 0, inheritSpecCount: 0,
                             homeCpu: primary)
    if slot < 0 {
        uartPuts("panic: createProcess (S5e thread fanout) failed\n")
        while true {}
    }

    schedule(until: { pState[slot] == pZombie && pSchedulerQuiesced[slot] })
    let code = pExit[slot]
    if code == 0 {
        // The parent observes worker completion through a futex before a worker
        // necessarily reaches SYS_exit and records S5e telemetry.
        schedule(until: { s5eThreadFanoutWorkersExited() })
    }

    cpu = 1
    while cpu < processRunQueueCpuCount && cpu < platform.cpuCount {
        let bit = processCpuBit(cpu)
        if (startedSecondaryMask & bit) != 0 {
            processStopSecondaryScheduler(cpu: cpu)
        }
        cpu += 1
    }

    smpLoadBarrier()
    s5eThreadPlacementActive = false
    captureLastS5eThreadFanoutTelemetry()
    lastReapedKilled = pKilled[slot]
    reapProcess(slot)
    return code
}

/// Exercise the default "run anywhere" placement policy under the restricted
/// S2h gate by creating a batch without explicit home CPUs.
func processRunS5fRunAnyPlacement(_ image: UInt, _ size: UInt,
                                  _ packed: UInt, _ packedLen: UInt, _ argc: Int) {
    let primary = currentCpuId()
    resetLastS5fRunAnyTelemetry()

    var startedSecondaryMask: UInt64 = 0
    var schedulerCpuMask = processCpuBit(primary)
    var cpu: UInt32 = 1
    while cpu < processRunQueueCpuCount && cpu < platform.cpuCount {
        if processValidSchedulerCpu(cpu) &&
           smpCpuOnline(cpu) &&
           smpPerCpuTimerTicks(cpu) != 0 {
            processStartSecondaryScheduler(cpu: cpu)
            let bit = processCpuBit(cpu)
            startedSecondaryMask |= bit
            schedulerCpuMask |= bit
        }
        cpu += 1
    }

    var processCount = Int(platform.cpuCount) + 2
    if processCount > maxProc { processCount = maxProc }
    if processCount < 1 { processCount = 1 }
    s5fRunAnyPlacementActive = true
    s5fNextPlacementCpu = primary

    var idx = 0
    while idx < processCount {
        let slot = createProcess(image, size, packed: packed, packedLen: packedLen,
                                 argc: argc, parent: -1, inherit: .all,
                                 inheritSpecsVA: 0, inheritSpecCount: 0,
                                 homeCpu: unassignedCpu)
        if slot < 0 {
            uartPuts("panic: createProcess (S5f run-any placement) failed\n")
            while true {}
        }
        s5fRunAnySlots[idx] = slot
        idx += 1
    }
    s5fRunAnyPlacementActive = false

    schedule(until: {
        var slotIndex = 0
        while slotIndex < processCount {
            let slot = s5fRunAnySlots[slotIndex]
            if slot < 0 ||
               pState[slot] != pZombie ||
               !pSchedulerQuiesced[slot] {
                return false
            }
            slotIndex += 1
        }
        return true
    })

    cpu = 1
    while cpu < processRunQueueCpuCount && cpu < platform.cpuCount {
        let bit = processCpuBit(cpu)
        if (startedSecondaryMask & bit) != 0 {
            processStopSecondaryScheduler(cpu: cpu)
        }
        cpu += 1
    }

    smpLoadBarrier()
    var dispatchCpuMask: UInt64 = 0
    var secondaryCpuMask: UInt64 = 0
    var dispatchCount: UInt64 = 0
    var exactCpuMatchCount: UInt64 = 0
    idx = 0
    while idx < processCount {
        let slot = s5fRunAnySlots[idx]
        let home = pHomeCpu[slot]
        let homeMask = processCpuBit(home)
        if home != primary {
            secondaryCpuMask |= homeMask
        }
        dispatchCpuMask |= pDispatchCpuMask[slot]
        dispatchCount &+= pDispatchCount[slot]
        if pDispatchCpuMask[slot] == homeMask && pDispatchCount[slot] != 0 {
            exactCpuMatchCount &+= 1
        }
        idx += 1
    }
    captureLastS5fRunAnyTelemetry(
        processCount: UInt64(processCount),
        schedulerCpuMask: schedulerCpuMask,
        dispatchCpuMask: dispatchCpuMask,
        secondaryCpuMask: secondaryCpuMask,
        dispatchCount: dispatchCount,
        exactCpuMatchCount: exactCpuMatchCount)

    idx = 0
    while idx < processCount {
        reapProcess(s5fRunAnySlots[idx])
        s5fRunAnySlots[idx] = -1
        idx += 1
    }
}

private func processSpawnChildWithInheritance(_ image: UInt, _ size: UInt, packed: UInt,
                                              packedLen: UInt, argc: Int,
                                              inherit: HandleInheritance,
                                              specsVA: UInt = 0, specCount: UInt = 0,
                                              setuid: Bool = false, setuidOwner: UInt32 = 0) -> Int {
    let parent = currentProcessSlot()
    guard parent >= 0 else { return -22 }
    let valid = vfsValidateHandleInheritance(parent: parent, inherit: inherit,
                                             specsVA: specsVA, specCount: specCount)
    if valid < 0 { return valid }
    let child = createProcess(image, size, packed: packed, packedLen: packedLen, argc: argc,
                              parent: parent, inherit: inherit,
                              inheritSpecsVA: specsVA, inheritSpecCount: specCount)
    if child < 0 { return -11 } // EAGAIN
    // setuid-on-exec for the spawn path: the child inherited the parent's context
    // in createProcess; elevate it to the file owner with the invoker preserved
    // as the real identity (mirrors the execve path in processExec).
    if setuid {
        pSecurity[child] = securityApplySetuid(pSecurity[child], owner: setuidOwner)
    }
    pState[parent] = pBlocked
    pWait[parent] = child
    yieldToScheduler() // scheduler runs the child; we resume once it exits
    let code = pExit[child]
    pWait[parent] = waitNone
    reapProcess(child)
    return code
}

/// spawn(path) child: create it with stdio only, block until it exits, return its exit status.
func processSpawnChild(_ image: UInt, _ size: UInt, packed: UInt, packedLen: UInt, argc: Int,
                       setuid: Bool = false, setuidOwner: UInt32 = 0) -> Int {
    return processSpawnChildWithInheritance(image, size, packed: packed, packedLen: packedLen,
                                            argc: argc, inherit: .stdioOnly,
                                            setuid: setuid, setuidOwner: setuidOwner)
}

/// spawn_handles(path) child: start from an empty handle table and inherit exactly
/// the caller-provided HandleSpec vector.
func processSpawnChildWithHandles(_ image: UInt, _ size: UInt, packed: UInt, packedLen: UInt,
                                  argc: Int, specsVA: UInt, specCount: UInt,
                                  setuid: Bool = false, setuidOwner: UInt32 = 0) -> Int {
    return processSpawnChildWithInheritance(image, size, packed: packed, packedLen: packedLen,
                                            argc: argc, inherit: .explicit,
                                            specsVA: specsVA, specCount: specCount,
                                            setuid: setuid, setuidOwner: setuidOwner)
}

func processCurrentPid() -> Int {
    let current = currentProcessSlot()
    return current >= 0 ? current + 1 : 0
}

func processYieldForIO() {
    let current = currentProcessSlot()
    if current < 0 { return }
    markProcessReadyOnHomeCpu(current)
    yieldToScheduler()
}

/// fork(): COW-clone the current process. The child gets a cloned address space
/// whose user pages initially share frames with the parent, plus a copy of the
/// parent's trap frame with x0=0, so it "returns from fork()" into EL0 at the
/// same point seeing 0; the parent gets the child pid.
func processFork(_ frame: UnsafeMutablePointer<UInt>) -> Int {
    let parent = currentProcessSlot()
    guard parent >= 0 else { return -11 }
    let child = allocSlot()
    if child < 0 { return -11 } // EAGAIN

    let childTtbr0 = addressSpaceCloneForActiveCpuMask(pTtbr0[parent],
                                                       processAddressSpaceActiveCpuMaskForSlot(parent))
    if childTtbr0 == 0 { return -12 } // ENOMEM

    let kstack = pmmAllocPages(kernelStackPages)
    if kstack == 0 { address_space_destroy(childTtbr0); return -12 }
    let kstackTop = kstack + UInt(kernelStackPages) * PageAllocator.pageSize

    // Copy the parent's full lower-EL trap frame, including FP/SIMD state, to
    // the top of the child kstack.
    let childFrameAddr = kstackTop - UInt(trapFrameBytes)
    let childFrame = UnsafeMutablePointer<UInt>(bitPattern: childFrameAddr)!
    for i in 0..<trapFrameWords { childFrame[i] = frame[i] }
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
    anonVmasCopy(child, parent)
    pIsThread[child] = false
    clearSignalFrameState(child)
    processSignalClearAllPending(child) // POSIX: pending signals are not inherited
    // The COW address-space clone preserves the child's logical mapped
    // footprint; physical frames are copied lazily on write. CPU/time start
    // fresh.
    pCpuTicks[child] = 0
    pStartTick[child] = systemTicks
    pResPages[child] = pResPages[parent]
    pWakeTick[child] = 0
    pSchedulerQuiesced[child] = false
    pReparentedOrphan[child] = false
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
    let creator = currentProcessSlot()
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
    anonVmasCopy(slot, creator)
    pIsThread[slot] = true
    clearSignalFrameState(slot)
    processSignalClearAllPending(slot)
    pWakeTick[slot] = 0
    pSchedulerQuiesced[slot] = false
    pReparentedOrphan[slot] = false
    pHomeCpu[slot] = unassignedCpu
    pRunNext[slot] = noProcessSlot
    pRunQueued[slot] = false
    pLastDispatchCpu[slot] = unassignedCpu
    pDispatchCount[slot] = 0
    pDispatchCpuMask[slot] = 0
    pAddressSpaceCpuMask[slot] = 0
    copyProcessName(from: creator, to: slot)
    copyProcessSecurity(from: creator, to: slot)
    // Share VFS state by snapshotting the creator's fd table + cwd (the demo only
    // needs shared stdout; full fd-table aliasing is a follow-up — see NOTES).
    vfsProcessInit(slot: slot, parent: creator)
    if s5eThreadPlacementActive {
        let home = processNextS5eThreadHomeCpu()
        recordS5eThreadCreate(creator: creator, slot: slot, homeCpu: home)
        markProcessReady(slot, cpu: home)
    } else {
        markProcessReadyOnHomeCpu(slot)
    }
    return slot + 1 // thread id (a pid in the shared table)
}

/// FUTEX_WAIT backend: block the current thread until a FUTEX_WAKE marks it
/// ready again. Mirrors processYieldForIO but parks in pBlocked (it must not be
/// rescheduled until explicitly woken). Returns once rescheduled.
func processPrepareBlockOnFutex() -> Bool {
    let me = currentProcessSlot()
    if me < 0 { return false }
    pState[me] = pBlocked
    return true
}

func processYieldAfterPreparedFutexBlock() {
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
    let me = currentProcessSlot()
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
    let parent = currentProcessSlot()
    guard parent >= 0 else { return -10 }
    if statusVA != 0 && userWritableBuffer(statusVA, 4) == nil { return -22 }
    let wantSlot = pid > 0 ? pid - 1 : waitAny

    while true {
        var found = -1
        var live = 0
        for i in 0..<maxProc where pState[i] != pUnused && pParent[i] == parent {
            if wantSlot != waitAny && i != wantSlot { continue }
            live += 1
            if pState[i] == pZombie && pSchedulerQuiesced[i] { found = i; break }
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

/// POSIX-shaped kill(pid, sig) subset for process lifecycle control.
///
/// Supported now: positive PIDs, signal 0 existence probes, and default/ignored
/// termination signals. Current-process custom handlers are delivered on syscall
/// return through a kernel-built user signal frame and a userspace sigreturn
/// trampoline. Process groups and remote async handler delivery are future work.
func processInstallSignalFrame(sig: Int, handler: UInt, restorer: UInt,
                               frame: UnsafeMutablePointer<UInt>) -> Bool {
    let me = currentProcessSlot()
    if me < 0 || me >= maxProc { return false }
    if pSignalFrameActive[me] { return false }
    if handler == SIG_DFL || handler == SIG_IGN || restorer == 0 { return false }

    let oldSP = frame[trapFrameSPIndex]
    if oldSP < UInt(signalFrameBytes) { return false }
    let newSP = (oldSP - UInt(signalFrameBytes)) & ~UInt(15)
    guard let dst = userWritableBuffer(newSP, UInt(signalFrameBytes)) else { return false }

    let words = UnsafeMutableRawPointer(dst).bindMemory(to: UInt.self,
                                                        capacity: signalFrameWords)
    words[0] = signalFrameMagic
    words[1] = UInt(sig)
    var i = 0
    while i < trapFrameWords {
        words[signalFrameHeaderWords + i] = frame[i]
        i += 1
    }

    pSignalFrameActive[me] = true
    pSignalFrameSP[me] = newSP

    frame[0] = UInt(sig)               // handler(int signo)
    frame[30] = restorer               // LR: userspace sigreturn trampoline
    frame[trapFrameSPIndex] = newSP
    frame[trapFrameELRIndex] = handler
    frame[trapFrameSPSRIndex] = 0
    return true
}

func processSignalReturn(_ frame: UnsafeMutablePointer<UInt>) {
    let me = currentProcessSlot()
    guard me >= 0 && me < maxProc && pSignalFrameActive[me] else {
        processTerminateBySignal(SIGSEGV)
        return
    }

    let sp = pSignalFrameSP[me]
    guard let src = userReadableBuffer(sp, UInt(signalFrameBytes)) else {
        processTerminateBySignal(SIGSEGV)
        return
    }
    let words = UnsafeRawPointer(src).bindMemory(to: UInt.self,
                                                 capacity: signalFrameWords)
    guard words[0] == signalFrameMagic else {
        processTerminateBySignal(SIGSEGV)
        return
    }

    var i = 0
    while i < trapFrameWords {
        frame[i] = words[signalFrameHeaderWords + i]
        i += 1
    }
    clearSignalFrameState(me)
}

func processKill(_ pid: Int, _ sig: Int) -> Int {
    if !signalIsValid(sig) && sig != 0 { return -22 } // EINVAL
    if pid <= 0 { return -22 } // process groups are not modeled yet
    let slot = pid - 1
    if slot < 0 || slot >= maxProc || pState[slot] == pUnused { return -3 } // ESRCH
    if sig == 0 { return 0 }
    if signalDisposition(sig) == SIG_IGN { return 0 }

    let me = currentProcessSlot()
    if slot == me {
        if signalDisposition(sig) != SIG_DFL && signalRestorer(sig) != 0 {
            signalRaise(sig)
            return 0
        }
        processTerminateBySignal(sig) // never returns
    }

    if pState[slot] == pZombie { return 0 }
    if pState[slot] == pRunning { return -16 } // avoid remote-CPU teardown

    if pRunQueued[slot] {
        removeProcessFromRunQueue(slot)
    }
    vfsProcessCloseAll(slot: slot)
    futexForgetSlot(slot)
    ipcForgetSlot(slot)  // QW2: drop any endpoint waiter record for this slot
    pWait[slot] = waitNone
    pWakeTick[slot] = 0
    pExit[slot] = 128 + sig
    pKilled[slot] = true
    pState[slot] = pZombie
    pSchedulerQuiesced[slot] = true
    wakeParent(of: slot)
    return 0
}

/// execve(path, argv, envp): replace the current process image and return from
/// this syscall directly into the new EL0 entry point, with argv/envp copied
/// onto the new user stack.
func processExec(image: UInt, size: UInt, packed: UInt, packedLen: UInt,
                 argc: Int, envPacked: UInt, envPackedLen: UInt, envc: Int,
                 setuid: Bool = false, setuidOwner: UInt32 = 0,
                 frame: UnsafeMutablePointer<UInt>) -> Int {
    let me = currentProcessSlot()
    guard me >= 0 else { return -22 }

    let (ttbr0, entry, userSP) = buildExecImage(image, size, packed: packed,
                                                packedLen: packedLen, argc: argc,
                                                envPacked: envPacked,
                                                envPackedLen: envPackedLen,
                                                envc: envc)
    if ttbr0 == 0 { return -12 } // ENOMEM / invalid image during bring-up

    // The old image is fully replaced; reclaim its frames once we are no longer
    // running on its tables. The kernel stack is reused across exec, so it is
    // not freed here — only the address space.
    let oldTtbr0 = pTtbr0[me]
    pTtbr0[me] = ttbr0
    pBrk[me] = userHeapBase
    pMmapTop[me] = userMmapTop // fresh image: empty mmap arena
    fileVmasClear(me)
    anonVmasClear(me)
    clearSignalFrameState(me)
    processSignalClearAllPending(me) // exec resets pending signals
    // New image replaces the resident set (old pages are dropped with the old
    // address space); accumulated CPU time and the start tick survive the exec.
    pResPages[me] = Int(elfLastLoadPages()) + userStackPages
    // POSIX: close-on-exec descriptors are dropped across exec. ash relocates
    // its saved fds above 10 with F_DUPFD_CLOEXEC and relies on this.
    vfsCloseCloexec(slot: me)
    // Identity across exec: a setuid base-image binary elevates the effective
    // identity to the file owner (full root authority) while preserving the
    // invoker as the real identity; an ordinary exec keeps the current identity
    // and re-establishes real==effective.
    if setuid {
        pSecurity[me] = securityApplySetuid(pSecurity[me], owner: setuidOwner)
    } else {
        pSecurity[me] = securitySyncRealToEffective(pSecurity[me])
    }
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

private func sysInfoCpuCount() -> UInt32 {
    var count = platform.cpuCount
    if count == 0 { count = 1 }
    let max = smpMaxCpuCount()
    if count > max { count = max }
    if count > UInt32(sysInfoCpuMax) { count = UInt32(sysInfoCpuMax) }
    return count
}

/// SYS_sysinfo: copy a system-wide stats blob for /bin/top.
/// Legacy layout (64 bytes, naturally aligned): uptimeTicks:u64, idleTicks:u64,
/// memTotal:u64, memFree:u64, kernelImage:u64, kernelHeap:u64, hz:u32,
/// procTotal:u32, procRunning:u32, reserved:u32. Passing a nonzero capacity at
/// least sysInfoSize appends cpuCount:u32, cpuCapacity:u32, per-CPU timer ticks,
/// and per-CPU idle ticks.
func processSysInfo(buffer: UInt, capacity: UInt) -> Int {
    let requested = capacity == 0 ? UInt(sysInfoLegacySize) : capacity
    if requested < UInt(sysInfoLegacySize) { return -22 }
    let writeSize = requested >= UInt(sysInfoSize) ? sysInfoSize : sysInfoLegacySize
    guard let dst = userWritableBuffer(buffer, UInt(writeSize)) else { return -22 }
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
    let cpuCount = sysInfoCpuCount()

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

    if writeSize >= sysInfoSize {
        raw.storeBytes(of: cpuCount, toByteOffset: 64, as: UInt32.self)
        raw.storeBytes(of: UInt32(sysInfoCpuMax), toByteOffset: 68, as: UInt32.self)
        var cpu = 0
        while cpu < sysInfoCpuMax {
            let cpuId = UInt32(cpu)
            let ticks = cpuId < cpuCount ? smpPerCpuTimerTicks(cpuId) : 0
            let idle = cpuId < cpuCount ? smpPerCpuIdleTicks(cpuId) : 0
            raw.storeBytes(of: ticks, toByteOffset: 72 + (cpu * 8), as: UInt64.self)
            raw.storeBytes(of: idle, toByteOffset: 72 + (sysInfoCpuMax * 8) + (cpu * 8), as: UInt64.self)
            cpu += 1
        }
    }
    return 0
}

/// SYS_security_info: copy the current process security context.
/// Record layout (16 bytes): principal:u32, session:u32, caps:u64.
/// The capability mask of the running process (M13). Used by the VFS to check
/// file access against the process's principal context. The kernel itself
/// (no active process) is fully privileged.
func processCurrentCaps() -> UInt64 {
    let current = currentProcessSlot()
    return current >= 0 ? pSecurity[current].caps : ~UInt64(0)
}

/// The principal id of the running process (M13c). Used by the VFS to stamp the
/// owner on tmpfs nodes it creates. The kernel itself (no active process) acts
/// as the boot/root principal 1.
func processCurrentPrincipal() -> UInt32 {
    let current = currentProcessSlot()
    return current >= 0 ? pSecurity[current].principal : 1
}

func processSecurityInfo(buffer: UInt) -> Int {
    let me = currentProcessSlot()
    guard me >= 0 else { return -22 }
    guard let dst = userWritableBuffer(buffer, 16) else { return -22 }
    let raw = UnsafeMutableRawPointer(dst)
    raw.storeBytes(of: pSecurity[me].principal, toByteOffset: 0, as: UInt32.self)
    raw.storeBytes(of: pSecurity[me].session, toByteOffset: 4, as: UInt32.self)
    raw.storeBytes(of: pSecurity[me].caps, toByteOffset: 8, as: UInt64.self)
    return 0
}

/// SYS_security_info_ex: copy the current process's effective AND real security
/// identity. Record layout (32 bytes): principal:u32, session:u32, caps:u64,
/// real_principal:u32, real_session:u32, real_caps:u64. `/bin/sudo` uses the
/// real identity to learn the invoker while running setuid-root.
func processSecurityInfoEx(buffer: UInt) -> Int {
    let me = currentProcessSlot()
    guard me >= 0 else { return -22 }
    guard let dst = userWritableBuffer(buffer, 32) else { return -22 }
    let raw = UnsafeMutableRawPointer(dst)
    raw.storeBytes(of: pSecurity[me].principal, toByteOffset: 0, as: UInt32.self)
    raw.storeBytes(of: pSecurity[me].session, toByteOffset: 4, as: UInt32.self)
    raw.storeBytes(of: pSecurity[me].caps, toByteOffset: 8, as: UInt64.self)
    raw.storeBytes(of: pSecurity[me].realPrincipal, toByteOffset: 16, as: UInt32.self)
    raw.storeBytes(of: pSecurity[me].realSession, toByteOffset: 20, as: UInt32.self)
    raw.storeBytes(of: pSecurity[me].realCaps, toByteOffset: 24, as: UInt64.self)
    return 0
}

/// SYS_login: replace the current process's security context after the caller
/// has authenticated a principal (M12b). Privileged: only a process holding
/// capConsole (the boot/login context) may do this, so an ordinary program
/// cannot grant itself a principal or capabilities. The new context is
/// inherited across the subsequent execve into the user's shell.
func processLogin(principal: UInt32, session: UInt32, caps: UInt64) -> Int {
    let me = currentProcessSlot()
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
    let cpu = currentCpuId()
    if !processCpuCanSchedule(cpu) {
        uartPuts("panic: processOnTick entered on inactive scheduler CPU\n")
        while true {}
    }

    // Wake any sleepers whose deadline has passed. Runs first and unconditionally
    // (even when no process is current during the scheduler's idle wfi) so a sleep
    // resumes promptly on an otherwise idle system. Only nanosleep blockers carry
    // a nonzero pWakeTick, so futex/waitpid/IO blockers are left untouched.
    if cpu == 0 {
        for i in 0..<maxProc where pState[i] == pBlocked && pWakeTick[i] != 0 {
            if systemTicks >= pWakeTick[i] {
                markProcessReadyOnHomeCpu(i)
                pWakeTick[i] = 0
            }
        }
    }

    // CPU accounting for /bin/top. Charge a tick as *user* time to the running
    // process only when the timer interrupted EL0 (it was executing user code);
    // EL1 ticks — the scheduler's idle wfi, and a process parked in a wfi-based
    // blocking syscall (poll/read) — count as idle. So a process sleeping on
    // input shows ~0% CPU and an idle system shows ~100% idle, while a CPU-bound
    // EL0 loop shows ~100%. (Kernel "system" time is bucketed into idle; a
    // separate sy% would need to distinguish syscall work from a wfi wait.)
    let current = currentProcessSlot()
    if fromEL0 && current >= 0 {
        pCpuTicks[current] &+= 1
    } else {
        if cpu == 0 {
            idleTicks &+= 1
            smpRecordIdleTickForCurrentCpu()
        }
    }
    if current >= 0 && pState[current] == pRunning {
        markProcessReadyOnHomeCpu(current)
        yieldToScheduler()
    }
}

/// SYS_exit: zombify the current process, wake a waiting parent, leave the CPU.
func processExit(_ code: Int) {
    let me = currentProcessSlot()
    vfsProcessCloseAll(slot: me)
    // rt-a: a thread has no waitpid joiner (siblings join via futex), so it must
    // not linger as an unreapable zombie — free its slot directly. The shared
    // address space stays mapped for the surviving threads. Drop any stale futex
    // wait record first so a later wake cannot resurrect a reused slot.
    if pIsThread[me] {
        recordS5eThreadExit(me)
        futexForgetSlot(me)
        ipcForgetSlot(me)  // QW2: drop any endpoint waiter record for this slot
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
    let me = currentProcessSlot()
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
    let me = currentProcessSlot()
    guard me >= 0 else { return fail }
    let old = pBrk[me]
    if incr == 0 { return old }

    let newBreak = UInt(bitPattern: Int(bitPattern: old) + incr)
    if newBreak < userHeapBase { return fail }
    if newBreak > userMmapFloor { return fail } // heap stops below the mmap arena

    let mask = PageAllocator.pageSize - 1
    let oldTop = (old + mask) & ~mask
    let newTop = (newBreak + mask) & ~mask
    if newTop > oldTop {
        let activeMask = processAddressSpaceActiveCpuMaskForSlot(me)
        var va = oldTop
        while va < newTop {
            let pa = pmmAllocZeroedPage()
            if pa == 0 ||
               addressSpaceMapForActiveCpuMask(pTtbr0[me], va, pa, Int32(VM_PERM_USER_DATA), activeMask) != 0 {
                if pa != 0 { pmmFreePage(pa) }
                if va > oldTop {
                    _ = addressSpaceMunmapForActiveCpuMask(pTtbr0[me],
                                                           oldTop,
                                                           (va - oldTop) / PageAllocator.pageSize,
                                                           activeMask)
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

private let MAP_FIXED: Int32 = 0x10
private let MAP_FIXED_NOREPLACE: Int32 = 0x100000

private func mappedPageCount(_ ttbr0: UInt, _ addr: UInt, _ pages: UInt) -> Int {
    var live = 0
    var i: UInt = 0
    while i < pages {
        if address_space_translate(ttbr0, addr + i * PageAllocator.pageSize) != 0 { live += 1 }
        i += 1
    }
    return live
}

/// mmap(addr, len, prot, flags): reserve `len` (rounded up to whole pages) in
/// the anonymous mmap arena and return its base VA. Without MAP_FIXED, SwiftOS
/// ignores addr as a hint and carves a fresh descending region. MAP_FIXED can
/// replace pages only inside an existing anonymous reservation; this is enough
/// for V8-style reserve-PROT_NONE, fixed-commit, guard-page flows without
/// introducing arbitrary sparse user mappings yet. MAP_FIXED_NOREPLACE reports
/// EEXIST when the target overlaps an existing reservation or live mapping.
/// PROT_NONE reserves VA only; other valid mappings allocate zero-filled memory.
/// PROT_WRITE|PROT_EXEC is rejected with EINVAL. Errors are returned as a
/// negative errno encoded in the UInt result.
func processMmap(_ addr: UInt, _ len: UInt, _ prot: Int32, _ flags: Int32) -> UInt {
    func err(_ e: Int) -> UInt { UInt(bitPattern: e) }
    let me = currentProcessSlot()
    guard me >= 0 else { return err(-22) } // EINVAL
    if len == 0 { return err(-22) }
    // W^X up front (also enforced in protPageDesc for committed pages).
    if (prot & PROT_WRITE) != 0 && (prot & PROT_EXEC) != 0 { return err(-22) }

    let pages = roundUpPages(len)
    let bytes = pages * PageAllocator.pageSize

    let fixed = (flags & (MAP_FIXED | MAP_FIXED_NOREPLACE)) != 0
    if fixed {
        if addr == 0 || (addr & (PageAllocator.pageSize - 1)) != 0 { return err(-22) }
        if addr < userMmapFloor || addr >= userMmapTop { return err(-22) }
        if addr > userMmapTop - bytes { return err(-22) }
        if prot != PROT_NONE && (prot & (PROT_READ | PROT_WRITE | PROT_EXEC)) == 0 { return err(-22) }

        if (flags & MAP_FIXED_NOREPLACE) != 0 {
            if anonVmaOverlaps(me, addr, pages) || mappedPageCount(pTtbr0[me], addr, pages) > 0 {
                return err(-17) // EEXIST
            }
            return err(-22) // SwiftOS does not create sparse fixed reservations yet.
        }

        if !anonVmaContains(me, addr, pages) { return err(-22) }
        let live = mappedPageCount(pTtbr0[me], addr, pages)
        let unmapRc = addressSpaceMunmapForActiveCpuMask(pTtbr0[me],
                                                         addr,
                                                         pages,
                                                         processAddressSpaceActiveCpuMaskForSlot(me))
        if unmapRc != 0 { return err(Int(unmapRc)) }
        pResPages[me] -= live
        if prot == PROT_NONE { return addr }

        let mapRc = addressSpaceMmapForActiveCpuMask(pTtbr0[me],
                                                     addr,
                                                     pages,
                                                     prot,
                                                     processAddressSpaceActiveCpuMaskForSlot(me))
        if mapRc != 0 { return err(Int(mapRc)) }
        pResPages[me] += Int(pages)
        return addr
    }

    // Carve the region just below the cursor, growing down. Guard against
    // underflow and against running into the stack region.
    if pMmapTop[me] < userMmapFloor + bytes { return err(-12) } // ENOMEM: arena full
    let base = pMmapTop[me] - bytes

    if !anonVmaAdd(me, base, pages) { return err(-12) }
    if prot == PROT_NONE {
        pMmapTop[me] = base
        return base
    }
    if (prot & (PROT_READ | PROT_WRITE | PROT_EXEC)) == 0 {
        anonVmasDeactivateOverlap(me, base, pages)
        return err(-22)
    }

    let rc = addressSpaceMmapForActiveCpuMask(pTtbr0[me],
                                              base,
                                              pages,
                                              prot,
                                              processAddressSpaceActiveCpuMaskForSlot(me))
    if rc != 0 {
        anonVmasDeactivateOverlap(me, base, pages)
        return err(Int(rc))
    }
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
    let me = currentProcessSlot()
    guard me >= 0 else { return err(-22) } // EINVAL
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
    let me = currentProcessSlot()
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
        if addressSpaceMapFilePageForActiveCpuMask(pTtbr0[me],
                                                   pageVA,
                                                   v.diskImage,
                                                   v.diskOffset + contentStart,
                                                   contentLen,
                                                   v.prot,
                                                   processAddressSpaceActiveCpuMaskForSlot(me)) {
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
    let me = currentProcessSlot()
    guard me >= 0 else { return -22 }
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
    let rc = addressSpaceMunmapForActiveCpuMask(pTtbr0[me],
                                                addr,
                                                pages,
                                                processAddressSpaceActiveCpuMaskForSlot(me))
    if rc != 0 { return Int(rc) }
    pResPages[me] -= live
    // I6: a lazily-reserved file VMA must not survive its munmap — the cursor
    // reclaim below can hand the same VA range to a future mmap, and a stale
    // VMA would demand-fill the new mapping from the OLD file's disk extent.
    // Any overlap deactivates the whole file VMA (and frees its slot). A partial
    // munmap therefore drops demand paging for the VMA's remaining pages:
    // already-materialized ones stay mapped, untouched ones become fatal on
    // access — acceptable for the map-whole/unmap-whole file pattern, and
    // documented here until a file-VMA split is needed.
    for vi in 0..<maxFileVmas {
        let idx = me * maxFileVmas + vi
        if !pFileVmas[idx].active { continue }
        let vBase = pFileVmas[idx].base
        let vEnd = vBase + pFileVmas[idx].pages * PageAllocator.pageSize
        if addr < vEnd && addr + bytes > vBase { pFileVmas[idx].active = false }
    }
    // Anon VMAs split on partial munmap: V8's aligned allocator over-allocates
    // then trims the unaligned ends, and the aligned middle must stay tracked so
    // a later mprotect(commit) can demand-fill it. (Whole-VMA deactivation here
    // was the intermittent cppgc/Oilpan "out of memory" — the committed middle
    // had no VMA to back it.)
    anonVmasUnmapRange(me, addr, pages)
    // Cursor reclaim: if the freed region sat at the bottom of the arena, hand
    // the VA space back so a later mmap can reuse it. (Interior holes are left
    // as gaps — a free-list is a follow-up; the JIT pattern maps once.)
    if addr == pMmapTop[me] { pMmapTop[me] += bytes }
    return 0
}

/// mprotect(addr, len, prot): change protection on an existing mapping. addr
/// must be page-aligned and in the mmap arena. Inside an anonymous reservation,
/// missing pages are committed on demand for non-PROT_NONE protections, and
/// PROT_NONE decommits live pages while preserving VA. PROT_WRITE|PROT_EXEC
/// (W^X) is rejected. This is the JIT lever: reserve PROT_NONE, commit RW,
/// write code, then flip the region to RX. Returns 0 or errno.
func processMprotect(_ addr: UInt, _ len: UInt, _ prot: Int32) -> Int {
    let me = currentProcessSlot()
    guard me >= 0 else { return -22 }
    if len == 0 { return -22 }
    if (addr & (PageAllocator.pageSize - 1)) != 0 { return -22 }
    let pages = roundUpPages(len)
    let bytes = pages * PageAllocator.pageSize
    if addr < pMmapTop[me] || addr >= userMmapTop { return -22 }
    if addr > userMmapTop - bytes { return -22 }

    if prot == PROT_NONE {
        if !anonVmaContains(me, addr, pages) { return -12 }
        var live = 0
        var i: UInt = 0
        while i < pages {
            if address_space_translate(pTtbr0[me], addr + i * PageAllocator.pageSize) != 0 { live += 1 }
            i += 1
        }
        let rc = addressSpaceMunmapForActiveCpuMask(pTtbr0[me],
                                                    addr,
                                                    pages,
                                                    processAddressSpaceActiveCpuMaskForSlot(me))
        if rc != 0 { return Int(rc) }
        pResPages[me] -= live
        return 0
    }

    // W^X invariant enforced HERE (syscall entry) as well as in protPageDesc.
    if (prot & PROT_WRITE) != 0 && (prot & PROT_EXEC) != 0 { return -22 } // EINVAL
    if (prot & (PROT_READ | PROT_WRITE | PROT_EXEC)) == 0 { return -22 }

    if anonVmaContains(me, addr, pages) {
        var committed = 0
        var i: UInt = 0
        while i < pages {
            let cur = addr + i * PageAllocator.pageSize
            if address_space_translate(pTtbr0[me], cur) == 0 {
                let rc = addressSpaceMmapForActiveCpuMask(pTtbr0[me],
                                                          cur,
                                                          1,
                                                          prot,
                                                          processAddressSpaceActiveCpuMaskForSlot(me))
                if rc != 0 { return Int(rc) }
                committed += 1
            }
            i += 1
        }
        pResPages[me] += committed
    }

    return Int(addressSpaceMprotectForActiveCpuMask(pTtbr0[me],
                                                    addr,
                                                    pages,
                                                    prot,
                                                    processAddressSpaceActiveCpuMaskForSlot(me)))
}
