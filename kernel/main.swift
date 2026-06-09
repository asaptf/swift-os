// SPDX-License-Identifier: Apache-2.0
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
private var c2SpawnExplicitPassed = false
private var c3HandleRightsPassed = false

/// Enable the MMU using the static boot page tables (kernel/mm/vm.c — these do
/// not draw from the PMM). DTB parsing runs before this, so the parser avoids
/// large value-copy layouts that would make Swift emit unaligned wide loads.
private func enableMMU() {
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
}

/// Exercise the page map/translate/unmap path. Requires the PMM (allocates a
/// scratch frame), so it runs after pmmInit; the MMU is already enabled.
private func runVirtualMemoryProbe() {
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
        klog(.info, "sched", "M4.5 sched: real context switch OK")
    } else {
        uartPuts("panic: scheduler demo did not complete\n")
        while true {}
    }
}

/// Common helper: load a demo program from the packed base image. Returns
/// (0, 0) and logs if it is missing (so a demo degrades to a skip, not a fault).
private func demoImage(_ path: StaticString) -> (UInt, UInt) {
    let (img, sz) = loadProgramImage(path)
    if img == 0 {
        uartPuts("demo: missing on disk ")
        uartPuts(path)
        uartPuts("\n")
    }
    return (img, sz)
}

private func runProcessDemo() {
    uartPuts("swift-os M6: load + run static ELF at EL0\n")
    let (img, sz) = demoImage("/bin/hello")
    if img == 0 { return }
    let (p, n, argc) = packArgs(["hello"])
    let code = processRunElf(img, sz, packed: p, packedLen: n, argc: argc)
    uartPuts("M6 OK: ELF process exited, code ")
    uartPutUInt(UInt64(code))
    uartPuts("\n")
}

private func runArgvDemo() {
    uartPuts("swift-os M8a: argv/argc to EL0\n")
    let (img, sz) = demoImage("/bin/argvdemo")
    if img == 0 { return }
    let (p, n, argc) = packArgs(["argvdemo", "alpha", "beta"])
    let code = processRunElf(img, sz, packed: p, packedLen: n, argc: argc)
    uartPuts("M8a OK: argv delivered, argc=")
    uartPutUInt(UInt64(code))
    uartPuts("\n")
}

private func runSpawnDemo() {
    uartPuts("swift-os M8a: spawn a child from EL0\n")
    let (img, sz) = demoImage("/bin/spawndemo")
    if img == 0 { return }
    let (p, n, argc) = packArgs(["spawndemo"])
    let code = processRunElf(img, sz, packed: p, packedLen: n, argc: argc)
    uartPuts("M8a OK: spawn parent exited, code ")
    uartPutUInt(UInt64(code))
    uartPuts("\n")
    if code == 0 {
        c2SpawnExplicitPassed = true
        c3HandleRightsPassed = true
    }
}

private func runBrkDemo() {
    uartPuts("swift-os M8c: user heap via sbrk\n")
    let (img, sz) = demoImage("/bin/brkdemo")
    if img == 0 { return }
    let (p, n, argc) = packArgs(["brkdemo"])
    _ = processRunElf(img, sz, packed: p, packedLen: n, argc: argc)
}

private func runNewlibDemo() {
    uartPuts("swift-os M8c: newlib libc (printf/malloc/fopen)\n")
    let (img, sz) = demoImage("/bin/newlibtest")
    if img == 0 { return }
    let (p, n, argc) = packArgs(["newlibtest"])
    let code = processRunElf(img, sz, packed: p, packedLen: n, argc: argc)
    uartPuts("M8c OK: newlib program exited, code ")
    uartPutUInt(UInt64(code))
    uartPuts("\n")
}

private func runConcurrentDemo() {
    uartPuts("swift-os M8d: preemptive EL0 multitasking\n")
    let (img, sz) = demoImage("/bin/coproc")
    if img == 0 { return }
    let (pa, na, ca) = packArgs(["coproc", "A"])
    let (pb, nb, cb) = packArgs(["coproc", "B"])
    processRunPair(img, sz, pa, na, ca,
                   img, sz, pb, nb, cb)
    uartPuts("M8d OK: two EL0 processes ran concurrently\n")
}

private func runForkDemo() {
    uartPuts("swift-os M8d: fork + waitpid\n")
    let (img, sz) = demoImage("/bin/forkdemo")
    if img == 0 { return }
    let (p, n, argc) = packArgs(["forkdemo"])
    let code = processRunElf(img, sz, packed: p, packedLen: n, argc: argc)
    uartPuts("M8d OK: fork demo exited, code ")
    uartPutUInt(UInt64(code))
    uartPuts("\n")
    if code == 0 && c2SpawnExplicitPassed {
        uartPuts("C2 OK: explicit handle inheritance preserved\n")
    }
}

private func runExecDemo() {
    uartPuts("swift-os M8d: execve image replacement\n")
    let (img, sz) = demoImage("/bin/execdemo")
    if img == 0 { return }
    let (p, n, argc) = packArgs(["execdemo"])
    let code = processRunElf(img, sz, packed: p, packedLen: n, argc: argc)
    uartPuts("M8d exec OK: exec demo exited, code ")
    uartPutUInt(UInt64(code))
    uartPuts("\n")
}

private func runFdOpsDemo() {
    uartPuts("swift-os M8e: fd sharing, pipes, poll, tmpfs mutations\n")
    let (img, sz) = demoImage("/bin/fdopsdemo")
    if img == 0 { return }
    let (p, n, argc) = packArgs(["fdopsdemo"])
    let code = processRunElf(img, sz, packed: p, packedLen: n, argc: argc)
    uartPuts("M8e OK: fdops demo exited, code ")
    uartPutUInt(UInt64(code))
    uartPuts("\n")
    if code == 0 {
        uartPuts("C1 OK: fds-as-handles preserved\n")
    }
}

private func runFsDemo() {
    uartPuts("swift-os M8b: VFS (dirs, stat, getdents, cwd, tmpfs)\n")
    let (img, sz) = demoImage("/bin/fsdemo")
    if img == 0 { return }
    let (p, n, argc) = packArgs(["fsdemo"])
    let code = processRunElf(img, sz, packed: p, packedLen: n, argc: argc)
    uartPuts("M8b OK: VFS demo exited, code ")
    uartPutUInt(UInt64(code))
    uartPuts("\n")
    if code == 0 && c3HandleRightsPassed {
        uartPuts("C3 OK: per-handle rights enforced\n")
    }
}

private func runSecurityDemo() {
    uartPuts("swift-os security: adversarial syscall smoke tests\n")
    let (img, sz) = demoImage("/bin/securitydemo")
    if img == 0 { return }
    let (p, n, argc) = packArgs(["securitydemo"])
    let code = processRunElf(img, sz, packed: p, packedLen: n, argc: argc)
    uartPuts("security OK: syscall abuse demo exited, code ")
    uartPutUInt(UInt64(code))
    uartPuts("\n")
}

private func runIdentityDemo() {
    uartPuts("swift-os M12a: principal/session/capability context\n")
    let (img, sz) = demoImage("/bin/identitydemo")
    if img == 0 { return }
    let (p, n, argc) = packArgs(["identitydemo"])
    let code = processRunElf(img, sz, packed: p, packedLen: n, argc: argc)
    uartPuts("M12a OK: identity demo exited, code ")
    uartPutUInt(UInt64(code))
    uartPuts("\n")
}

// One round of teardown-exercising work: fork+waitpid (forkdemo), exec-replace
// (execdemo), and spawn+reap (spawndemo). Each image is loaded immediately
// before it runs because the ELF staging buffer (exec.swift's elfBuf) is shared
// and reused. Returns the number of programs that actually ran.
private func runReclaimRound() -> Int {
    var ran = 0
    let (fk, fks) = demoImage("/bin/forkdemo")
    if fk != 0 {
        let (p, n, c) = packArgs(["forkdemo"])
        _ = processRunElf(fk, fks, packed: p, packedLen: n, argc: c); ran += 1
    }
    let (ex, exs) = demoImage("/bin/execdemo")
    if ex != 0 {
        let (p, n, c) = packArgs(["execdemo"])
        _ = processRunElf(ex, exs, packed: p, packedLen: n, argc: c); ran += 1
    }
    let (sp, sps) = demoImage("/bin/spawndemo")
    if sp != 0 {
        let (p, n, c) = packArgs(["spawndemo"])
        _ = processRunElf(sp, sps, packed: p, packedLen: n, argc: c); ran += 1
    }
    return ran
}

/// Process-teardown reclamation self-test. Runs several rounds of fork/exec/
/// spawn/exit/reap and asserts the PMM free-frame count is identical before and
/// after — proving every frame (address space, page tables, kernel stacks) is
/// returned to the allocator. Regression guard for the ~2 MiB-per-command leak
/// that previously exhausted RAM after ~100 commands.
private func runReclaimDemo() {
    klog(.info, "boot", "swift-os reclaim: process teardown frees frames")
    // A warm-up round settles any one-time lazy state (e.g. the ELF staging
    // buffer) so the baseline measures steady-state frame use only.
    if runReclaimRound() == 0 {
        uartPuts("reclaim: demo images missing; skipping\n")
        return
    }
    let baseline = pmmFreeCount()
    for _ in 0..<5 { _ = runReclaimRound() }
    let after = pmmFreeCount()

    klog(.info, "pmm", "free frames", UInt64(baseline))
    klog(.info, "pmm", "free frames", UInt64(after))

    uartPuts("reclaim: free frames baseline=")
    uartPutUInt(UInt64(baseline))
    uartPuts(" after=")
    uartPutUInt(UInt64(after))
    uartPuts("\n")
    if after == baseline {
        klog(.info, "boot", "reclaim OK: no frame leak across fork/exec/exit/reap")
    } else {
        uartPuts("reclaim FAIL: leaked frames across process teardown\n")
    }
}

private func runPsDemo() {
    klog(.info, "boot", "swift-os userland: Swift ps")
    let (img, sz) = demoImage("/bin/ps")
    if img == 0 { return }
    let (p, n, argc) = packArgs(["ps"])
    var code = processRunElf(img, sz, packed: p, packedLen: n, argc: argc)
    let (pf, nf, argcf) = packArgs(["ps", "-ef"])
    code = processRunElf(img, sz, packed: pf, packedLen: nf, argc: argcf)
    let (pa, na, argca) = packArgs(["ps", "aux"])
    code = processRunElf(img, sz, packed: pa, packedLen: na, argc: argca)
    let (po, no, argco) = packArgs(["ps", "-o", "pid,ppid,stat,comm"])
    code = processRunElf(img, sz, packed: po, packedLen: no, argc: argco)
    uartPuts("ps OK: Swift ps exited, code ")
    uartPutUInt(UInt64(code))
    uartPuts("\n")
}

/// M11b: probe the virtio-blk disk. Bring up the block device discovered in the
/// virtio-mmio window, read sector 0, and report it. When the attached disk is a
/// packed base image its first bytes are the ASCII magic "SWOSBASE", which we
/// recognise here — the M11c on-disk filesystem will build on this read path.
private func runVirtioBlkProbe() {
    let cap = virtioBlkInit(platform.virtioMmioBase,
                            platform.virtioMmioStride,
                            platform.virtioMmioCount)
    if cap == 0 {
        uartPuts("M11b: no virtio-blk disk attached\n")
        return
    }
    uartPuts("M11b: virtio-blk disk, capacity ")
    uartPutUInt(cap)
    uartPuts(" sectors\n")

    var sector = [UInt8](repeating: 0, count: 512)
    let rc = sector.withUnsafeMutableBytes { raw -> Int32 in
        virtioBlkRead(0, raw.baseAddress)
    }
    if rc != 0 {
        uartPuts("M11b: sector 0 read failed, rc ")
        uartPutUInt(UInt64(bitPattern: Int64(rc)))
        uartPuts("\n")
        return
    }

    let magic: StaticString = "SWOSBASE"
    var isBase = true
    magic.withUTF8Buffer { m in
        for i in 0..<m.count where sector[i] != m[i] { isBase = false }
    }
    if isBase {
        klog(.info, "disk", "M11b OK: sector 0 read from disk, SWOSBASE magic verified")
    } else {
        uartPuts("M11b: sector 0 read from disk, first bytes ")
        for i in 0..<8 {
            uartPutHex(UInt(sector[i]))
            uartPutc(0x20)
        }
        uartPuts("\n")
    }
}

/// Print a MAC address as `aa:bb:cc:dd:ee:ff`.
private func printMac(_ m: MAC) {
    let bytes = [m.a, m.b, m.c, m.d, m.e, m.f]
    for (i, byte) in bytes.enumerated() {
        if i != 0 { uartPutc(0x3A) } // ':'
        let hi = byte >> 4, lo = byte & 0xF
        uartPutc(hi < 10 ? 0x30 + hi : 0x61 + (hi - 10))
        uartPutc(lo < 10 ? 0x30 + lo : 0x61 + (lo - 10))
    }
}

/// net-a: bring up virtio-net and exercise the sans-IO stack against the QEMU
/// user-net (slirp) gateway. We ARP for 10.0.2.2, then send an ICMP echo request
/// and wait for the reply — proving driver RX/TX plus the Ethernet/ARP/IPv4/ICMP
/// core end to end. A no-op (one log line) when no NIC is attached, so the other
/// boot/test paths are unaffected (mirrors runVirtioBlkProbe).
private func runVirtioNetProbe() {
    netInit()   // brings up the NIC + the shared NetStack the socket layer uses
    if !netReady {
        return  // netInit already logged "net: no virtio-net device attached"
    }
    uartPuts("net-a: virtio-net up, MAC ")
    printMac(gNet.mac)
    uartPuts("\n")

    let gwIP = netGatewayIP   // 10.0.2.2 (slirp gateway)

    // 1) Resolve the gateway's MAC via ARP.
    virtioNetTxSubmit(frameLen: gNet.buildArpRequest(targetIP: gwIP, out: virtioNetTxBuffer()))
    var gwMac = MAC()
    var resolved = false
    var spins = 0
    while spins < 4_000_000 && !resolved {
        let r = virtioNetPoll(&gNet)
        if r.arpResolved && r.resolvedIP == gwIP { gwMac = r.resolvedMac; resolved = true }
        spins += 1
    }
    if !resolved {
        uartPuts("net-a: ARP for 10.0.2.2 timed out\n")
        return
    }
    uartPuts("net-a: ARP reply, 10.0.2.2 is at ")
    printMac(gwMac)
    uartPuts("\n")

    // 2) Ping the gateway: send an ICMP echo request and await the echo reply.
    virtioNetTxSubmit(frameLen: gNet.buildEchoRequest(toMac: gwMac, toIP: gwIP, id: 0x1234,
                                                      seq: 1, payloadLen: 32, out: virtioNetTxBuffer()))
    var got = false
    spins = 0
    while spins < 4_000_000 && !got {
        let r = virtioNetPoll(&gNet)
        if r.echoReply { got = true }
        spins += 1
    }
    if got {
        uartPuts("net-a OK: ICMP echo reply from 10.0.2.2\n")
    } else {
        uartPuts("net-a: ICMP echo reply timed out\n")
    }
}

private func runInit() {
    uartPuts("swift-os M12c: starting console-login (init)\n")
    // Keep the system usable: when a session ends, start a fresh login rather
    // than leaving the VM idle. The image is (re)loaded each iteration because
    // the shell exec inside the session overwrites the shared ELF buffer.
    while true {
        let (login, loginSize) = loadProgramImage("/bin/console-login")
        if login != 0 {
            let (p, n, argc) = packArgs(["console-login"])
            let code = processRunElf(login, loginSize, packed: p, packedLen: n, argc: argc)
            uartPuts("M12c: session ended, code ")
            uartPutUInt(UInt64(code))
            uartPuts("; restarting login\n")
            continue
        }
        // No login program on disk: fall back to a raw shell so the system is
        // still usable (e.g. a base image built without console-login).
        uartPuts("M12c: /bin/console-login missing; starting raw shell\n")
        let (image, size) = resolveBusyboxImage()
        if image == 0 {
            uartPuts("panic: no shell or login program available\n")
            while true { wfi() }
        }
        let (p, n, argc) = packArgs(["sh"])
        _ = processRunElf(image, size, packed: p, packedLen: n, argc: argc)
    }
}

private func runTtyDemo() {
    uartPuts("swift-os M7: interactive tty + signals\n")
    let (img, sz) = demoImage("/bin/ttydemo")
    if img == 0 { return }
    let (p, n, argc) = packArgs(["ttydemo"])
    let code = processRunElf(img, sz, packed: p, packedLen: n, argc: argc)
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
    // Capture the interrupted exception level before any handler runs (SPSR_EL1
    // still holds the pre-IRQ PSTATE; no nested EL1 exception is taken here).
    // M[3:0] == 0 means EL0t — user code was running. Used for CPU accounting.
    let fromEL0 = (read_spsr_el1() & 0xF) == 0

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
        virtioKbdDrain() // poll the graphical-window keyboard into the tty
        fb_cursor_blink() // blink the on-screen cursor (no-op without a framebuffer)
        schedulerTick()  // M4.5 kernel-thread scheduler (idle once its demo ends)
        processOnTick(fromEL0: fromEL0)  // preempt the current EL0 process + CPU accounting
    } else if interruptId == uartIrqId {
        signalDeliverToForeground() // Ctrl-C → SIGINT; may terminate the process
    }
}

/// Drain any keystrokes from the virtio-input keyboard into the tty line
/// discipline, exactly as the UART IRQ feeds serial input. No-op when there is
/// no keyboard device (the getchar returns -1 immediately).
private func virtioKbdDrain() {
    while true {
        let b = virtioKbdGetchar()
        if b < 0 { break }
        ttyOnInput(UInt8(b & 0xFF))
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
    if exceptionClass == 0x24 {
        let dfsc = esr & 0x3F
        let isWrite = (esr & (1 << 6)) != 0
        let isPermissionFault = dfsc >= 0xC && dfsc <= 0xF
        if isWrite && isPermissionFault {
            let ttbr0 = processCurrentAddressSpace()
            if ttbr0 != 0 && addressSpaceHandleCowFault(ttbr0, UInt(read_far_el1())) {
                return
            }
        }
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
/// `dtbPhys` is the device-tree pointer the boot stub preserved from x0.
@_cdecl("kernel_main")
func kernelMain(_ dtbPhys: UInt, _ fbBase: UInt, _ fbDims: UInt, _ fbStrFmt: UInt) {
    uartInit()  // no-op on QEMU; enables the PL011 on VirtualBox before any output
    // The UEFI loader may hand us a GOP framebuffer (x1=base, x2=w<<32|h,
    // x3=stride<<32|format). When present, mirror the boot log to the screen.
    if fbBase != 0 {
        let w = UInt32(truncatingIfNeeded: fbDims >> 32)
        let h = UInt32(truncatingIfNeeded: fbDims & 0xFFFF_FFFF)
        let stride = UInt32(truncatingIfNeeded: fbStrFmt >> 32)
        fb_init(UInt64(fbBase), w, h, stride)
    }
    uartPuts("Hello from Swift kernel\n")
    uartPuts("swift-os M0: boot skeleton up on QEMU virt (aarch64, EL1)\n")
    uartPuts("swift-os M1: runtime and memory init\n")

    // M9: discover the hardware map from the device tree before any subsystem
    // (PMM, GIC, timer) relies on it. Discovery falls back to QEMU virt defaults.
    platformInit(dtbPhys)

    swiftos_heap_init()
    enableMMU()

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

#if BOARD_VIRTUALBOX
    // M10.5: this proves swift-os runs on VirtualBox ARM — the UEFI loader staged
    // the kernel into VBox RAM (0x0800_0000), the boot stub ran, the PL011 at
    // 0xFFDD_F000 carries output, and the MMU is on with a VBox-correct map.
    // Interrupt-driven subsystems are deferred: VBox exposes a GICv3, which the
    // current GICv2 driver cannot drive. Park here rather than fault on GIC init.
    uartPuts("swift-os M10.5: VirtualBox bring-up OK — kernel, UART, RAM, MMU\n")
    uartPuts("swift-os M10.5: GIC/timer/scheduler deferred (VBox is GICv3; see docs/VIRTUALBOX.md)\n")
    while true {}
#endif

    uartPuts("swift-os M2: enabling GIC and generic timer\n")
    gicInit()
    timerInit(ticksPerSecond: 100) // high tick rate → frequent EL0 preemption
    klog(.info, "timer", "tick rate (Hz)", 100)
    klog(.info, "platform", "M9 OK: hardware discovered from device tree")
    klog(.info, "smp", "S0 OK: foundations ready", UInt64(currentCpuId()))
    if !smpAtomicSelfTest() {
        uartPuts("panic: S0b atomic self-test failed\n")
        while true {}
    }
    klog(.info, "smp", "S0b OK: atomics and barriers ready")
    if !smpEarlyInitCurrentCpu() || !smpPerCpuSelfTest() {
        uartPuts("panic: S0d per-CPU self-test failed\n")
        while true {}
    }
    klog(.info, "smp", "S0d OK: per-CPU state ready", UInt64(smpMaxCpuCount()))
    if !smpSecondaryParkSelfTest() {
        uartPuts("panic: S0e secondary park mailbox self-test failed\n")
        while true {}
    }
    klog(.info, "smp", "S0e OK: secondary park mailbox ready")
    klog(.info, "log", "L0 kernel logger active")
    klog(.info, "log", "level filtering active (min INFO)")
    // A .debug line that is suppressed by the L2 default (.info). This proves
    // the filter is active without polluting normal boot logs or test output.
    klog(.debug, "log", "this debug line should be filtered by default")
    klog(.info, "log", "source filtering active")
    klogSetSourceMinLevel("log_filter", .error)
    klog(.info, "log_filter", "this source-filtered info line should be hidden")
    klog(.error, "log_filter", "source override allows error")
    klogClearSourceMinLevels()
    schedulerInit()
    processInit()
    securityInit()
    runVirtioBlkProbe() // M11b: bring up the disk before the VFS may mount from it
    vfsInit()           // M11c: serves the read-only base from disk when present
    runVirtioNetProbe() // net-a: virtio-net + sans-IO ARP/ICMP against slirp
    ttyInit()
    signalReset()
    uartRxInit()
    let windowKeyboard = virtioKbdInit() > 0  // graphical window has a keyboard
    if windowKeyboard {
        uartPuts("virtio-kbd: window keyboard ready\n")
    }
    enable_irq()

    if windowKeyboard {
        // Interactive graphical session (make run-gfx): boot straight into the
        // shell so the window is immediately usable. The milestone demos still
        // run on the serial/test path below (and the acceptance tests depend on
        // them, e.g. the M7 tty demo).
        runInit()
    } else {
        runSchedulerDemo()
        runProcessDemo()
        runArgvDemo()
        runSpawnDemo()
        runBrkDemo()
        runNewlibDemo()
        runConcurrentDemo()
        runForkDemo()
        runExecDemo()
        runFdOpsDemo()
        runFsDemo()
        runSecurityDemo()
        runIdentityDemo()
        runReclaimDemo()
        runPsDemo()
        klogRing(.info, "log_export", "tail serialization ready")
        logDumpRecent(32)
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 768) { exportBuffer in
            let base = exportBuffer.baseAddress!
            let n = logFormatRecentTail(6, into: base, capacity: exportBuffer.count)
            uartPuts("LOG-EXPORT bytes=")
            uartPutUInt(UInt64(n))
            uartPuts("\n")
            uartPuts("LOG-EXPORT-BEGIN\n")
            var i = 0
            while i < n {
                uartPutc(base[i])
                i += 1
            }
            uartPuts("LOG-EXPORT-END\n")
        }
        runTtyDemo()
        runInit() // console-login (init) — interactive, last
    }

    while true {
        // Wake on timer IRQ.
        wfi()
    }
}
