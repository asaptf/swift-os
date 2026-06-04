// process.swift — load and run static ELFs at EL0 (posix_spawn-style), nestable.
//
// We pick a posix_spawn-style primitive over fork/exec: there is no COW, and
// every process gets a fresh address space, so fork's copy semantics would add
// page-fault machinery we don't need to launch a tool.
//
// Runs are synchronous and NESTED: when a running EL0 process issues spawn(),
// the kernel runs the child to completion and returns its exit status to the
// parent's syscall — exactly the "shell launches a command and waits" pattern.
// Each nesting level keeps its own return context, child address space, and
// exit status; SYS_exit / a fatal signal unwinds the innermost level back to
// its launcher and restores the parent's address space.

private let userStackTop: UInt = 0x9000_0000
private let userStackPages = 4
private let maxDepth = 8

private var returnCtxs: UnsafeMutablePointer<CPUContext>! = nil // [maxDepth]
private var launchCtxs: UnsafeMutablePointer<CPUContext>! = nil // [maxDepth]
private var scratchCtx: UnsafeMutablePointer<CPUContext>! = nil

private var levelTtbr0 = [UInt](repeating: 0, count: maxDepth)
private var levelExitCode = [Int](repeating: 0, count: maxDepth)
private var levelKilled = [Bool](repeating: false, count: maxDepth)

private var depth = 0          // number of active nested EL0 processes
private var lastKilled = false // signal-kill flag of the most recent run

func processInit() {
    let n = MemoryLayout<CPUContext>.stride
    guard let r = swiftos_kernel_alloc(UInt(n * maxDepth), 16),
          let l = swiftos_kernel_alloc(UInt(n * maxDepth), 16),
          let s = swiftos_kernel_alloc(UInt(n), 16) else {
        uartPuts("panic: process context allocation failed\n")
        while true {}
    }
    returnCtxs = r.bindMemory(to: CPUContext.self, capacity: maxDepth)
    launchCtxs = l.bindMemory(to: CPUContext.self, capacity: maxDepth)
    scratchCtx = s.bindMemory(to: CPUContext.self, capacity: 1)
    scratchCtx.pointee = CPUContext()
}

func processIsActive() -> Bool { depth > 0 }
func processLastKilledBySignal() -> Bool { lastKilled }

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

/// Load the ELF at [image, image+size) into a fresh address space and run it at
/// EL0 with the given argv (packed NUL-separated). Returns its exit code. May be
/// called from the kernel or, re-entrantly, from a spawn() syscall.
func processRunElf(_ image: UInt, _ size: UInt, packed: UInt, packedLen: UInt, argc: Int) -> Int {
    let level = depth
    if level >= maxDepth { return -11 } // EAGAIN: too deep

    let ttbr0 = address_space_create()
    if ttbr0 == 0 {
        uartPuts("panic: address_space_create failed\n")
        while true {}
    }

    let entry = elf_load(ttbr0, UnsafeRawPointer(bitPattern: image), size)
    if entry == 0 {
        uartPuts("panic: elf_load failed\n")
        while true {}
    }

    // Map the user stack just below userStackTop.
    var va = userStackTop - UInt(userStackPages) * PageAllocator.pageSize
    while va < userStackTop {
        let pa = pmmAllocZeroedPage()
        if pa == 0 || address_space_map(ttbr0, va, pa, Int32(VM_PERM_USER_DATA)) != 0 {
            uartPuts("panic: user stack mapping failed\n")
            while true {}
        }
        va += PageAllocator.pageSize
    }

    // Kernel stack this EL0 thread uses while handling its own traps.
    let kstack = pmmAllocPages(2)
    if kstack == 0 {
        uartPuts("panic: kernel stack allocation failed\n")
        while true {}
    }
    let kstackTop = kstack + 2 * PageAllocator.pageSize

    // Lay out argc/argv/envp at the top of the user stack; SP starts there.
    var userSP = userStackTop
    if packedLen > 0 && argc > 0 {
        let built = user_stack_build(ttbr0, userStackTop,
                                     UnsafePointer<CChar>(bitPattern: packed),
                                     packedLen, Int32(argc))
        if built != 0 { userSP = built }
    }

    let launch = launchCtxs.advanced(by: level)
    launch.pointee = CPUContext()
    launch.pointee.x19 = UInt64(entry)
    launch.pointee.x20 = UInt64(userSP)
    launch.pointee.x21 = UInt64(ttbr0)
    launch.pointee.lr = UInt64(user_thread_launch_addr())
    launch.pointee.sp = UInt64(kstackTop)

    levelTtbr0[level] = ttbr0
    levelKilled[level] = false
    depth = level + 1

    cpu_switch_context(UnsafeMutableRawPointer(returnCtxs.advanced(by: level)),
                       UnsafeMutableRawPointer(launch))
    // Resumes here once the child unwinds (SYS_exit or a fatal signal).
    depth = level
    lastKilled = levelKilled[level]
    return levelExitCode[level]
}

/// Unwind the innermost running process back to its launcher, restoring the
/// parent's address space. Never returns.
private func processUnwind(_ code: Int, killed: Bool) {
    let level = depth - 1
    levelExitCode[level] = code
    levelKilled[level] = killed

    let parentTtbr0 = level > 0 ? levelTtbr0[level - 1] : mmu_kernel_ttbr0()
    address_space_switch(parentTtbr0)
    cpu_switch_context(UnsafeMutableRawPointer(scratchCtx),
                       UnsafeMutableRawPointer(returnCtxs.advanced(by: level)))
    while true { wfi() }
}

/// SYS_exit handler. Never returns.
func processExit(_ code: Int) {
    processUnwind(code, killed: false)
}

/// Fatal-signal termination of the foreground process (status 128+signo).
func processTerminateBySignal(_ sig: Int) {
    processUnwind(128 + sig, killed: true)
}
