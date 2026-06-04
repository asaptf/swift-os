// process.swift — preemptive EL0 process model.
//
// A real process table scheduled preemptively. Each process has its own address
// space, kernel stack, and saved CPUContext (the M4.5 switch primitive). The
// scheduler runs on the kernel_main stack as a dedicated context: it switches
// INTO a runnable process and regains control when that process yields, blocks,
// is preempted by the timer, or exits — classic per-CPU scheduler context.
//
// The kernel launches a top process and drives the scheduler until it exits
// (processRunElf). EL0 processes can spawn children and block waiting for them;
// the same scheduler loop runs the children and wakes the parent. This is the
// foundation for fork/execve/waitpid (next steps).
//
// NOTE: process teardown does not yet free its frames (address space, stacks);
// page reclamation is a follow-up. Fine for bring-up workloads.

private let userStackTop: UInt = 0x9000_0000
private let userStackPages = 4
private let userHeapBase: UInt = 0xA000_0000
private let maxProc = 16

// Process states.
private let pUnused: Int32 = 0
private let pReady: Int32 = 1
private let pRunning: Int32 = 2
private let pBlocked: Int32 = 3
private let pZombie: Int32 = 4

private let waitNone = -2 // not waiting
private let waitAny = -1  // any child

// Stable context storage for cpu_switch_context.
private var procCtx: UnsafeMutablePointer<CPUContext>! = nil   // [maxProc]
private var schedCtx: UnsafeMutablePointer<CPUContext>! = nil  // [1]

// Per-process metadata (parallel arrays; not address-sensitive).
private var pState = [Int32](repeating: 0, count: maxProc)
private var pParent = [Int](repeating: -1, count: maxProc)   // parent slot, -1 = kernel
private var pTtbr0 = [UInt](repeating: 0, count: maxProc)
private var pExit = [Int](repeating: 0, count: maxProc)
private var pKilled = [Bool](repeating: false, count: maxProc)
private var pWait = [Int](repeating: waitNone, count: maxProc) // slot waited on / waitAny
private var pBrk = [UInt](repeating: 0, count: maxProc)

private var currentProc = -1 // running slot, or -1 while in the scheduler
private var rrCursor = 0     // round-robin hint
private var lastReapedKilled = false

func processInit() {
    let n = MemoryLayout<CPUContext>.stride
    guard let c = swiftos_kernel_alloc(UInt(n * maxProc), 16),
          let s = swiftos_kernel_alloc(UInt(n), 16) else {
        uartPuts("panic: process context allocation failed\n")
        while true {}
    }
    procCtx = c.bindMemory(to: CPUContext.self, capacity: maxProc)
    schedCtx = s.bindMemory(to: CPUContext.self, capacity: 1)
    schedCtx.pointee = CPUContext()
    for i in 0..<maxProc { pState[i] = pUnused }
}

func processIsActive() -> Bool { currentProc >= 0 }
func processLastKilledBySignal() -> Bool { lastReapedKilled }
func processCurrentAddressSpace() -> UInt {
    currentProc >= 0 ? pTtbr0[currentProc] : 0
}

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

// Build a process from an ELF image. Returns its slot, or -1.
private func createProcess(_ image: UInt, _ size: UInt, packed: UInt, packedLen: UInt,
                           argc: Int, parent: Int) -> Int {
    let slot = allocSlot()
    if slot < 0 { return -1 }

    let ttbr0 = address_space_create()
    if ttbr0 == 0 { return -1 }
    let entry = elf_load(ttbr0, UnsafeRawPointer(bitPattern: image), size)
    if entry == 0 { return -1 }

    var va = userStackTop - UInt(userStackPages) * PageAllocator.pageSize
    while va < userStackTop {
        let pa = pmmAllocZeroedPage()
        if pa == 0 || address_space_map(ttbr0, va, pa, Int32(VM_PERM_USER_DATA)) != 0 { return -1 }
        va += PageAllocator.pageSize
    }

    let kstack = pmmAllocPages(2)
    if kstack == 0 { return -1 }
    let kstackTop = kstack + 2 * PageAllocator.pageSize

    var userSP = userStackTop
    if packedLen > 0 && argc > 0 {
        let built = user_stack_build(ttbr0, userStackTop,
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

    pState[slot] = pReady
    pParent[slot] = parent
    pTtbr0[slot] = ttbr0
    pExit[slot] = 0
    pKilled[slot] = false
    pWait[slot] = waitNone
    pBrk[slot] = userHeapBase
    return slot
}

private func pickReady() -> Int {
    for step in 1...maxProc {
        let i = (rrCursor + step) % maxProc
        if pState[i] == pReady { rrCursor = i; return i }
    }
    return -1
}

// Switch from the current process back into the scheduler. Returns when this
// process is scheduled again.
private func yieldToScheduler() {
    cpu_switch_context(UnsafeMutableRawPointer(procCtx.advanced(by: currentProc)),
                       UnsafeMutableRawPointer(schedCtx))
}

private func wakeParent(of slot: Int) {
    let pp = pParent[slot]
    if pp >= 0 && pState[pp] == pBlocked && (pWait[pp] == slot || pWait[pp] == waitAny) {
        pState[pp] = pReady
    }
}

// Run the scheduler until `until()` is satisfied (e.g. a target is a zombie).
private func schedule(until done: () -> Bool) {
    while !done() {
        let s = pickReady()
        if s < 0 {
            wfi() // nothing runnable yet (e.g. all blocked waiting on the timer)
            continue
        }
        currentProc = s
        pState[s] = pRunning
        // cpu_switch_context swaps registers only — install the process's
        // address space so its EL0 user VAs resolve when it eret's.
        address_space_switch(pTtbr0[s])
        cpu_switch_context(UnsafeMutableRawPointer(schedCtx),
                           UnsafeMutableRawPointer(procCtx.advanced(by: s)))
        currentProc = -1
    }
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
    pState[slot] = pUnused
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
    pState[a] = pUnused
    pState[b] = pUnused
}

/// spawn(path) child: create it, block until it exits, return its exit status.
func processSpawnChild(_ image: UInt, _ size: UInt, packed: UInt, packedLen: UInt, argc: Int) -> Int {
    let parent = currentProc
    let child = createProcess(image, size, packed: packed, packedLen: packedLen, argc: argc, parent: parent)
    if child < 0 { return -11 } // EAGAIN
    pState[parent] = pBlocked
    pWait[parent] = child
    yieldToScheduler() // scheduler runs the child; we resume once it exits
    let code = pExit[child]
    pWait[parent] = waitNone
    pState[child] = pUnused // reap
    return code
}

/// Timer preemption hook (called from the IRQ handler after the GIC EOI).
func processOnTick() {
    if currentProc >= 0 && pState[currentProc] == pRunning {
        pState[currentProc] = pReady
        yieldToScheduler()
    }
}

/// SYS_exit: zombify the current process, wake a waiting parent, leave the CPU.
func processExit(_ code: Int) {
    let me = currentProc
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
                return fail
            }
            va += PageAllocator.pageSize
        }
    }
    pBrk[me] = newBreak
    return old
}
