// SPDX-License-Identifier: Apache-2.0
// gic.swift — GIC driver for the ARM Generic Interrupt Controller.
//
// Dual-path (H1): GICv2 (MMIO CPU interface — the QEMU `virt` default) and
// GICv3 (per-CPU redistributors + a system-register CPU interface — what QEMU
// `-M virt,gic-version=3` and the Hetzner ARM cloud VM present). The version is
// detected at runtime from GICD_PIDR2.ArchRev, so the same kernel drives both
// boards. Callers use one surface — gicInit / gicInitCpuInterfaceForCurrentCpu /
// gicEnableInterrupt / gicAcknowledge / gicEndInterrupt / the SGI helpers —
// regardless of version.

// Distributor base (shared by v2/v3; the same 0x0800_0000 on QEMU virt and the
// Hetzner VM). The v2 CPU-interface and v3 redistributor bases come from the HAL
// too, so they track platformInit's device-tree / default discovery.
private var gicdBase: UInt { platform.gicDist }
private var giccBase: UInt { platform.gicCpu }       // GICv2 CPU interface (MMIO)
private var gicrBase: UInt { platform.gicRedist }    // GICv3 redistributor frames

// Distributor registers (offsets are identical across v2/v3 for the ones we use).
private let gicdCtlr: UInt = 0x000
private let gicdIcenabler: UInt = 0x180
private let gicdIsenabler: UInt = 0x100
private let gicdIpriorityr: UInt = 0x400
private let gicdItargetsr: UInt = 0x800     // v2 SPI routing (one byte per INTID)
private let gicdIcfgr: UInt = 0xC00
private let gicdIrouter: UInt = 0x6000      // v3 SPI routing (64-bit per INTID)
private let gicdSgir: UInt = 0xF00          // v2 SGI generation

// GICv2 CPU interface (MMIO).
private let giccCtlr: UInt = 0x000
private let giccPmr: UInt = 0x004
private let giccIar: UInt = 0x00C
private let giccEoir: UInt = 0x010

// GICv3 redistributor frame layout. Each PE's redistributor is two 64 KiB
// frames: RD_base (control) then SGI_base (SGI/PPI config). QEMU virt and the
// Hetzner VM lay them out 0x20000 apart per PE.
private let gicrStride: UInt = 0x2_0000
private let gicrSgiOffset: UInt = 0x1_0000
private let gicrWaker: UInt = 0x0014        // in RD_base
private let gicrTyper: UInt = 0x0008        // 64-bit; Affinity[63:32], Last[4]
private let gicrIgroupr0: UInt = 0x0080     // in SGI_base
private let gicrIsenabler0: UInt = 0x0100
private let gicrIcenabler0: UInt = 0x0180
private let gicrIpriorityr: UInt = 0x0400
private let gicrWakerProcessorSleep: UInt32 = 1 << 1
private let gicrWakerChildrenAsleep: UInt32 = 1 << 2

// GICD_CTLR bits in the single-security-state (DS=1) view QEMU virt presents.
private let gicdCtlrEnableGrp0: UInt32 = 1 << 0
private let gicdCtlrEnableGrp1: UInt32 = 1 << 1
private let gicdCtlrARE: UInt32 = 1 << 4
private let gicdCtlrRWP: UInt32 = UInt32(1) << 31

let gicSpuriousInterrupt: UInt32 = 1023
let smpIpiInterruptId: UInt32 = 1

// Detected GIC architecture version (2 or 3). Set once by gicInit on CPU0,
// before any secondary CPU starts, then read by the per-CPU init and the hot
// IRQ paths. Secondaries observe it after CPU0's release-store handoff.
private(set) var gicArchVersion: UInt32 = 2

@inline(__always) func gicIsV3() -> Bool { gicArchVersion >= 3 }

private func gicDetectVersion() {
    // ID_AA64PFR0_EL1.GIC (bits [27:24]) is nonzero iff the GICv3+ system-
    // register CPU interface is implemented. Fault-free, unlike probing the
    // GICD_PIDR2 MMIO offset (the v2 distributor aborts on the v3 location).
    let gicField = (read_id_aa64pfr0_el1() >> 24) & 0xF
    gicArchVersion = gicField != 0 ? 3 : 2
}

// ---------------------------------------------------------------------------
// Public surface
// ---------------------------------------------------------------------------

func gicInit() {
    gicDetectVersion()
    if gicIsV3() {
        gicv3InitDistributor()
        gicInitCpuInterfaceForCurrentCpu()
        uartPuts("M2 GIC: GICv3 dist ")
        uartPutHex(gicdBase)
        uartPuts(" redist ")
        uartPutHex(gicrBase)
        uartPuts("\n")
        return
    }

    mmio_write32(gicdBase + gicdCtlr, 0)
    gicInitCpuInterfaceForCurrentCpu()

    // Enable both groups. On the non-secure GICv2 view, bit 0 enables Group 1.
    mmio_write32(gicdBase + gicdCtlr, 0x3)
    gicInitCpuInterfaceForCurrentCpu()
    uartPuts("M2 GIC: GICv2 dist ")
    uartPutHex(gicdBase)
    uartPuts(" cpu ")
    uartPutHex(giccBase)
    uartPuts("\n")
}

func gicInitCpuInterfaceForCurrentCpu() {
    if gicIsV3() {
        gicv3InitCpuInterfaceForCurrentCpu()
        return
    }
    mmio_write32(giccBase + giccCtlr, 0)
    mmio_write32(giccBase + giccPmr, 0xFF)
    mmio_write32(giccBase + giccCtlr, 0x3)
    gicEnableInterrupt(smpIpiInterruptId)
}

func gicEnableInterrupt(_ id: UInt32) {
    if gicIsV3() {
        gicv3EnableInterrupt(id)
        return
    }

    let priorityAddr = gicdBase + gicdIpriorityr + UInt(id)
    mmio_write32(priorityAddr & ~UInt(3), 0x8080_8080)

    // Level-triggered, active-high. Timer PPIs are banked, so no target setup.
    let cfgAddr = gicdBase + gicdIcfgr + UInt((id / 16) * 4)
    let shift = UInt((id % 16) * 2)
    let cfg = mmio_read32(cfgAddr) & ~(UInt32(0x3) << UInt32(shift))
    mmio_write32(cfgAddr, cfg)

    // SPIs (id >= 32) are not banked: route them to CPU interface 0. ITARGETSR
    // is byte-per-interrupt; do a read-modify-write on the containing word.
    if id >= 32 {
        let targetWord = gicdBase + gicdItargetsr + UInt((id / 4) * 4)
        let byteShift = UInt32((id % 4) * 8)
        let current = mmio_read32(targetWord) & ~(UInt32(0xFF) << byteShift)
        mmio_write32(targetWord, current | (UInt32(0x01) << byteShift))
    }

    let enableAddr = gicdBase + gicdIsenabler + UInt((id / 32) * 4)
    mmio_write32(enableAddr, UInt32(1) << UInt32(id % 32))
}

func gicDisableInterrupt(_ id: UInt32) {
    if gicIsV3() {
        if id < 32 {
            let sgi = gicv3RedistBaseForCurrentCpu() + gicrSgiOffset
            mmio_write32(sgi + gicrIcenabler0, UInt32(1) << UInt32(id % 32))
        } else {
            let disableAddr = gicdBase + gicdIcenabler + UInt((id / 32) * 4)
            mmio_write32(disableAddr, UInt32(1) << UInt32(id % 32))
        }
        return
    }
    let disableAddr = gicdBase + gicdIcenabler + UInt((id / 32) * 4)
    mmio_write32(disableAddr, UInt32(1) << UInt32(id % 32))
}

func gicAcknowledge() -> UInt32 {
    if gicIsV3() {
        return UInt32(gicv3_read_iar1() & 0xFF_FFFF)
    }
    return mmio_read32(giccBase + giccIar)
}

func gicEndInterrupt(_ interruptAck: UInt32) {
    if gicIsV3() {
        gicv3_write_eoir1(UInt64(interruptAck))
        return
    }
    mmio_write32(giccBase + giccEoir, interruptAck)
}

func gicSoftwareGeneratedInterruptSource(_ interruptAck: UInt32) -> UInt32 {
    // GICv3 ICC_IAR1 returns only the INTID for an SGI; the source PE is not
    // encoded (unlike the GICv2 IAR). Telemetry that wants the sender must track
    // it another way on v3, so report 0 there.
    if gicIsV3() { return 0 }
    return (interruptAck >> 10) & 0x7
}

func gicSendSoftwareGeneratedInterrupt(_ id: UInt32, targetMask: UInt32) -> Bool {
    if id >= 16 { return false }
    let mask = targetMask & 0xFF
    if mask == 0 { return false }

    if gicIsV3() {
        smpStoreBarrier()
        gicv3_write_sgi1r(gicv3BuildSgi1r(id: id, targetList: mask))
        smpMemoryBarrier()
        return true
    }

    smpStoreBarrier()
    mmio_write32(gicdBase + gicdSgir, gicBuildSgirValue(id: id, targetMask: mask))
    smpMemoryBarrier()
    return true
}

func gicSendSoftwareGeneratedInterruptToCpu(_ id: UInt32, _ cpu: UInt32) -> Bool {
    if cpu >= 8 { return false }
    return gicSendSoftwareGeneratedInterrupt(id, targetMask: UInt32(1) << cpu)
}

// ---------------------------------------------------------------------------
// GICv2 SGI encoding (kept for the MMIO path + the self-test)
// ---------------------------------------------------------------------------

private func gicBuildSgirValue(id: UInt32, targetMask: UInt32) -> UInt32 {
    // GICD_SGIR target-list mode: SGIINTID[3:0], CPUTargetList[23:16],
    // TargetListFilter[25:24] = 0b00. QEMU 11.0.1 arm_gic.c handles this at
    // distributor offset 0xf00 and maps CPUTargetList bits to CPU interfaces.
    (id & 0xF) | ((targetMask & 0xFF) << 16)
}

// ---------------------------------------------------------------------------
// GICv3 internals
// ---------------------------------------------------------------------------

// ICC_SGI1R_EL1: INTID[27:24], TargetList[15:0]. Aff1/2/3 = 0 (a single CPU
// cluster on QEMU virt and the Hetzner VM) and IRM[40] = 0 (use the target
// list). The 8-bit targetMask maps directly onto TargetList (Aff0 0..7).
private func gicv3BuildSgi1r(id: UInt32, targetList: UInt32) -> UInt64 {
    (UInt64(id & 0xF) << 24) | UInt64(targetList & 0xFFFF)
}

// IROUTER / redistributor affinity value, packed like GICR_TYPER[63:32]:
// Aff3<<24 | Aff2<<16 | Aff1<<8 | Aff0. QEMU virt uses Aff0 as the CPU index.
private func gicv3CurrentAffinity() -> UInt32 {
    let mpidr = read_mpidr_el1()
    let aff0 = UInt32(mpidr & 0xFF)
    let aff1 = UInt32((mpidr >> 8) & 0xFF)
    let aff2 = UInt32((mpidr >> 16) & 0xFF)
    let aff3 = UInt32((mpidr >> 32) & 0xFF)
    return aff0 | (aff1 << 8) | (aff2 << 16) | (aff3 << 24)
}

// Locate the current PE's redistributor frame by matching GICR_TYPER affinity
// to MPIDR. Falls back to the first frame (and is bounded) so a mismatch can
// never walk off into unmapped MMIO.
private func gicv3RedistBaseForCurrentCpu() -> UInt {
    let want = gicv3CurrentAffinity()
    var frame = gicrBase
    var scanned = 0
    while scanned < 8 {
        let affinity = mmio_read32(frame + gicrTyper + 4)   // TYPER[63:32]
        if affinity == want { return frame }
        let typerLo = mmio_read32(frame + gicrTyper)
        if (typerLo & (UInt32(1) << 4)) != 0 { break }      // Last redistributor
        frame += gicrStride
        scanned += 1
    }
    return gicrBase
}

private func gicv3WaitDistributorRWP() {
    var spins = 0
    while (mmio_read32(gicdBase + gicdCtlr) & gicdCtlrRWP) != 0 && spins < 1_000_000 {
        spins += 1
    }
}

private func gicv3InitDistributor() {
    // QEMU virt (and the Hetzner VM) run the GIC with a single security state
    // (DS=1), so the non-secure group bits are directly settable from EL1.
    // Disable, turn on affinity routing (ARE), then enable groups.
    mmio_write32(gicdBase + gicdCtlr, 0)
    gicv3WaitDistributorRWP()
    mmio_write32(gicdBase + gicdCtlr, gicdCtlrARE)
    gicv3WaitDistributorRWP()
    mmio_write32(gicdBase + gicdCtlr,
                 gicdCtlrARE | gicdCtlrEnableGrp1 | gicdCtlrEnableGrp0)
    gicv3WaitDistributorRWP()
}

private func gicv3InitCpuInterfaceForCurrentCpu() {
    let rd = gicv3RedistBaseForCurrentCpu()

    // Wake the redistributor: clear ProcessorSleep, then wait ChildrenAsleep.
    var waker = mmio_read32(rd + gicrWaker)
    waker &= ~gicrWakerProcessorSleep
    mmio_write32(rd + gicrWaker, waker)
    var spins = 0
    while (mmio_read32(rd + gicrWaker) & gicrWakerChildrenAsleep) != 0 && spins < 1_000_000 {
        spins += 1
    }

    // SGI/PPI defaults in the SGI frame: all Group 1, all disabled to start
    // (individual SGIs/PPIs are enabled via gicEnableInterrupt).
    let sgi = rd + gicrSgiOffset
    mmio_write32(sgi + gicrIgroupr0, 0xFFFF_FFFF)
    mmio_write32(sgi + gicrIcenabler0, 0xFFFF_FFFF)

    // System-register CPU interface.
    gicv3_write_sre(gicv3_read_sre() | 1)   // ICC_SRE_EL1.SRE = 1, use sysregs
    gicv3_write_pmr(0xFF)                    // unmask all priorities
    gicv3_write_bpr1(0)
    gicv3_write_ctlr(0)                      // EOImode = 0 (priority drop + EOI)
    gicv3_write_igrpen1(1)                   // enable Group 1 interrupts

    gicEnableInterrupt(smpIpiInterruptId)
}

private func gicv3EnableInterrupt(_ id: UInt32) {
    if id < 32 {
        // SGI/PPI live in THIS PE's redistributor SGI frame.
        let sgi = gicv3RedistBaseForCurrentCpu() + gicrSgiOffset
        let priorityAddr = sgi + gicrIpriorityr + UInt(id)
        mmio_write32(priorityAddr & ~UInt(3), 0x8080_8080)
        mmio_write32(sgi + gicrIsenabler0, UInt32(1) << UInt32(id % 32))
        return
    }

    // SPI: distributor priority, config, affinity routing, then enable.
    let priorityAddr = gicdBase + gicdIpriorityr + UInt(id)
    mmio_write32(priorityAddr & ~UInt(3), 0x8080_8080)

    let cfgAddr = gicdBase + gicdIcfgr + UInt((id / 16) * 4)
    let shift = UInt((id % 16) * 2)
    let cfg = mmio_read32(cfgAddr) & ~(UInt32(0x3) << UInt32(shift))
    mmio_write32(cfgAddr, cfg)   // level-triggered, active-high

    // Route this SPI to the current PE (IROUTER is 64-bit, ARE must be set).
    let router = gicdBase + gicdIrouter + UInt(id) * 8
    mmio_write32(router, gicv3CurrentAffinity())
    mmio_write32(router + 4, 0)  // Aff3 = 0, IRM = 0 (specific PE)

    let enableAddr = gicdBase + gicdIsenabler + UInt((id / 32) * 4)
    mmio_write32(enableAddr, UInt32(1) << UInt32(id % 32))
}

// ---------------------------------------------------------------------------
// Self-test (pure arithmetic; version-aware). Used by the SMP IPI substrate.
// ---------------------------------------------------------------------------

func gicSoftwareGeneratedInterruptSelfTest() -> Bool {
    if smpIpiInterruptId >= 16 { return false }
    if gicIsV3() {
        if gicv3BuildSgi1r(id: 1, targetList: 0x01) != 0x0100_0001 { return false }
        if gicv3BuildSgi1r(id: 7, targetList: 0xA5) != 0x0700_00A5 { return false }
        return true
    }
    if gicdSgir != 0xF00 { return false }
    if gicBuildSgirValue(id: 1, targetMask: 0x01) != 0x0001_0001 { return false }
    if gicBuildSgirValue(id: 7, targetMask: 0xA5) != 0x00A5_0007 { return false }
    if gicSoftwareGeneratedInterruptSource(0x0000_0801) != 2 { return false }
    return true
}
