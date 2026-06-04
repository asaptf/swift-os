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

    guard let rawPage = swiftos_kernel_alloc(4096, 4096) else {
        uartPuts("panic: VM probe page allocation failed\n")
        while true {}
    }

    let physicalPage = UInt(bitPattern: rawPage)
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
    } else if interruptId != gicSpuriousInterrupt {
        uartPuts("unexpected IRQ ")
        uartPutUInt(UInt64(interruptId))
        uartPuts("\n")
    }

    if interruptId != gicSpuriousInterrupt {
        gicEndInterrupt(iar)
    }
}

/// Kernel entry point, called from the boot stub. Must never return.
@_cdecl("kernel_main")
func kernelMain() {
    uartPuts("Hello from Swift kernel\n")
    uartPuts("swift-os M0: boot skeleton up on QEMU virt (aarch64, EL1)\n")
    uartPuts("swift-os M1: runtime and memory init\n")

    swiftos_heap_init()
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

    uartPuts("swift-os M2: enabling GIC and generic timer\n")
    gicInit()
    timerInit(ticksPerSecond: 4)
    enable_irq()

    while true {
        // Wake on timer IRQ.
        wfi()
    }
}
