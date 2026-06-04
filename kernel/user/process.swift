// process.swift — load and run a static ELF at EL0 (posix_spawn-style).
//
// We pick a posix_spawn-style primitive over fork/exec: there is no COW, and
// every process gets a fresh address space, so fork's copy semantics would add
// page-fault machinery we don't need to launch a tool. processRunElf builds the
// space, loads the image, maps a user stack, and switches into EL0.
//
// The run is synchronous: SYS_exit switches back to the kernel context saved
// here (via cpu_switch_context), so processRunElf returns the program's exit
// code. This naturally nests — a process that itself spawns a child suspends in
// its syscall while the child runs — which is what a shell needs later.

private let userStackTop: UInt = 0x9000_0000
private let userStackPages = 4

private var kernelReturnCtx: UnsafeMutablePointer<CPUContext>! = nil
private var launchCtx: UnsafeMutablePointer<CPUContext>! = nil
private var scratchCtx: UnsafeMutablePointer<CPUContext>! = nil
private var lastExitCode: Int = 0
private var processActive = false
private var killedBySignal = false

private func allocContext() -> UnsafeMutablePointer<CPUContext> {
    guard let raw = swiftos_kernel_alloc(UInt(MemoryLayout<CPUContext>.stride), 16) else {
        uartPuts("panic: process context allocation failed\n")
        while true {}
    }
    let ptr = raw.bindMemory(to: CPUContext.self, capacity: 1)
    ptr.pointee = CPUContext()
    return ptr
}

func processInit() {
    kernelReturnCtx = allocContext()
    launchCtx = allocContext()
    scratchCtx = allocContext()
}

func processIsActive() -> Bool {
    return processActive
}

func processLastKilledBySignal() -> Bool {
    return killedBySignal
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
        a.withUTF8Buffer { b in
            for c in b { buf[off] = c; off += 1 }
        }
        buf[off] = 0
        off += 1
    }
    return (UInt(bitPattern: raw), UInt(total), args.count)
}

/// Load the ELF at [image, image+size) into a fresh address space and run it at
/// EL0 with the given argv (packed as NUL-separated strings). Returns the
/// program's exit code once it calls exit().
func processRunElf(_ image: UInt, _ size: UInt, packed: UInt, packedLen: UInt, argc: Int) -> Int {
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

    launchCtx.pointee = CPUContext()
    launchCtx.pointee.x19 = UInt64(entry)
    launchCtx.pointee.x20 = UInt64(userSP)
    launchCtx.pointee.x21 = UInt64(ttbr0)
    launchCtx.pointee.lr = UInt64(user_thread_launch_addr())
    launchCtx.pointee.sp = UInt64(kstackTop)

    processActive = true
    killedBySignal = false
    cpu_switch_context(UnsafeMutableRawPointer(kernelReturnCtx),
                       UnsafeMutableRawPointer(launchCtx))
    // Resumes here once SYS_exit (or a fatal signal) switches back.
    processActive = false
    return lastExitCode
}

/// Terminate the foreground process because of a fatal signal. Records exit
/// status 128+signo and switches back to the launching kernel context, exactly
/// like processExit. Called from signal delivery; never returns.
func processTerminateBySignal(_ sig: Int) {
    killedBySignal = true
    lastExitCode = 128 + sig
    processActive = false
    address_space_switch(mmu_kernel_ttbr0())
    cpu_switch_context(UnsafeMutableRawPointer(scratchCtx),
                       UnsafeMutableRawPointer(kernelReturnCtx))
    while true { wfi() }
}

/// SYS_exit handler: record the code, restore the kernel address space, and
/// switch back to the context that launched the process. Never returns.
func processExit(_ code: Int) {
    lastExitCode = code
    address_space_switch(mmu_kernel_ttbr0())
    cpu_switch_context(UnsafeMutableRawPointer(scratchCtx),
                       UnsafeMutableRawPointer(kernelReturnCtx))
    while true { wfi() }
}
