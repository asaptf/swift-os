// SPDX-License-Identifier: Apache-2.0
// gic.swift — minimal GICv2 driver for QEMU `virt`.

// Distributor and CPU-interface bases, discovered into the HAL (QEMU `virt`
// defaults 0x0800_0000 / 0x0801_0000). Computed so they track platformInit.
private var gicdBase: UInt { platform.gicDist }
private var giccBase: UInt { platform.gicCpu }

private let gicdCtlr: UInt = 0x000
private let gicdIcenabler: UInt = 0x180
private let gicdIsenabler: UInt = 0x100
private let gicdIpriorityr: UInt = 0x400
private let gicdItargetsr: UInt = 0x800
private let gicdIcfgr: UInt = 0xC00
private let gicdSgir: UInt = 0xF00

private let giccCtlr: UInt = 0x000
private let giccPmr: UInt = 0x004
private let giccIar: UInt = 0x00C
private let giccEoir: UInt = 0x010

let gicSpuriousInterrupt: UInt32 = 1023
let smpIpiInterruptId: UInt32 = 1

func gicInit() {
    mmio_write32(gicdBase + gicdCtlr, 0)
    gicInitCpuInterfaceForCurrentCpu()

    // Enable both groups. On the non-secure GICv2 view, bit 0 enables Group 1.
    mmio_write32(gicdBase + gicdCtlr, 0x3)
    gicInitCpuInterfaceForCurrentCpu()
}

func gicInitCpuInterfaceForCurrentCpu() {
    mmio_write32(giccBase + giccCtlr, 0)
    mmio_write32(giccBase + giccPmr, 0xFF)
    mmio_write32(giccBase + giccCtlr, 0x3)
    gicEnableInterrupt(smpIpiInterruptId)
}

func gicEnableInterrupt(_ id: UInt32) {
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
    let disableAddr = gicdBase + gicdIcenabler + UInt((id / 32) * 4)
    mmio_write32(disableAddr, UInt32(1) << UInt32(id % 32))
}

func gicAcknowledge() -> UInt32 {
    mmio_read32(giccBase + giccIar)
}

func gicEndInterrupt(_ interruptAck: UInt32) {
    mmio_write32(giccBase + giccEoir, interruptAck)
}

func gicSoftwareGeneratedInterruptSource(_ interruptAck: UInt32) -> UInt32 {
    (interruptAck >> 10) & 0x7
}

private func gicBuildSgirValue(id: UInt32, targetMask: UInt32) -> UInt32 {
    // GICD_SGIR target-list mode: SGIINTID[3:0], CPUTargetList[23:16],
    // TargetListFilter[25:24] = 0b00. QEMU 11.0.1 arm_gic.c handles this at
    // distributor offset 0xf00 and maps CPUTargetList bits to CPU interfaces.
    (id & 0xF) | ((targetMask & 0xFF) << 16)
}

func gicSendSoftwareGeneratedInterrupt(_ id: UInt32, targetMask: UInt32) -> Bool {
    if id >= 16 { return false }
    let mask = targetMask & 0xFF
    if mask == 0 { return false }

    smpStoreBarrier()
    mmio_write32(gicdBase + gicdSgir, gicBuildSgirValue(id: id, targetMask: mask))
    smpMemoryBarrier()
    return true
}

func gicSendSoftwareGeneratedInterruptToCpu(_ id: UInt32, _ cpu: UInt32) -> Bool {
    if cpu >= 8 { return false }
    return gicSendSoftwareGeneratedInterrupt(id, targetMask: UInt32(1) << cpu)
}

func gicSoftwareGeneratedInterruptSelfTest() -> Bool {
    if gicdSgir != 0xF00 { return false }
    if smpIpiInterruptId >= 16 { return false }
    if gicBuildSgirValue(id: 1, targetMask: 0x01) != 0x0001_0001 { return false }
    if gicBuildSgirValue(id: 7, targetMask: 0xA5) != 0x00A5_0007 { return false }
    if gicSoftwareGeneratedInterruptSource(0x0000_0801) != 2 { return false }
    return true
}
