// main.swift — Swift kernel entry point.
//
// The assembly boot stub (arch/aarch64/boot.S) sets up the stack and clears
// BSS, then calls `kernel_main`. We are at EL1, single core, MMU off.
//
// M0 goal: prove the Swift toolchain, boot path, and UART all work by printing
// a banner to the serial console. Everything else arrives in later milestones.

final class HeapProbe {
    let a: UInt
    let b: UInt

    init(_ a: UInt, _ b: UInt) {
        self.a = a
        self.b = b
    }

    func sum() -> UInt {
        a + b
    }
}

private var retainedProbe: HeapProbe? = nil

private func runVirtualMemoryProbe() {
    uartPuts("swift-os M3: enabling MMU\n")
    mmu_init_identity_map()
    uartPuts("M3 probe: page tables initialized\n")
    mmu_configure_translation()
    uartPuts("M3 probe: translation registers configured\n")
    mmu_enable_sctlr()
    uartPuts("M3 probe: MMU enable returned\n")

    if mmu_is_enabled() == 0 {
        uartPuts("panic: MMU did not enable\n")
        while true {}
    }

    let physicalPage = pmmAllocZeroedPage()
    if physicalPage == 0 {
        uartPuts("panic: VM probe page allocation failed\n")
        while true {}
    }
    let rawPage = UnsafeMutableRawPointer(bitPattern: physicalPage)!
    let testVA: UInt = 0x8000_0000
    if vm_map_page(testVA, physicalPage, UInt32(VM_ATTR_NORMAL)) != 0 {
        uartPuts("panic: vm_map_page failed\n")
        while true {}
    }

    if vm_translate(testVA) != physicalPage {
        uartPuts("panic: vm_translate after map failed\n")
        while true {}
    }

    let mapped = UnsafeMutableRawPointer(bitPattern: testVA)!
    mapped.storeBytes(of: UInt64(0xA11C_A7ED_0000_0003), as: UInt64.self)
    let stored = rawPage.load(as: UInt64.self)
    if stored != 0xA11C_A7ED_0000_0003 {
        uartPuts("panic: mapped VA write did not reach PA\n")
        while true {}
    }

    if vm_unmap_page(testVA) != 0 || vm_translate(testVA) != 0 {
        uartPuts("panic: vm_unmap_page failed\n")
        while true {}
    }

    uartPuts("M3 OK: MMU enabled and page map/unmap works\n")
}

private func runAddressSpaceProbe() {
    uartPuts("swift-os M4.5: per-process address spaces\n")

    let as1 = address_space_create()
    let as2 = address_space_create()
    if as1 == 0 || as2 == 0 {
        uartPuts("panic: address_space_create failed\n")
        while true {}
    }

    let p1 = pmmAllocZeroedPage()
    let p2 = pmmAllocZeroedPage()
    if p1 == 0 || p2 == 0 {
        uartPuts("panic: AS probe page allocation failed\n")
        while true {}
    }

    // Same virtual address, two address spaces, two physical frames.
    let va: UInt = 0x9000_0000
    if address_space_map(as1, va, p1, Int32(VM_PERM_USER_DATA)) != 0 ||
        address_space_map(as2, va, p2, Int32(VM_PERM_USER_DATA)) != 0 {
        uartPuts("panic: address_space_map failed\n")
        while true {}
    }

    UnsafeMutableRawPointer(bitPattern: p1)!.storeBytes(of: UInt64(0xA5A5_0001), as: UInt64.self)
    UnsafeMutableRawPointer(bitPattern: p2)!.storeBytes(of: UInt64(0xB6B6_0002), as: UInt64.self)

    address_space_switch(as1)
    let seenIn1 = UnsafeMutableRawPointer(bitPattern: va)!.load(as: UInt64.self)
    address_space_switch(as2)
    let seenIn2 = UnsafeMutableRawPointer(bitPattern: va)!.load(as: UInt64.self)
    address_space_switch(mmu_kernel_ttbr0())

    if seenIn1 != 0xA5A5_0001 || seenIn2 != 0xB6B6_0002 {
        uartPuts("panic: address space isolation broken\n")
        while true {}
    }
    if address_space_translate(as1, va) != p1 || address_space_translate(as2, va) != p2 {
        uartPuts("panic: address_space_translate mismatch\n")
        while true {}
    }

    uartPuts("M4.5 AS: per-process isolation OK\n")
}

private func kernelThreadBody(_ arg: UInt) {
    var i: UInt64 = 0
    while i < 3 {
        uartPuts("M4.5 thread ")
        uartPutUInt(UInt64(arg))
        uartPuts(" iter ")
        uartPutUInt(i)
        uartPuts("\n")
        schedYield()
        i += 1
    }
}

private let kernelThreadEntry: @convention(c) (UInt) -> Void = kernelThreadBody

private func runSchedulerDemo() {
    uartPuts("swift-os M4.5: real kernel threads\n")
    let a = threadCreate(kernelThreadEntry, 1)
    let b = threadCreate(kernelThreadEntry, 2)
    if a < 0 || b < 0 {
        uartPuts("panic: threadCreate failed\n")
        while true {}
    }

    // Hand the CPU to the new threads; control returns here once both finish.
    schedYield()

    if schedAllThreadsDone() {
        uartPuts("M4.5 sched: real context switch OK\n")
    } else {
        uartPuts("panic: scheduler demo did not complete\n")
        while true {}
    }
}

private func runProcessDemo() {
    uartPuts("swift-os M6: load + run static ELF at EL0\n")
    let (p, n, argc) = packArgs(["hello"])
    let code = processRunElf(hello_elf_addr(), UInt(hello_elf_len()), packed: p, packedLen: n, argc: argc)
    uartPuts("M6 OK: ELF process exited, code ")
    uartPutUInt(UInt64(code))
    uartPuts("\n")
}

private func runArgvDemo() {
    uartPuts("swift-os M8a: argv/argc to EL0\n")
    let (p, n, argc) = packArgs(["argvdemo", "alpha", "beta"])
    let code = processRunElf(argvdemo_elf_addr(), UInt(argvdemo_elf_len()), packed: p, packedLen: n, argc: argc)
    uartPuts("M8a OK: argv delivered, argc=")
    uartPutUInt(UInt64(code))
    uartPuts("\n")
}

private func runSpawnDemo() {
    uartPuts("swift-os M8a: spawn a child from EL0\n")
    let (p, n, argc) = packArgs(["spawndemo"])
    let code = processRunElf(spawndemo_elf_addr(), UInt(spawndemo_elf_len()), packed: p, packedLen: n, argc: argc)
    uartPuts("M8a OK: spawn parent exited, code ")
    uartPutUInt(UInt64(code))
    uartPuts("\n")
}

private func runFsDemo() {
    uartPuts("swift-os M8b: VFS (dirs, stat, getdents, cwd, tmpfs)\n")
    let (p, n, argc) = packArgs(["fsdemo"])
    let code = processRunElf(fsdemo_elf_addr(), UInt(fsdemo_elf_len()), packed: p, packedLen: n, argc: argc)
    uartPuts("M8b OK: VFS demo exited, code ")
    uartPutUInt(UInt64(code))
    uartPuts("\n")
}

private func runTtyDemo() {
    uartPuts("swift-os M7: interactive tty + signals\n")
    let (p, n, argc) = packArgs(["ttydemo"])
    let code = processRunElf(ttydemo_elf_addr(), UInt(ttydemo_elf_len()), packed: p, packedLen: n, argc: argc)
    if processLastKilledBySignal() {
        uartPuts("M7 OK: foreground interrupted by Ctrl-C (SIGINT), status ")
    } else {
        uartPuts("M7: tty process exited, code ")
    }
    uartPutUInt(UInt64(code))
    uartPuts("\n")
}

@_cdecl("exception_handler")
func exceptionHandler() {
    uartPuts("panic: unexpected EL1 exception\n")
    uartPuts("  ESR_EL1=")
    uartPutHex(UInt(read_esr_el1()))
    uartPuts("\n  ELR_EL1=")
    uartPutHex(UInt(read_elr_el1()))
    uartPuts("\n  FAR_EL1=")
    uartPutHex(UInt(read_far_el1()))
    uartPuts("\n  SCTLR_EL1=")
    uartPutHex(UInt(read_sctlr_el1()))
    uartPuts("\n  CPACR_EL1=")
    uartPutHex(UInt(read_cpacr_el1()))
    uartPuts("\n")
    while true {}
}

@_cdecl("irq_handler")
func irqHandler() {
    let iar = gicAcknowledge()
    let interruptId = iar & 0x3FF

    if interruptId == physicalTimerIrq {
        timerHandleTick()
    } else if interruptId == uartIrqId {
        uartHandleRx()
    } else if interruptId != gicSpuriousInterrupt {
        uartPuts("unexpected IRQ ")
        uartPutUInt(UInt64(interruptId))
        uartPuts("\n")
    }

    if interruptId != gicSpuriousInterrupt {
        gicEndInterrupt(iar)
    }

    // Everything below runs after the EOI so a context switch / process
    // termination never leaves an interrupt active at the GIC.
    if interruptId == physicalTimerIrq {
        schedulerTick()
    } else if interruptId == uartIrqId {
        signalDeliverToForeground() // Ctrl-C → SIGINT; may terminate the process
    }
}

@_cdecl("sync_lower_el_aarch64_handler")
func syncLowerELAArch64Handler(_ framePointer: UnsafeMutableRawPointer) {
    let esr = read_esr_el1()
    let exceptionClass = (esr >> 26) & 0x3F
    if exceptionClass == 0x15 {
        let frame = framePointer.assumingMemoryBound(to: UInt.self)
        syscallDispatch(number: frame[8], frame: frame)
        return
    }

    uartPuts("panic: unexpected lower-EL sync exception\n")
    uartPuts("  ESR_EL1=")
    uartPutHex(UInt(esr))
    uartPuts("\n  ELR_EL1=")
    uartPutHex(UInt(read_elr_el1()))
    uartPuts("\n  FAR_EL1=")
    uartPutHex(UInt(read_far_el1()))
    uartPuts("\n")
    while true {}
}

/// Kernel entry point, called from the boot stub. Must never return.
@_cdecl("kernel_main")
func kernelMain() {
    uartPuts("Hello from Swift kernel\n")
    uartPuts("swift-os M0: boot skeleton up on QEMU virt (aarch64, EL1)\n")
    uartPuts("swift-os M1: runtime and memory init\n")

    swiftos_heap_init()
    pmmInit()
    if let raw = swiftos_kernel_alloc(32, 16) {
        raw.storeBytes(of: UInt64(0xC0DEFACE_CAFEBEEF), as: UInt64.self)
    } else {
        uartPuts("panic: kernelAlloc failed\n")
        while true {}
    }
    uartPuts("M1 probe: raw heap allocation ok\n")

    let swiftRaw = UnsafeMutableRawPointer.allocate(byteCount: 24, alignment: 16)
    swiftRaw.storeBytes(of: UInt64(0x1234_5678_90AB_CDEF), as: UInt64.self)
    swiftRaw.deallocate()
    uartPuts("M1 probe: Swift raw allocation hook ok\n")

    let probe = HeapProbe(13, 29)
    if probe.sum() != 42 {
        uartPuts("panic: Swift class heap probe failed\n")
        while true {}
    }
    retainedProbe = probe
    uartPuts("M1 probe: Swift class allocation ok\n")

    uartPuts("M1 OK: heap, ARC class, exception vectors\n")
    uartPuts("heap used: ")
    uartPutHex(swiftos_kernel_heap_used_bytes())
    uartPuts("\n")

    runVirtualMemoryProbe()
    runAddressSpaceProbe()

    uartPuts("swift-os M2: enabling GIC and generic timer\n")
    gicInit()
    timerInit(ticksPerSecond: 4)
    schedulerInit()
    processInit()
    vfsInit()
    ttyInit()
    signalReset()
    uartRxInit()
    enable_irq()

    runSchedulerDemo()

    runProcessDemo()

    runArgvDemo()

    runSpawnDemo()

    runFsDemo()

    runTtyDemo()

    userProcessStart()

    while true {
        // Wake on timer IRQ.
        wfi()
    }
}
