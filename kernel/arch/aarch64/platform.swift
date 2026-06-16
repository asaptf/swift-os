// SPDX-License-Identifier: Apache-2.0
// platform.swift - the hardware abstraction layer (HAL).
//
// One global `Platform` holds the device addresses and IRQ numbers the kernel
// drivers need. It starts at QEMU `virt` defaults so early boot (the banner,
// the panic path) works before discovery runs, then `platformInit` overrides
// the fields it can read from the flattened device tree the firmware/QEMU
// passes in x0. Drivers read from `platform` instead of hardcoding constants,
// which is what lets the same kernel boot under UEFI / a different board.

@_alignment(16) struct Platform {
#if BOARD_VIRTUALBOX
    // VirtualBox ARM machine model (observed from its device tree; see
    // docs/VIRTUALBOX.md). These compiled-in defaults make early boot — the
    // banner, the panic path — reach the real UART before any DTB discovery,
    // since VBox is not guaranteed to hand us a device tree.
    var ramBase: UInt = 0x0800_0000
    var ramSize: UInt = 0x1000_0000   // 256 MiB (RAM 0x0800_0000..0x1800_0000).
    // GIC: VBox exposes a GICv3 block at 0xFCD3_0000 (large redistributor range).
    // The GICv2 driver does not drive it yet, so these are informational until
    // GICv3 support lands; the VBox boot path parks before GIC init.
    var gicDist: UInt = 0xFCD3_0000
    var gicCpu: UInt = 0xFCD4_0000
    // GICv3 redistributor base (H1). Informational on VBox (it parks before GIC
    // init); the kernel detects GICv2 vs v3 from GICD_PIDR2 at gicInit.
    var gicRedist: UInt = 0xFCD4_0000
    // PL011 UART.
    var uartBase: UInt = 0xFFDD_F000
    var uartIrq: UInt32 = 33
    // EL1 physical timer PPI - architectural, not board-specific.
    var timerIrq: UInt32 = 30
    // virtio-mmio transport window (QEMU-style layout; informational on VBox).
    var virtioMmioBase: UInt = 0x0A00_0000
    var virtioMmioStride: UInt = 0x200
    var dtbBase: UInt = 0
    var virtioMmioCount: UInt32 = 32
    // H2: no PCIe ECAM modeled for the VirtualBox board yet (it parks before
    // driver init); 0 disables PCI enumeration.
    var pcieEcamBase: UInt = 0
    var cpuCount: UInt32 = 1
    var cpuAff0_0: UInt32 = 0
    var cpuAff0_1: UInt32 = 0
    var cpuAff0_2: UInt32 = 0
    var cpuAff0_3: UInt32 = 0
    var cpuAff0_4: UInt32 = 0
    var cpuAff0_5: UInt32 = 0
    var cpuAff0_6: UInt32 = 0
    var cpuAff0_7: UInt32 = 0
    var cpuPsciEnableMask: UInt32 = 0
    var psciMethod: UInt32 = platformPsciMethodNone
    var psciCpuOn: UInt32 = 0
    // PL031 RTC: unknown on VBox; 0 disables the clock (rtcNow returns 0).
    var rtcBase: UInt = 0
#else
    // Main RAM.
    var ramBase: UInt = 0x4000_0000
    var ramSize: UInt = 0x1000_0000   // 256 MiB (matches `-m 256M`).
    // GICv2 distributor and CPU interface.
    var gicDist: UInt = 0x0800_0000
    var gicCpu: UInt = 0x0801_0000
    // GICv3 redistributor base (H1). QEMU `-M virt,gic-version=3` and the Hetzner
    // ARM cloud VM both place GICR at 0x080A_0000 (the same GICD at 0x0800_0000).
    // Unused on the GICv2 path; the kernel detects the version from GICD_PIDR2.
    var gicRedist: UInt = 0x080A_0000
    // PL011 UART.
    var uartBase: UInt = 0x0900_0000
    var uartIrq: UInt32 = 33          // QEMU virt: SPI 1 -> INTID 33.
    // EL1 physical timer PPI - architectural, not board-specific.
    var timerIrq: UInt32 = 30
    // virtio-mmio transport window (QEMU virt: 32 slots of 0x200 at 0x0A000000).
    var virtioMmioBase: UInt = 0x0A00_0000
    var virtioMmioStride: UInt = 0x200
    var dtbBase: UInt = 0
    var virtioMmioCount: UInt32 = 32
    // H2: PCIe ECAM config-space base. QEMU virt (high ECAM) and the Hetzner ARM
    // VM both place it at 0x40_1000_0000. 0 disables PCI enumeration. The early
    // MMU map covers the containing 1 GiB block (vm_early.c).
    var pcieEcamBase: UInt = 0x40_1000_0000
    // S0f CPU topology. CPU0 is the only compiled-in default; the DTB parser
    // replaces this with the QEMU `-smp N` `/cpus` map when available.
    var cpuCount: UInt32 = 1
    var cpuAff0_0: UInt32 = 0
    var cpuAff0_1: UInt32 = 0
    var cpuAff0_2: UInt32 = 0
    var cpuAff0_3: UInt32 = 0
    var cpuAff0_4: UInt32 = 0
    var cpuAff0_5: UInt32 = 0
    var cpuAff0_6: UInt32 = 0
    var cpuAff0_7: UInt32 = 0
    // S0g PSCI discovery. This records what the DTB advertises; S0 still never
    // issues CPU_ON or lets secondaries enter Swift/kernel code.
    var cpuPsciEnableMask: UInt32 = 0
    var psciMethod: UInt32 = platformPsciMethodNone
    var psciCpuOn: UInt32 = 0
    // PL031 RTC (QEMU virt): data register at base holds Unix time in seconds.
    var rtcBase: UInt = 0x0901_0000
#endif
}

var platform = Platform()

private let qemuDirectBootDtbAddr: UInt = 0x4FF0_0000

/// Discover the hardware map from the device tree and update `platform`.
///
/// `dtbPhys` is the pointer the boot stub preserved from x0. If it is not a
/// valid DTB we scan RAM for the device tree; if that also fails we keep the
/// compiled-in defaults - the kernel never regresses on a board it already knew.
func platformInit(_ dtbPhys: UInt) {
    var info = PlatformInfo()
    var parsedDtb: UInt = 0

    // 1. The pointer the boot stub preserved from x0 (how a UEFI loader and some
    //    boot paths hand off the DTB).
    if tryParse(dtbPhys, into: &info) {
        parsedDtb = dtbPhys
    }

    // 2. QEMU's direct ELF `-kernel` path does not reliably pass the DTB in x0,
    //    and our run/test harness injects a dumped DTB at a fixed RAM address.
    //    Scan RAM (page-granular) for the FDT magic rather than hardcode that
    //    address; the parser is header-validated, so a stray magic match on
    //    stale bytes cannot fault the kernel.
    if !info.valid {
        var addr = platform.ramBase
        let end = platform.ramBase + platform.ramSize
        while addr + 0x1000 <= end {
            if tryParse(addr, into: &info) {
                parsedDtb = addr
                break
            }
            addr += 0x1000
        }
    }

    guard info.valid else {
        uartPuts("M9 platform: no valid device tree, using QEMU virt defaults\n")
        return
    }

    platform.dtbBase = parsedDtb

    if info.haveRam {
        platform.ramBase = info.ramBase
        platform.ramSize = info.ramSize
    }
    if info.haveUart {
        platform.uartBase = info.uartBase
        if info.haveUartIrq { platform.uartIrq = info.uartIrq }
    }
    if info.haveGic {
        platform.gicDist = info.gicDist
        // For GICv3 the second reg range is the redistributor, not a CPU
        // interface (the CPU interface is system registers). For GICv2 it is
        // the GICC MMIO window. fdtParseInto records which via gicIsV3.
        if info.gicIsV3 {
            platform.gicRedist = info.gicCpu
        } else {
            platform.gicCpu = info.gicCpu
        }
    }
    if info.haveVirtio && info.virtioCount > 0 {
        platform.virtioMmioBase = info.virtioBase
        if info.virtioStride != 0 { platform.virtioMmioStride = info.virtioStride }
        platform.virtioMmioCount = info.virtioCount
    }

    uartPuts("M9 platform: ram ")
    uartPutHex(platform.ramBase)
    uartPuts(" size ")
    uartPutHex(platform.ramSize)
    uartPuts("\nM9 platform: uart ")
    uartPutHex(platform.uartBase)
    uartPuts(" irq ")
    uartPutUInt(UInt64(platform.uartIrq))
    uartPuts(" gic ")
    uartPutHex(platform.gicDist)
    uartPuts(" / ")
    uartPutHex(platform.gicCpu)
    if info.haveVirtio {
        uartPuts("\nM9 platform: virtio-mmio ")
        uartPutHex(platform.virtioMmioBase)
        uartPuts(" x")
        uartPutUInt(UInt64(platform.virtioMmioCount))
    }
    uartPuts("\n")

    if info.haveRam && info.haveUart && info.haveGic {
        uartPuts("M9 OK: hardware discovered from device tree\n")
    } else {
        uartPuts("M9 WARN: device tree incomplete, kept defaults for missing fields\n")
    }
}

private func tryParse(_ addr: UInt, into info: inout PlatformInfo) -> Bool {
    guard let p = UnsafePointer<UInt8>(bitPattern: addr) else {
        info.reset()
        return false
    }
    fdtParseInto(p, &info)
    return info.valid
}

// S0f/S0g: copy CPU topology and PSCI discovery after the MMU is enabled. The
// early `platformInit` deliberately leaves this for later because Swift may
// combine adjacent UInt32 fields into SIMD loads/stores, which are unsafe while
// RAM is still Device-typed.
func platformInitCpuTopology() {
    var info = PlatformInfo()
    considerCpuTopology(platform.dtbBase, into: &info)
    considerCpuTopology(qemuDirectBootDtbAddr, into: &info)

    if info.haveCpuTopology && info.cpuCount > 0 {
        platform.cpuCount = info.cpuCount
        platform.cpuAff0_0 = info.cpuAff0_0
        platform.cpuAff0_1 = info.cpuAff0_1
        platform.cpuAff0_2 = info.cpuAff0_2
        platform.cpuAff0_3 = info.cpuAff0_3
        platform.cpuAff0_4 = info.cpuAff0_4
        platform.cpuAff0_5 = info.cpuAff0_5
        platform.cpuAff0_6 = info.cpuAff0_6
        platform.cpuAff0_7 = info.cpuAff0_7
        platform.cpuPsciEnableMask = info.cpuPsciEnableMask
        platform.psciMethod = info.psciMethod
        platform.psciCpuOn = info.psciCpuOn
    }
}

private func considerCpuTopology(_ addr: UInt, into best: inout PlatformInfo) {
    if addr == 0 { return }
    if addr < platform.ramBase { return }
    if addr + 0x1000 > platform.ramBase + platform.ramSize { return }

    var candidate = PlatformInfo()
    if tryParseSmp(addr, into: &candidate) &&
       candidate.haveCpuTopology &&
       (candidate.cpuCount > best.cpuCount ||
        (candidate.cpuCount == best.cpuCount &&
         candidate.havePsci && !best.havePsci)) {
        best = candidate
    }
}

private func tryParseSmp(_ addr: UInt, into info: inout PlatformInfo) -> Bool {
    if !tryParse(addr, into: &info) { return false }
    guard let p = UnsafePointer<UInt8>(bitPattern: addr) else {
        info.reset()
        return false
    }
    fdtParseSmpInto(p, &info)
    return info.valid
}

func platformCpuAff0(_ index: UInt32) -> UInt32 {
    switch index {
    case 0: return platform.cpuAff0_0
    case 1: return platform.cpuAff0_1
    case 2: return platform.cpuAff0_2
    case 3: return platform.cpuAff0_3
    case 4: return platform.cpuAff0_4
    case 5: return platform.cpuAff0_5
    case 6: return platform.cpuAff0_6
    case 7: return platform.cpuAff0_7
    default: return UInt32.max
    }
}

func platformCpuUsesPsci(_ index: UInt32) -> Bool {
    let aff0 = platformCpuAff0(index)
    if aff0 >= smpMaxCpuCount() { return false }
    return (platform.cpuPsciEnableMask & (UInt32(1) << aff0)) != 0
}
