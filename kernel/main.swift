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
private var c4aEndpointRightsPassed = false

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
        c4aEndpointRightsPassed = true
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

private func runConcurrentDemo() -> Bool {
    uartPuts("swift-os M8d: preemptive EL0 multitasking\n")
    let (img, sz) = demoImage("/bin/coproc")
    if img == 0 { return false }
    let (pa, na, ca) = packArgs(["coproc", "A"])
    let (pb, nb, cb) = packArgs(["coproc", "B"])
    processRunPair(img, sz, pa, na, ca,
                   img, sz, pb, nb, cb)
    uartPuts("M8d OK: two EL0 processes ran concurrently\n")
    return true
}

private func runS5bPlacementDemo() -> Bool {
    uartPuts("swift-os S5b: EL0 scheduler placement batch\n")
    let (img, sz) = demoImage("/bin/coproc")
    if img == 0 { return false }
    let (pa, na, ca) = packArgs(["coproc", "S5b-A"])
    let (pb, nb, cb) = packArgs(["coproc", "S5b-B"])
    let (pc, nc, cc) = packArgs(["coproc", "S5b-C"])
    processRunS5bPlacementBatch(img, sz, pa, na, ca,
                                pb, nb, cb,
                                pc, nc, cc)
    uartPuts("S5b OK: three EL0 processes ran with scheduler placement\n")
    return true
}

private func runS5cPlacementStressDemo() -> Bool {
    uartPuts("swift-os S5c: repeated EL0 scheduler placement stress\n")
    let (img, sz) = demoImage("/bin/coproc")
    if img == 0 { return false }
    let (primaryPacked, primaryPackedLen, primaryArgc) = packArgs(["coproc", "S5c-P"])
    let (secondaryPacked, secondaryPackedLen, secondaryArgc) = packArgs(["coproc", "S5c-S"])
    let (tailPacked, tailPackedLen, tailArgc) = packArgs(["coproc", "S5c-T"])
    processRunS5cPlacementStress(img, sz,
                                 primaryPacked, primaryPackedLen, primaryArgc,
                                 secondaryPacked, secondaryPackedLen, secondaryArgc,
                                 tailPacked, tailPackedLen, tailArgc)
    uartPuts("S5c OK: repeated EL0 placement stress completed\n")
    return true
}

private func runS5dFanoutDemo() -> Bool {
    uartPuts("swift-os S5d: EL0 fanout across scheduler CPUs\n")
    let (img, sz) = demoImage("/bin/coproc")
    if img == 0 { return false }
    let (packed, packedLen, argc) = packArgs(["coproc", "S5d"])
    processRunS5dFanout(img, sz, packed, packedLen, argc)
    uartPuts("S5d OK: EL0 fanout ran across scheduler CPUs\n")
    return true
}

private func runS5eThreadFanoutDemo() -> Bool {
    uartPuts("swift-os S5e: shared-address-space thread fanout\n")
    let (img, sz) = demoImage("/bin/threadsdemo")
    if img == 0 { return false }
    let (packed, packedLen, argc) = packArgs(["threadsdemo"])
    let code = processRunS5eThreadFanout(img, sz, packed, packedLen, argc)
    if code != 0 {
        uartPuts("panic: S5e thread fanout exited nonzero\n")
        while true {}
    }
    uartPuts("S5e OK: shared-address-space thread fanout completed\n")
    return true
}

private func runS5fRunAnyPlacementDemo() -> Bool {
    uartPuts("swift-os S5f: run-any EL0 placement policy\n")
    let (img, sz) = demoImage("/bin/coproc")
    if img == 0 { return false }
    let (packed, packedLen, argc) = packArgs(["coproc", "S5f"])
    processRunS5fRunAnyPlacement(img, sz, packed, packedLen, argc)
    uartPuts("S5f OK: run-any placement policy completed\n")
    return true
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
    if code == 0 && c4aEndpointRightsPassed {
        uartPuts("C4a OK: endpoint IPC moved handles safely\n")
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

private func runDriverServiceDemo() {
    uartPuts("swift-os C5a: restartable driver-service supervisor\n")
    let (img, sz) = demoImage("/bin/drvsvcdemo")
    if img == 0 { return }
    let (p, n, argc) = packArgs(["drvsvcdemo"])
    let code = processRunElf(img, sz, packed: p, packedLen: n, argc: argc)
    uartPuts("C5a driver service demo exited, code ")
    uartPutUInt(UInt64(code))
    uartPuts("\n")
}

// LA1: the persistent native-Swift supervisor + UserlandService successor to the
// C5 demo. Runs after the C5 demo releases the input device. Bounded generations
// so it doubles as a boot self-test; the supervisor exits with the LA1 OK marker.
private func runUserlandServiceDemo() {
    uartPuts("swift-os LA1: persistent Swift supervisor + userland service\n")
    let (img, sz) = demoImage("/bin/svc-supervisor")
    if img == 0 { return }
    let (p, n, argc) = packArgs(["svc-supervisor"])
    let code = processRunElf(img, sz, packed: p, packedLen: n, argc: argc)
    uartPuts("LA1 supervisor demo exited, code ")
    uartPutUInt(UInt64(code))
    uartPuts("\n")
}

// LA2: device-MMIO-map authority probe. Runs as a capConsole boot principal:
// claims the mappable virtio-input window, maps it via sys_device_mmap, and reads
// the virtio identification registers through the Device-nGnRE mapping to prove
// the path is live. Also exercises the EACCES refusal on the metadata-only
// sibling grant. No-ops cleanly on boards without a virtio-input window.
private func runDeviceMmioMapProbe() {
    uartPuts("swift-os LA2: device MMIO map authority probe\n")
    let (img, sz) = demoImage("/bin/devicemmapprobe")
    if img == 0 { return }
    let (p, n, argc) = packArgs(["devicemmapprobe"])
    let code = processRunElf(img, sz, packed: p, packedLen: n, argc: argc)
    uartPuts("LA2 device mmap probe exited, code ")
    uartPutUInt(UInt64(code))
    uartPuts("\n")
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

/// QW3 orphan-zombie reaper self-test. Repeatedly builds the orphan scenario — a
/// parent forks a child and exits without waiting, so the child is reparented to
/// the kernel and later exits with no waiter — and asserts that live process
/// slots, PMM frames, and endpoint slots all return to baseline. Before the fix,
/// each round permanently leaked the orphan's zombie slot (and its frames); after
/// the fix the kernel collects it. A leak that prevented collection would instead
/// hang the round's scheduler wait, which the test driver catches via timeout.
private func runOrphanReapDemo() {
    klog(.info, "boot", "swift-os orphan-reap: kernel collects orphaned-child zombies")
    let (img, sz) = demoImage("/bin/orphandemo")
    if img == 0 {
        uartPuts("orphan-reap: demo image missing; skipping\n")
        return
    }
    let (p, n, c) = packArgs(["orphandemo"])
    // Warm-up round settles one-time lazy state so the baseline is steady-state.
    if !processOrphanReapRound(img, sz, packed: p, packedLen: n, argc: c) {
        uartPuts("orphan-reap FAIL: could not launch warm-up round\n")
        return
    }
    let baseSlots = processLiveSlotCount()
    let baseFrames = pmmFreeCount()
    let baseEndpoints = vfsEndpointInUseCount()
    // 20 rounds exceeds both the 16-slot process table and the 16-slot endpoint
    // table, so any per-round slot leak would exhaust a table (round launch
    // fails) well before the count comparison.
    var launched = true
    for _ in 0..<20 {
        if !processOrphanReapRound(img, sz, packed: p, packedLen: n, argc: c) {
            launched = false
            break
        }
    }
    let afterSlots = processLiveSlotCount()
    let afterFrames = pmmFreeCount()
    let afterEndpoints = vfsEndpointInUseCount()

    uartPuts("orphan-reap: slots base=")
    uartPutUInt(UInt64(baseSlots))
    uartPuts(" after=")
    uartPutUInt(UInt64(afterSlots))
    uartPuts(" frames base=")
    uartPutUInt(UInt64(baseFrames))
    uartPuts(" after=")
    uartPutUInt(UInt64(afterFrames))
    uartPuts(" endpoints base=")
    uartPutUInt(UInt64(baseEndpoints))
    uartPuts(" after=")
    uartPutUInt(UInt64(afterEndpoints))
    uartPuts("\n")

    if launched && afterSlots == baseSlots && afterFrames == baseFrames
       && afterEndpoints == baseEndpoints {
        uartPuts("orphan-reap OK: no zombie slot leak across orphan churn\n")
    } else {
        uartPuts("orphan-reap FAIL: leaked slot/frame/endpoint across orphan churn\n")
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

/// D0: bring the persistent "data" disk into play. Independent of the read-only
/// base/store, this is a writable virtio-blk device (sector-0 magic "SWDATAFS")
/// that will host the /data tier (datafs, D1+). Here we only prove end-to-end
/// persistence: read a boot counter near the start of the disk, increment it,
/// write it back, and flush. The counter surviving across reboots is the D0
/// acceptance (tests/data_persist_test.sh).
private func runDataDeviceProbeD0() {
    if !virtioBlkDataAvailable() {
        uartPuts("D0: no data disk attached\n")
        return
    }
    uartPuts("D0: data device, ")
    uartPutUInt(virtioBlkDataCapacitySectors())
    uartPuts(" sectors\n")

    // Boot counter at a fixed byte offset (sector 2), clear of the D1 superblock.
    let counterOff: UInt64 = 1024
    var buf = [UInt8](repeating: 0, count: 8)
    let rrc = buf.withUnsafeMutableBytes { raw -> Int32 in
        virtioBlkDataReadRange(counterOff, raw.baseAddress, 8)
    }
    if rrc != 0 {
        uartPuts("D0: data read failed, rc ")
        uartPutUInt(UInt64(bitPattern: Int64(rrc)))
        uartPuts("\n")
        return
    }
    var count: UInt64 = 0
    var k = 0
    while k < 8 { count |= UInt64(buf[k]) << (8 * UInt64(k)); k += 1 }
    count &+= 1
    k = 0
    while k < 8 { buf[k] = UInt8((count >> (8 * UInt64(k))) & 0xFF); k += 1 }
    let wrc = buf.withUnsafeBytes { raw -> Int32 in
        virtioBlkDataWriteRange(counterOff, raw.baseAddress, 8)
    }
    if wrc != 0 {
        uartPuts("D0: data write failed, rc ")
        uartPutUInt(UInt64(bitPattern: Int64(wrc)))
        uartPuts("\n")
        return
    }
    _ = virtioBlkDataFlush()
    uartPuts("D0 OK: data disk persistent, boot count ")
    uartPutUInt(count)
    uartPuts("\n")
}

/// D2: confirm the durable-sync path. fsync/fdatasync/sync now flush the data
/// disk's write cache to stable media. Here we prove the flush mechanism runs
/// after datafs is mounted; the userland fsync() -> SYS_FSYNC path is exercised
/// end-to-end by durable SQLite (D3).
private func runFsyncProbeD2() {
    if !virtioBlkDataAvailable() { return }
    let rc = virtioBlkDataFlush()
    if rc != 0 {
        uartPuts("D2: data flush failed, rc ")
        uartPutUInt(UInt64(bitPattern: Int64(rc)))
        uartPuts("\n")
        return
    }
    uartPuts("D2 OK: data sync path ready, flush count ")
    uartPutUInt(virtioBlkDataFlushCount())
    uartPuts("\n")
}

/// M11b: probe the virtio-blk disk. Bring up the block device discovered in the
/// virtio-mmio window, read sector 0, and report it. When the attached disk is a
/// packed base image its first bytes are the ASCII magic "SWOSBASE", which we
/// recognise here — the M11c on-disk filesystem will build on this read path.
// H2: prove the virtio transport actually exchanges a virtqueue. After
// virtioRngInit binds (over virtio-mmio on QEMU `virt`, or virtio-pci on
// `-cpu max` / the Hetzner VM), request entropy and confirm bytes came back
// through the used ring — a full descriptor → avail → notify → used round trip.
private func runVirtioRngQueueProbeH2() {
    let page = pmm_alloc_page()
    if page == 0 { return }
    let dst = UnsafeMutablePointer<UInt8>(bitPattern: page)!
    let want = 32
    let n = virtioRngRead(dst, want)
    var nonzero = 0
    if n > 0 {
        var i = 0
        while i < n { if dst[i] != 0 { nonzero += 1 }; i += 1 }
    }
    pmm_free_page(page)

    if n == want {
        uartPuts("H2 OK: virtio-")
        uartPuts(virtioRngTransportName())
        uartPuts(" rng exchanged a queue, bytes ")
        uartPutUInt(UInt64(n))
        uartPuts(" nonzero ")
        uartPutUInt(UInt64(nonzero))
        uartPuts("\n")
        klog(.info, "pci", "H2 OK: virtio transport exchanged a queue", UInt64(n))
    } else {
        uartPuts("H2 WARN: virtio rng queue exchange incomplete\n")
    }
}

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

/// Print an IPv4 address in dotted decimal.
private func printIPv4(_ ip: IPv4) {
    uartPutUInt(UInt64((ip >> 24) & 0xFF))
    uartPutc(0x2E)
    uartPutUInt(UInt64((ip >> 16) & 0xFF))
    uartPutc(0x2E)
    uartPutUInt(UInt64((ip >> 8) & 0xFF))
    uartPutc(0x2E)
    uartPutUInt(UInt64(ip & 0xFF))
}

/// net-a: bring up virtio-net and exercise the sans-IO stack against the QEMU
/// user-net (slirp) gateway. We ARP for 10.0.2.2, then send an ICMP echo request
/// and wait for the reply — proving driver RX/TX plus the Ethernet/ARP/IPv4/ICMP
/// core end to end. A no-op (one log line) when no NIC is attached, so the other
/// boot/test paths are unaffected (mirrors runVirtioBlkProbe).
private func runVirtioNetProbe() {
    netInit()   // brings up the NIC + the shared NetStack the socket layer uses
    if !netIsReady() {
        return  // netInit already logged "net: no virtio-net device attached"
    }
    uartPuts("net-a: virtio-net up, MAC ")
    printMac(netCurrentMac())
    uartPuts("\n")

    let gwIP = netGatewayIP

    // 1) Resolve the gateway's MAC via ARP.
    netProbeSendArpRequest(targetIP: gwIP)
    var gwMac = MAC()
    var resolved = false
    var spins = 0
    while spins < 4_000_000 && !resolved {
        let r = netProbePollArp(targetIP: gwIP)
        if r.resolved { gwMac = r.mac; resolved = true }
        spins += 1
    }
    if !resolved {
        if gwIP == netFallbackGatewayIP {
            uartPuts("net-a: ARP for 10.0.2.2 timed out\n")
        } else {
            uartPuts("net-a: ARP for gateway ")
            printIPv4(gwIP)
            uartPuts(" timed out\n")
        }
        return
    }
    if gwIP == netFallbackGatewayIP {
        uartPuts("net-a: ARP reply, 10.0.2.2 is at ")
    } else {
        uartPuts("net-a: ARP reply, gateway ")
        printIPv4(gwIP)
        uartPuts(" is at ")
    }
    printMac(gwMac)
    uartPuts("\n")

    // 2) Ping the gateway: send an ICMP echo request and await the echo reply.
    netProbeSendEchoRequest(toMac: gwMac, toIP: gwIP, id: 0x1234, seq: 1, payloadLen: 32)
    var got = false
    spins = 0
    while spins < 4_000_000 && !got {
        if netProbePollEcho() { got = true }
        spins += 1
    }
    if got {
        if gwIP == netFallbackGatewayIP {
            uartPuts("net-a OK: ICMP echo reply from 10.0.2.2\n")
        } else {
            uartPuts("net-a OK: ICMP echo reply from gateway ")
            printIPv4(gwIP)
            uartPuts("\n")
        }
    } else {
        uartPuts("net-a: ICMP echo reply timed out\n")
    }
}

private func runInit() {
    // We reached steady state — clear the consecutive-panic counter so an isolated
    // later fault starts counting fresh instead of inheriting this boot's history.
    panicLoopMarkHealthyBoot()
    uartPuts("swift-os M12c: starting swos-init\n")
    // Keep the system usable: when a session ends, start a fresh login rather
    // than leaving the VM idle. The image is (re)loaded each iteration because
    // the shell exec inside the session overwrites the shared ELF buffer.
    while true {
        let (initImage, initSize) = loadProgramImage("/bin/swos-init")
        if initImage != 0 {
            let (p, n, argc) = packArgs(["swos-init"])
            let code = processRunElf(initImage, initSize, packed: p, packedLen: n, argc: argc)
            uartPuts("M12c: session ended, code ")
            uartPutUInt(UInt64(code))
            uartPuts("; restarting init\n")
            continue
        }
        let (login, loginSize) = loadProgramImage("/bin/console-login")
        if login != 0 {
            uartPuts("M12c: /bin/swos-init missing; starting console-login\n")
            let (p, n, argc) = packArgs(["console-login"])
            let code = processRunElf(login, loginSize, packed: p, packedLen: n, argc: argc)
            uartPuts("M12c: session ended, code ")
            uartPutUInt(UInt64(code))
            uartPuts("; restarting login\n")
            continue
        }
        // No init/login program on disk: fall back to a raw shell so the system
        // is still usable (e.g. a minimal base image built without login).
        uartPuts("M12c: init/login missing; starting raw shell\n")
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
    // A kernel-level fault is unrecoverable, but a headless server should not be
    // left wedged forever: count down (visible on the console) and auto-reboot so
    // it returns to service. panicReboot never returns. See kernel/power/power.swift.
    panicReboot(seconds: 90)
}

@_cdecl("irq_handler")
func irqHandler() {
    // Capture the interrupted exception level before any handler runs (SPSR_EL1
    // still holds the pre-IRQ PSTATE; no nested EL1 exception is taken here).
    // M[3:0] == 0 means EL0t — user code was running. Used for CPU accounting.
    let fromEL0 = (read_spsr_el1() & 0xF) == 0

    let iar = gicAcknowledge()
    let interruptId = iar & 0x3FF

    if interruptId == physicalTimerIrq && currentCpuId() != 0 {
        smpRecordTimerTickForCurrentCpu()
        if !processSecondarySchedulerCanTickForCurrentCpu() {
            smpRecordIdleTickForCurrentCpu()
        }
        timerScheduleNext()
    } else if interruptId == smpIpiInterruptId {
        smpHandleIpi(iar)
    } else if interruptId == physicalTimerIrq {
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
    if interruptId == physicalTimerIrq && currentCpuId() == 0 {
        virtioKbdDrain() // poll the graphical-window keyboard into the tty
        fb_cursor_blink() // blink the on-screen cursor (no-op without a framebuffer)
        schedulerTick()  // M4.5 kernel-thread scheduler (idle once its demo ends)
        processOnTick(fromEL0: fromEL0)  // preempt the current EL0 process + CPU accounting
    } else if interruptId == physicalTimerIrq && processSecondarySchedulerCanTickForCurrentCpu() {
        processOnTick(fromEL0: fromEL0)
    } else if interruptId == uartIrqId {
        signalDeliverToForeground() // Ctrl-C → SIGINT; may terminate the process
    }
}

// C5i: set once at boot. False when the userland driver service owns virtio-input
// (the kernel never called virtioKbdInit), so the per-tick drain is skipped
// entirely rather than calling into a dormant getchar each tick.
private var kernelPolledKbdActive = false

/// Drain any keystrokes from the virtio-input keyboard into the tty line
/// discipline, exactly as the UART IRQ feeds serial input. No-op when there is
/// no keyboard device, or (C5i) when the userland driver owns it.
private func virtioKbdDrain() {
    if !kernelPolledKbdActive { return }
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
        let far = UInt(read_far_el1())
        // I2b: demand-page a lazily-reserved file-backed mmap region. This is a
        // translation fault on an unmapped page; it is disjoint from COW below,
        // which is a write *permission* fault on a still-mapped shared page.
        if processHandleFileFault(far) { return }
        let dfsc = esr & 0x3F
        let isWrite = (esr & (1 << 6)) != 0
        let isPermissionFault = dfsc >= 0xC && dfsc <= 0xF
        if isWrite && isPermissionFault {
            let ttbr0 = processCurrentAddressSpace()
            if ttbr0 != 0 {
                if addressSpaceHandleCowFaultForActiveCpuMask(ttbr0,
                                                              far,
                                                              processCurrentAddressSpaceActiveCpuMask()) {
                    return
                }
            }
        }
    }

    // Any other synchronous exception taken from EL0 is a fault in the user
    // process, not the kernel: a BRK/trap from an aborting runtime (V8 emits
    // `brk` on FatalProcessOutOfMemory / CHECK failures), an illegal/undefined
    // instruction, an alignment fault, or an unhandled data/instruction abort.
    // It must terminate the offending process with the matching signal, never
    // halt the kernel. (A same-EL/EL1 fault routes to a different vector and is
    // still a hard panic there.) Map the exception class to a signal, log the
    // fault for postmortem, then zombify the process and reschedule.
    let sig: Int
    switch exceptionClass {
    case 0x3C, 0x38, 0x30, 0x31, 0x32, 0x33: sig = SIGTRAP // BRK/BKPT/breakpoint/step/watchpoint
    case 0x00, 0x0E:                         sig = SIGILL  // unknown reason / illegal execution state
    case 0x22, 0x26:                         sig = SIGBUS  // PC / SP misalignment
    case 0x20, 0x21, 0x24, 0x25:             sig = SIGSEGV // instruction / data abort
    default:                                 sig = SIGILL
    }
    uartPuts("EL0 fault -> terminate proc by signal ")
    uartPutHex(UInt(sig))
    uartPuts(" ESR_EL1=")
    uartPutHex(UInt(esr))
    uartPuts(" ELR_EL1=")
    uartPutHex(UInt(read_elr_el1()))
    uartPuts(" FAR_EL1=")
    uartPutHex(UInt(read_far_el1()))
    uartPuts("\n")
    processTerminateBySignal(sig)
    // processTerminateBySignal does not return; guard against a future change.
    while true {}
}

/// Kernel entry point, called from the boot stub. Must never return.
/// `dtbPhys` is the device-tree pointer the boot stub preserved from x0.
/// `ramdiskBase`/`ramdiskSize` (x4/x5) are the UEFI loader's H3 RAM base-image
/// handoff (0/0 when the base comes from a virtio-blk disk instead).
@_cdecl("kernel_main")
func kernelMain(_ dtbPhys: UInt, _ fbBase: UInt, _ fbDims: UInt, _ fbStrFmt: UInt,
                _ ramdiskBase: UInt, _ ramdiskSize: UInt, _ acpiRsdp: UInt) {
    uartInit()  // no-op on QEMU; enables the PL011 on VirtualBox before any output
    // The UEFI loader may hand us a GOP framebuffer (x1=base, x2=w<<32|h,
    // x3=stride<<32|format). When present, mirror the boot log to the screen.
    if fbBase != 0 {
        let w = UInt32(truncatingIfNeeded: fbDims >> 32)
        let h = UInt32(truncatingIfNeeded: fbDims & 0xFFFF_FFFF)
        let stride = UInt32(truncatingIfNeeded: fbStrFmt >> 32)
        fb_init(UInt64(fbBase), w, h, stride)
    }
    ramdiskInit(base: ramdiskBase, size: ramdiskSize)  // H3: RAM-backed base image
    uartPuts("Hello from Swift kernel\n")
    uartPuts("swift-os M0: boot skeleton up on QEMU virt (aarch64, EL1)\n")
    uartPuts("swift-os M1: runtime and memory init\n")

    // M9/H5: discover the hardware map before any subsystem (PMM, GIC, timer)
    // relies on it. Prefer ACPI when the UEFI loader passed an RSDP (the real
    // Hetzner firmware has no FDT), else the device tree, else QEMU virt defaults.
    platformInit(dtbPhys, acpiRsdp)

    swiftos_heap_init()
    enableMMU()
    platformInitCpuTopology()

    pmmInit()
    if let raw = swiftos_kernel_alloc(32, 16) {
        raw.storeBytes(of: UInt64(0xC0DEFACE_CAFEBEEF), as: UInt64.self)
    } else {
        uartPuts("panic: kernelAlloc failed\n")
        while true {}
    }
    uartPuts("M1 probe: raw heap allocation ok\n")

#if PANIC_LOOP_INJECT
    // Test-only fault injector (the panic-loop-test kernel variant): auto-reboot on
    // every boot, here — after PSCI/MMU/heap are up but long before the steady-state
    // healthy-boot marker (panicLoopMarkHealthyBoot in runInit) and any interactive
    // stage — so the panic-loop guard must bound the consecutive reboots and halt
    // rather than cycle forever. Never compiled into a production kernel.
    uartPuts("panic-loop-test: injecting an early panic\n")
    panicReboot(seconds: 0)
#endif

    let swiftRaw = UnsafeMutableRawPointer.allocate(byteCount: 24, alignment: 16)
    swiftRaw.storeBytes(of: UInt64(0x1234_5678_90AB_CDEF), as: UInt64.self)
    swiftRaw.deallocate()
    uartPuts("M1 probe: Swift raw allocation hook ok\n")

    // Bring up a virtio-gpu scanout console as early as possible (right after the
    // PMM, which it needs for the framebuffer) so the boot log is visible on a
    // hypervisor whose only console is the graphical framebuffer — e.g. Hetzner
    // Cloud's noVNC, which has no serial tab. No-op when there is no virtio-gpu
    // (the GOP/ramfb framebuffer from the loader, if any, stays in use).
    if virtioGpuInit() {
        uartPuts("virtio-gpu: scanout console active\n")
    }

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
    if platformDiscoveredFromAcpi {
        klog(.info, "platform", "M9 OK: hardware discovered from ACPI")
    } else {
        klog(.info, "platform", "M9 OK: hardware discovered from device tree")
    }
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
    if !smpTopologySelfTest() {
        uartPuts("panic: S0f CPU topology self-test failed\n")
        while true {}
    }
    klog(.info, "smp", "S0f OK: CPU topology ready", UInt64(platform.cpuCount))
    if !smpPsciDiscoverySelfTest() {
        uartPuts("panic: S0g PSCI discovery self-test failed\n")
        while true {}
    }
    klog(.info, "smp", "S0g OK: PSCI discovery ready", UInt64(platform.cpuPsciEnableMask))
    if !smpBringupSecondaries() {
        uartPuts("panic: S1 secondary CPU bring-up failed\n")
        while true {}
    }
    klog(.info, "log", "L0 kernel logger active")
    klog(.info, "log", "level filtering active (min INFO)")
    // A .debug line that is suppressed by the L2 default (.info). This proves
    // the filter is active without polluting normal boot logs or test output.
    klog(.debug, "log", "this debug line should be filtered by default")
    klog(.info, "log", "source filtering active")
    klogSetSourceMinLevel("log_filter", .error)
    klog(.info, "log_filter", "this source-filtered info line should be hidden")
    klog(.error, "log_filter", "source override allows error")
    if klogCurrentSinkKind() == .uart {
        klog(.info, "log", "sink indirection active")
    }
    if !klogCanInstallSink(capabilities: 0) &&
        klogCanExportRing(capabilities: capLogExport) {
        klog(.info, "log", "sink capability hook active")
    }
    klogClearSourceMinLevels()
    schedulerInit()
    if !kernelSchedulerOwnershipSelfTest() || !smpS2cKernelSchedulerReadinessSelfTest() {
        uartPuts("panic: S2c kernel scheduler owner self-test failed\n")
        while true {}
    }
    klog(.info, "smp", "S2c OK: kernel scheduler owner ready", UInt64(currentCpuId()) + 1)
    processInit()
    if !smpS2ReadinessSelfTest() {
        uartPuts("panic: S2a scheduler readiness self-test failed\n")
        while true {}
    }
    klog(.info, "smp", "S2a OK: scheduler owner ready", UInt64(currentCpuId()) + 1)
    if !processSchedulerContextSelfTest() {
        uartPuts("panic: S2b process scheduler context self-test failed\n")
        while true {}
    }
    klog(.info, "smp", "S2b OK: process scheduler context scaffold ready", UInt64(smpMaxCpuCount()))
    if !processRunQueueScaffoldSelfTest() {
        uartPuts("panic: S2d process run queue scaffold self-test failed\n")
        while true {}
    }
    klog(.info, "smp", "S2d OK: process run queue scaffold ready", UInt64(smpMaxCpuCount()))
    if !processDormantSchedulerCpusSelfTest() {
        uartPuts("panic: S2e dormant process scheduler CPU self-test failed\n")
        while true {}
    }
    klog(.info, "smp", "S2e OK: dormant process scheduler CPUs published", UInt64(smpMaxCpuCount()))
    if !processDispatchTelemetrySelfTest() {
        uartPuts("panic: S2f process dispatch telemetry self-test failed\n")
        while true {}
    }
    klog(.info, "smp", "S2f OK: process dispatch telemetry ready", UInt64(smpMaxCpuCount()))
    if !processSecondaryEl0GateSelfTest() {
        uartPuts("panic: S2h secondary EL0 gate self-test failed\n")
        while true {}
    }
    klog(.info, "smp", "S2h OK: secondary EL0 gate ready", UInt64(smpMaxCpuCount()))
    if !processAddressSpaceCpuMaskSelfTest() {
        uartPuts("panic: S3a address-space CPU mask self-test failed\n")
        while true {}
    }
    klog(.info, "smp", "S3a OK: address-space CPU mask scaffold ready", UInt64(smpMaxCpuCount()))
    if !smpIpiSubstrateSelfTest() {
        uartPuts("panic: S3b IPI substrate self-test failed\n")
        while true {}
    }
    klog(.info, "smp", "S3b OK: GIC SGI IPI substrate ready", UInt64(platform.cpuCount))
    if !smpTlbShootdownSelfTest() {
        uartPuts("panic: S3c TLB shootdown self-test failed\n")
        while true {}
    }
    klog(.info, "smp", "S3c OK: TLB shootdown IPI scaffold ready", UInt64(platform.cpuCount))
    if !processAddressSpaceTlbFlushFacadeSelfTest() {
        uartPuts("panic: S3d address-space TLB flush facade self-test failed\n")
        while true {}
    }
    klog(.info, "smp", "S3d OK: address-space TLB flush facade ready", UInt64(smpMaxCpuCount()))
    if !pmmS4aConcurrencySelfTest() {
        uartPuts("panic: S4a PMM lock boundary self-test failed\n")
        while true {}
    }
    if !smpPmmStressSelfTest() {
        uartPuts("panic: S4a PMM SMP stress self-test failed\n")
        while true {}
    }
    klog(.info, "smp", "S4a OK: PMM lock boundary ready", UInt64(pmmS4aLockAcquireCount()))
    securityInit()
    runVirtioBlkProbe() // M11b: bring up the disk before the VFS may mount from it
    runDataDeviceProbeD0() // D0: persistent /data disk end-to-end persistence check
    if virtioRngInit() {
        uartPuts("virtio-rng: runtime entropy ready\n")
        runVirtioRngQueueProbeH2()
    }
    // Always seed the jitter-entropy DRBG: it is the SYS_RANDOM source whenever
    // no virtio-rng device is present (e.g. the Hetzner Cloud ARM VM), keeping
    // getentropy()/OpenSSL/sshd entropy alive without a hardware RNG.
    sysRngInit()
    if virtioRngAvailable() {
        uartPuts("SYS_RANDOM: source virtio-rng (DRBG fallback armed)\n")
        klog(.info, "rng", "SYS_RANDOM source: virtio-rng", 0)
    } else if sysRngHealthy() {
        uartPuts("SYS_RANDOM: source jitter-entropy DRBG (no virtio-rng device)\n")
        klog(.info, "rng", "SYS_RANDOM source: jitter-entropy DRBG", 1)
    } else {
        uartPuts("SYS_RANDOM WARN: no entropy source available\n")
        klog(.warn, "rng", "SYS_RANDOM has no entropy source", 0)
    }
    pkgStoreInit()      // P3: read active package-store generation, if present
    if !pkgStoreS4dReadinessSelfTest() {
        uartPuts("panic: S4d package-store lock boundary self-test failed\n")
        while true {}
    }
    klog(.info, "smp", "S4d OK: package-store lock boundary ready", UInt64(pkgStoreS4dLockAcquireCount()))
    vfsInit()           // M11c: serves the read-only base from disk when present
    runFsyncProbeD2()   // D2: confirm the data-disk durable-sync path
    if !vfsS4bReadinessSelfTest() {
        uartPuts("panic: S4b VFS lock boundary self-test failed\n")
        while true {}
    }
    klog(.info, "smp", "S4b OK: VFS lock boundary ready", UInt64(vfsS4bLockAcquireCount()))
    if !swiftos_heap_s4c_self_test() {
        uartPuts("panic: S4c kernel heap lock boundary self-test failed\n")
        while true {}
    }
    klog(.info, "smp", "S4c OK: kernel heap lock boundary ready", UInt64(swiftos_heap_lock_acquire_count()))
    espProbe()          // U1g-4a: locate the ESP on the GPT boot disk (if attached on mmio)
    runVirtioNetProbe() // net-a: virtio-net + sans-IO ARP/ICMP against slirp
    if !netS4eReadinessSelfTest() {
        uartPuts("panic: S4e network lock boundary self-test failed\n")
        while true {}
    }
    klog(.info, "smp", "S4e OK: network lock boundary ready", UInt64(netS4eLockAcquireCount()))
    if !smpPerCpuUtilizationSelfTest(platform.cpuCount) {
        uartPuts("panic: S5a per-CPU utilization counter self-test failed\n")
        while true {}
    }
    klog(.info, "smp", "S5a OK: per-CPU utilization counters ready", UInt64(platform.cpuCount))
    usbProbe()          // USB M1: bring up the xHCI controller and detect attached devices
    ttyInit()
    signalReset()
    uartRxInit()
    // C5i: the userland virtio-input driver service owns the device when the
    // registry handed out a mappable MMIO grant (C5h policy). In that case the
    // kernel must NOT bring up its in-kernel polled driver over the same window —
    // the device is driven from EL0. This is an early-init decision (one query),
    // not a per-tick check: kernelPolledKbdActive gates both init and the drain.
    let userlandOwnsKbd = vfsVirtioInputUserlandOwned()
    if userlandOwnsKbd {
        uartPuts("virtio-kbd: kernel skipped virtioKbdInit (userland driver owns virtio-input)\n")
    }
    kernelPolledKbdActive = userlandOwnsKbd ? false : (virtioKbdInit() > 0)
    // `inputKeyboard` reflects the PRESENCE of a window keyboard for the
    // interactive-console boot decision below, independent of whether the kernel
    // or the userland driver owns it — so a graphical session still boots straight
    // to the shell when a virtio keyboard + framebuffer are present.
    let inputKeyboard = userlandOwnsKbd || kernelPolledKbdActive
    // Take the "boot straight into swos-init / services" path (skipping the
    // serial-only milestone demo sequence) when a human is at a graphical window
    // (keyboard + framebuffer), OR when a virtio-gpu scanout console is the only
    // console — a headless server like a Hetzner Cloud VM, whose noVNC console
    // shows virtio-gpu and which has no serial input at all. Without this, the
    // demo sequence runs /bin/ttydemo, which blocks forever on a serial read that
    // never arrives, so swos-init (and therefore sshd) would never start. The
    // pure-serial dev/test path (`make run`, no framebuffer) keeps the demos.
    let interactiveConsole = (inputKeyboard && fb_available() != 0) || virtioGpuActive()
    if inputKeyboard {
        uartPuts("virtio-kbd: window keyboard ready\n")
    }
    enable_irq()

    if interactiveConsole {
        // Interactive graphical session (make run-gfx): boot straight into the
        // shell so the window is immediately usable. The milestone demos still
        // run on the serial/test path below (and the acceptance tests depend on
        // them, e.g. the M7 tty demo).
        runInit()
    } else {
        runSchedulerDemo()
        if !smpS2cNoSecondaryKernelSchedulerExecution() {
            uartPuts("panic: S2c secondary kernel scheduler execution guard failed\n")
            while true {}
        }
        klog(.info, "smp", "S2c OK: no secondary kernel scheduler execution", UInt64(platform.cpuCount))
        runProcessDemo()
        runArgvDemo()
        runSpawnDemo()
        runBrkDemo()
        runNewlibDemo()
        let ranConcurrentDemo = runConcurrentDemo()
        if ranConcurrentDemo {
            if !processCoprocPairDispatchTelemetrySelfTest() {
                uartPuts("panic: S2g coproc dispatch telemetry guard failed\n")
                while true {}
            }
            if platform.cpuCount > 1 {
                klog(.info, "smp", "S2h OK: coproc pair dispatched across scheduler CPUs", UInt64(platform.cpuCount))
            } else {
                klog(.info, "smp", "S2h OK: coproc pair dispatch CPU0 fallback", UInt64(platform.cpuCount))
            }
        }
        let ranS5bPlacementDemo = runS5bPlacementDemo()
        if ranS5bPlacementDemo {
            if !processS5bPlacementTelemetrySelfTest() {
                uartPuts("panic: S5b scheduler placement telemetry guard failed\n")
                while true {}
            }
            if platform.cpuCount > 1 {
                klog(.info, "smp", "S5b OK: EL0 scheduler placed batch across CPUs", UInt64(platform.cpuCount))
            } else {
                klog(.info, "smp", "S5b OK: EL0 scheduler placement CPU0 fallback", UInt64(platform.cpuCount))
            }
        }
        let ranS5cPlacementStressDemo = runS5cPlacementStressDemo()
        if ranS5cPlacementStressDemo {
            if !processS5cPlacementStressSelfTest() {
                uartPuts("panic: S5c scheduler placement stress guard failed\n")
                while true {}
            }
            if platform.cpuCount > 1 {
                klog(.info, "smp", "S5c OK: repeated EL0 placement stress crossed CPUs", UInt64(platform.cpuCount))
            } else {
                klog(.info, "smp", "S5c OK: repeated EL0 placement stress CPU0 fallback", UInt64(platform.cpuCount))
            }
        }
        let ranS5dFanoutDemo = runS5dFanoutDemo()
        if ranS5dFanoutDemo {
            if !processS5dFanoutSelfTest() {
                uartPuts("panic: S5d scheduler fanout guard failed\n")
                while true {}
            }
            if platform.cpuCount > 1 {
                klog(.info, "smp", "S5d OK: EL0 fanout crossed scheduler CPUs", UInt64(platform.cpuCount))
            } else {
                klog(.info, "smp", "S5d OK: EL0 fanout CPU0 fallback", UInt64(platform.cpuCount))
            }
        }
        let ranS5eThreadFanoutDemo = runS5eThreadFanoutDemo()
        if ranS5eThreadFanoutDemo {
            if !processS5eThreadFanoutSelfTest() {
                uartPuts("panic: S5e thread fanout guard failed\n")
                while true {}
            }
            if platform.cpuCount > 1 {
                klog(.info, "smp", "S5e OK: shared-address-space threads crossed CPUs", UInt64(platform.cpuCount))
            } else {
                klog(.info, "smp", "S5e OK: shared-address-space thread fanout CPU0 fallback", UInt64(platform.cpuCount))
            }
        }
        let ranS5fRunAnyPlacementDemo = runS5fRunAnyPlacementDemo()
        if ranS5fRunAnyPlacementDemo {
            if !processS5fRunAnyPlacementSelfTest() {
                uartPuts("panic: S5f run-any placement guard failed\n")
                while true {}
            }
            if platform.cpuCount > 1 {
                klog(.info, "smp", "S5f OK: run-any placement covered scheduler CPUs", UInt64(platform.cpuCount))
            } else {
                klog(.info, "smp", "S5f OK: run-any placement CPU0 fallback", UInt64(platform.cpuCount))
            }
        }
        runForkDemo()
        runExecDemo()
        runFdOpsDemo()
        runDriverServiceDemo()
        runUserlandServiceDemo()
        runDeviceMmioMapProbe()
        runFsDemo()
        runSecurityDemo()
        runIdentityDemo()
        runReclaimDemo()
        runOrphanReapDemo()
        runPsDemo()
        if !processMultiCpuSchedulerPostRunSelfTest() {
            uartPuts("panic: S2 multi-CPU process scheduler post-run guard failed\n")
            while true {}
        }
        klog(.info, "smp", "S2h OK: process scheduler quiesced after multi-CPU dispatch", UInt64(platform.cpuCount))
        if !processSecondaryEl0GateHeldSelfTest() {
            uartPuts("panic: S2h secondary EL0 gate guard failed\n")
            while true {}
        }
        klog(.info, "smp", "S2h OK: secondary EL0 gate closed after restricted dispatch", UInt64(platform.cpuCount))
        if !processAddressSpaceCpuMaskPostRunSelfTest() {
            uartPuts("panic: S3a address-space CPU mask guard failed\n")
            while true {}
        }
        klog(.info, "smp", "S3a OK: address-space CPU masks matched dispatch CPUs", UInt64(platform.cpuCount))
        if !smpS3bIpiSchedulerBoundarySelfTest() {
            uartPuts("panic: S3b IPI scheduler boundary guard failed\n")
            while true {}
        }
        klog(.info, "smp", "S3b OK: IPI delivery stayed scheduler-safe", UInt64(platform.cpuCount))
        if !smpS3cTlbShootdownSchedulerBoundarySelfTest() {
            uartPuts("panic: S3c TLB shootdown scheduler boundary guard failed\n")
            while true {}
        }
        klog(.info, "smp", "S3c OK: TLB shootdown path stayed scheduler-safe", UInt64(platform.cpuCount))
        if !processAddressSpaceTlbFlushPostRunSelfTest() {
            uartPuts("panic: S3d address-space TLB flush facade guard failed\n")
            while true {}
        }
        klog(.info, "smp", "S3d OK: address-space TLB flush matched dispatch CPUs", UInt64(platform.cpuCount))
        if !pmmS4aLockBoundaryHeldSelfTest() {
            uartPuts("panic: S4a PMM lock boundary did not stay balanced\n")
            while true {}
        }
        if !smpS4aPmmStressSchedulerBoundarySelfTest() {
            uartPuts("panic: S4a PMM stress scheduler boundary failed\n")
            while true {}
        }
        klog(.info, "smp", "S4a OK: PMM lock boundary stayed balanced", UInt64(pmmS4aLockContentionCount()))
        if !vfsS4bLockBoundaryHeldSelfTest() {
            uartPuts("panic: S4b VFS lock boundary did not stay balanced\n")
            while true {}
        }
        klog(.info, "smp", "S4b OK: VFS lock boundary stayed balanced", UInt64(vfsS4bLockContentionCount()))
        if !swiftos_heap_lock_boundary_self_test() {
            uartPuts("panic: S4c kernel heap lock boundary did not stay balanced\n")
            while true {}
        }
        klog(.info, "smp", "S4c OK: kernel heap lock boundary stayed balanced", UInt64(swiftos_heap_lock_contention_count()))
        if !pkgStoreS4dLockBoundaryHeldSelfTest() {
            uartPuts("panic: S4d package-store lock boundary did not stay balanced\n")
            while true {}
        }
        klog(.info, "smp", "S4d OK: package-store lock boundary stayed balanced", UInt64(pkgStoreS4dLockContentionCount()))
        if !netS4eLockBoundaryHeldSelfTest() {
            uartPuts("panic: S4e network lock boundary did not stay balanced\n")
            while true {}
        }
        klog(.info, "smp", "S4e OK: network lock boundary stayed balanced", UInt64(netS4eLockContentionCount()))
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
