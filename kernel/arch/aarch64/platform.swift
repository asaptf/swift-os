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
    // PL011 UART.
    var uartBase: UInt = 0xFFDD_F000
    var uartIrq: UInt32 = 33
    // EL1 physical timer PPI - architectural, not board-specific.
    var timerIrq: UInt32 = 30
    // virtio-mmio transport window (QEMU-style layout; informational on VBox).
    var virtioMmioBase: UInt = 0x0A00_0000
    var virtioMmioStride: UInt = 0x200
    var virtioMmioCount: UInt32 = 32
    // PL031 RTC: unknown on VBox; 0 disables the clock (rtcNow returns 0).
    var rtcBase: UInt = 0
#else
    // Main RAM.
    var ramBase: UInt = 0x4000_0000
    var ramSize: UInt = 0x1000_0000   // 256 MiB (matches `-m 256M`).
    // GICv2 distributor and CPU interface.
    var gicDist: UInt = 0x0800_0000
    var gicCpu: UInt = 0x0801_0000
    // PL011 UART.
    var uartBase: UInt = 0x0900_0000
    var uartIrq: UInt32 = 33          // QEMU virt: SPI 1 -> INTID 33.
    // EL1 physical timer PPI - architectural, not board-specific.
    var timerIrq: UInt32 = 30
    // virtio-mmio transport window (QEMU virt: 32 slots of 0x200 at 0x0A000000).
    var virtioMmioBase: UInt = 0x0A00_0000
    var virtioMmioStride: UInt = 0x200
    var virtioMmioCount: UInt32 = 32
    // PL031 RTC (QEMU virt): data register at base holds Unix time in seconds.
    var rtcBase: UInt = 0x0901_0000
#endif
}

var platform = Platform()

/// Discover the hardware map from the device tree and update `platform`.
///
/// `dtbPhys` is the pointer the boot stub preserved from x0. If it is not a
/// valid DTB we scan RAM for the device tree; if that also fails we keep the
/// compiled-in defaults - the kernel never regresses on a board it already knew.
func platformInit(_ dtbPhys: UInt) {
    var info = PlatformInfo()

    // 1. The pointer the boot stub preserved from x0 (how a UEFI loader and some
    //    boot paths hand off the DTB).
    _ = tryParse(dtbPhys, into: &info)

    // 2. QEMU's direct ELF `-kernel` path does not reliably pass the DTB in x0,
    //    and our run/test harness injects a dumped DTB at a fixed RAM address.
    //    Scan RAM (page-granular) for the FDT magic rather than hardcode that
    //    address; the parser is header-validated, so a stray magic match on
    //    stale bytes cannot fault the kernel.
    if !info.valid {
        var addr = platform.ramBase
        let end = platform.ramBase + platform.ramSize
        while addr + 0x1000 <= end {
            if tryParse(addr, into: &info) { break }
            addr += 0x1000
        }
    }

    guard info.valid else {
        uartPuts("M9 platform: no valid device tree, using QEMU virt defaults\n")
        return
    }

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
        platform.gicCpu = info.gicCpu
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
