// platform.swift - the hardware abstraction layer (HAL).
//
// One global `Platform` holds the device addresses and IRQ numbers the kernel
// drivers need. It starts at QEMU `virt` defaults so early boot (the banner,
// the panic path) works before discovery runs, then `platformInit` overrides
// the fields it can read from the flattened device tree the firmware/QEMU
// passes in x0. Drivers read from `platform` instead of hardcoding constants,
// which is what lets the same kernel boot under UEFI / a different board.

@_alignment(16) struct Platform {
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
