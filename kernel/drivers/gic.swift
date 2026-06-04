// gic.swift — minimal GICv2 driver for QEMU `virt`.

private let gicdBase: UInt = 0x0800_0000
private let giccBase: UInt = 0x0801_0000

private let gicdCtlr: UInt = 0x000
private let gicdIcenabler: UInt = 0x180
private let gicdIsenabler: UInt = 0x100
private let gicdIpriorityr: UInt = 0x400
private let gicdIcfgr: UInt = 0xC00

private let giccCtlr: UInt = 0x000
private let giccPmr: UInt = 0x004
private let giccIar: UInt = 0x00C
private let giccEoir: UInt = 0x010

let gicSpuriousInterrupt: UInt32 = 1023

func gicInit() {
    mmio_write32(gicdBase + gicdCtlr, 0)
    mmio_write32(giccBase + giccCtlr, 0)
    mmio_write32(giccBase + giccPmr, 0xFF)

    // Enable both groups. On the non-secure GICv2 view, bit 0 enables Group 1.
    mmio_write32(gicdBase + gicdCtlr, 0x3)
    mmio_write32(giccBase + giccCtlr, 0x3)
}

func gicEnableInterrupt(_ id: UInt32) {
    let priorityAddr = gicdBase + gicdIpriorityr + UInt(id)
    mmio_write32(priorityAddr & ~UInt(3), 0x8080_8080)

    // Level-triggered, active-high. Timer PPIs are banked, so no target setup.
    let cfgAddr = gicdBase + gicdIcfgr + UInt((id / 16) * 4)
    let shift = UInt((id % 16) * 2)
    let cfg = mmio_read32(cfgAddr) & ~(UInt32(0x3) << UInt32(shift))
    mmio_write32(cfgAddr, cfg)

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
