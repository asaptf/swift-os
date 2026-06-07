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
private let procNameMax = 16
private let psInfoRecordSize = 32

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
private var pNameLen = [Int](repeating: 0, count: maxProc)
private var pName = [UInt8](repeating: 0, count: maxProc * procNameMax)
private var pPrincipal = [UInt32](repeating: 0, count: maxProc)
private var pSession = [UInt32](repeating: 0, count: maxProc)
private var pCaps = [UInt64](repeating: 0, count: maxProc)
// rt-a: a thread shares its creator's address space (TTBR0) instead of owning a
// private one, so its exit must not be treated as an address-space teardown and
// it joins via futex rather than waitpid.
private var pIsThread = [Bool](repeating: false, count: maxProc)

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
        pPrincipal[slot] = pPrincipal[parent]
        pSession[slot] = pSession[parent]
        pCaps[slot] = pCaps[parent]
        return
    }
    let ctx = securityBootContext()
    pPrincipal[slot] = ctx.principal
    pSession[slot] = ctx.session
    pCaps[slot] = ctx.caps
}

private func copyProcessSecurity(from parent: Int, to child: Int) {
    if parent < 0 || parent >= maxProc || child < 0 || child >= maxProc { return }
    pPrincipal[child] = pPrincipal[parent]
    pSession[child] = pSession[parent]
    pCaps[child] = pCaps[parent]
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
    pIsThread[slot] = false
    setProcessName(slot: slot, packed: packed, argc: argc)
    setProcessSecurity(slot: slot, parent: parent)
    vfsProcessInit(slot: slot, parent: parent)
    return slot
}

private func buildExecImage(_ image: UInt, _ size: UInt, packed: UInt, packedLen: UInt,
                            argc: Int) -> (UInt, UInt, UInt) {
    let ttbr0 = address_space_create()
    if ttbr0 == 0 { return (0, 0, 0) }
    let entry = elf_load(ttbr0, UnsafeRawPointer(bitPattern: image), size)
    if entry == 0 { return (0, 0, 0) }

    var va = userStackTop - UInt(userStackPages) * PageAllocator.pageSize
    while va < userStackTop {
        let pa = pmmAllocZeroedPage()
        if pa == 0 || address_space_map(ttbr0, va, pa, Int32(VM_PERM_USER_DATA)) != 0 {
            return (0, 0, 0)
        }
        va += PageAllocator.pageSize
    }

    var userSP = userStackTop
    if packedLen > 0 && argc > 0 {
        let built = user_stack_build(ttbr0, userStackTop,
                                     UnsafePointer<CChar>(bitPattern: packed), packedLen, Int32(argc))
        if built != 0 { userSP = built }
    }
    return (ttbr0, entry, userSP)
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
    cpu_switch_context(UnsafeMutableRawPointer(procCtx.advanced(by: currentProc)),
                       UnsafeMutableRawPointer(schedCtx))
    irq_restore(daif)
}

private func wakeParent(of slot: Int) {
    let pp = pParent[slot]
    if pp >= 0 && pState[pp] == pBlocked && (pWait[pp] == slot || pWait[pp] == waitAny) {
        pState[pp] = pReady
    }
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
        pState[s] = pRunning
        // cpu_switch_context swaps registers only — install the process's
        // address space so its EL0 user VAs resolve when it eret's.
        address_space_switch(pTtbr0[s])
        cpu_switch_context(UnsafeMutableRawPointer(schedCtx),
                           UnsafeMutableRawPointer(procCtx.advanced(by: s)))
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

func processCurrentPid() -> Int { currentProc >= 0 ? currentProc + 1 : 0 }

func processYieldForIO() {
    if currentProc < 0 { return }
    pState[currentProc] = pReady
    yieldToScheduler()
}

/// fork(): eager-copy the current process. The child gets a cloned address
/// space and a copy of the parent's trap frame with x0=0, so it "returns from
/// fork()" into EL0 at the same point seeing 0; the parent gets the child pid.
func processFork(_ frame: UnsafeMutablePointer<UInt>) -> Int {
    let parent = currentProc
    guard parent >= 0 else { return -11 }
    let child = allocSlot()
    if child < 0 { return -11 } // EAGAIN

    let childTtbr0 = address_space_clone(pTtbr0[parent])
    if childTtbr0 == 0 { return -12 } // ENOMEM

    let kstack = pmmAllocPages(2)
    if kstack == 0 { return -12 }
    let kstackTop = kstack + 2 * PageAllocator.pageSize

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

    pState[child] = pReady
    pParent[child] = parent
    pTtbr0[child] = childTtbr0
    pExit[child] = 0
    pKilled[child] = false
    pWait[child] = waitNone
    pBrk[child] = pBrk[parent]
    pIsThread[child] = false
    copyProcessName(from: parent, to: child)
    copyProcessSecurity(from: parent, to: child)
    vfsProcessInit(slot: child, parent: parent)
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

    pState[slot] = pReady
    // Parent is the creator's parent so the thread is a sibling, not a child:
    // it must not be reapable by the creator's waitpid (threads join via futex).
    pParent[slot] = pParent[creator]
    pTtbr0[slot] = pTtbr0[creator] // SHARED — not a clone
    pExit[slot] = 0
    pKilled[slot] = false
    pWait[slot] = waitNone
    pBrk[slot] = pBrk[creator]
    pIsThread[slot] = true
    copyProcessName(from: creator, to: slot)
    copyProcessSecurity(from: creator, to: slot)
    // Share VFS state by snapshotting the creator's fd table + cwd (the demo only
    // needs shared stdout; full fd-table aliasing is a follow-up — see NOTES).
    vfsProcessInit(slot: slot, parent: creator)
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
    if pState[slot] == pBlocked { pState[slot] = pReady }
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
            pState[found] = pUnused // reap
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

    pTtbr0[me] = ttbr0
    pBrk[me] = userHeapBase
    // POSIX: close-on-exec descriptors are dropped across exec. ash relocates
    // its saved fds above 10 with F_DUPFD_CLOEXEC and relies on this.
    vfsCloseCloexec(slot: me)
    setProcessName(slot: me, packed: packed, argc: argc)
    frame[trapFrameSPIndex] = userSP
    frame[trapFrameELRIndex] = entry
    frame[trapFrameSPSRIndex] = 0
    address_space_switch(ttbr0)
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

/// SYS_security_info: copy the current process security context.
/// Record layout (16 bytes): principal:u32, session:u32, caps:u64.
/// The capability mask of the running process (M13). Used by the VFS to check
/// file access against the process's principal context. The kernel itself
/// (no active process) is fully privileged.
func processCurrentCaps() -> UInt64 {
    currentProc >= 0 ? pCaps[currentProc] : ~UInt64(0)
}

/// The principal id of the running process (M13c). Used by the VFS to stamp the
/// owner on tmpfs nodes it creates. The kernel itself (no active process) acts
/// as the boot/root principal 1.
func processCurrentPrincipal() -> UInt32 {
    currentProc >= 0 ? pPrincipal[currentProc] : 1
}

func processSecurityInfo(buffer: UInt) -> Int {
    let me = currentProc
    guard me >= 0 else { return -22 }
    guard let dst = userWritableBuffer(buffer, 16) else { return -22 }
    let raw = UnsafeMutableRawPointer(dst)
    raw.storeBytes(of: pPrincipal[me], toByteOffset: 0, as: UInt32.self)
    raw.storeBytes(of: pSession[me], toByteOffset: 4, as: UInt32.self)
    raw.storeBytes(of: pCaps[me], toByteOffset: 8, as: UInt64.self)
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
    if (pCaps[me] & capConsole) == 0 { return -1 } // EPERM
    pPrincipal[me] = principal
    pSession[me] = session
    pCaps[me] = caps
    return 0
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
    vfsProcessCloseAll(slot: me)
    // rt-a: a thread has no waitpid joiner (siblings join via futex), so it must
    // not linger as an unreapable zombie — free its slot directly. The shared
    // address space stays mapped for the surviving threads. Drop any stale futex
    // wait record first so a later wake cannot resurrect a reused slot.
    if pIsThread[me] {
        futexForgetSlot(me)
        pState[me] = pUnused
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
                return fail
            }
            va += PageAllocator.pageSize
        }
    }
    pBrk[me] = newBreak
    return old
}
