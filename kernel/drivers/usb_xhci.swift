// SPDX-License-Identifier: Apache-2.0
// usb_xhci.swift — xHCI USB host-controller bring-up (USB milestone 1).
//
// SwiftOS gets its keyboard from virtio-input; this driver is the first step
// toward a *real* USB keyboard, which needs an xHCI controller on the PCIe bus
// (`-device qemu-xhci`, and the same controller class on the Hetzner VM / real
// hardware). M1 scope is deliberately narrow: locate the controller over PCI
// (pci.swift), reset it, set up the minimum DMA structures the spec requires to
// legally run it (DCBAA, command ring, event ring, scratchpad), start it, and
// then scan the root-hub ports and report any connected device. No enumeration,
// no transfers, no HID yet — those are the next milestones (enable-slot /
// address-device, then the HID boot-protocol interrupt endpoint).
//
// The controller logic here is platform-agnostic: xhciInit() takes only the
// MMIO base pci.swift assigned, so the same code drives QEMU and bare metal.
// DMA structures are PMM pages; the kernel identity-maps RAM, so their physical
// address equals their virtual address and doubles as the bus address QEMU's
// PCIe host forwards 1:1 (exactly as the virtio-pci drivers rely on). Cache
// maintenance mirrors virtio_input.swift: no-ops under TCG, real on hardware.

// xHCI is PCI class 0x0C (serial bus), subclass 0x03 (USB), prog-IF 0x30.
private let XHCI_CLASS: UInt8 = 0x0C
private let XHCI_SUBCLASS: UInt8 = 0x03
private let XHCI_PROGIF: UInt8 = 0x30

// --- Capability registers (at BAR0 base) ------------------------------------
private let CAP_CAPLENGTH: UInt = 0x00   // u8: bytes to operational regs
private let CAP_HCIVERSION: UInt = 0x02  // u16
private let CAP_HCSPARAMS1: UInt = 0x04  // MaxSlots[7:0], MaxIntrs[18:8], MaxPorts[31:24]
private let CAP_HCSPARAMS2: UInt = 0x08  // scratchpad-buffer counts
private let CAP_HCCPARAMS1: UInt = 0x10  // AC64[0], CSZ[2], xECP[31:16]
private let CAP_DBOFF: UInt = 0x14        // doorbell array offset (dword-masked)
private let CAP_RTSOFF: UInt = 0x18       // runtime register space offset

// --- Operational registers (at BAR0 + CAPLENGTH) ----------------------------
private let OP_USBCMD: UInt = 0x00
private let OP_USBSTS: UInt = 0x04
private let OP_PAGESIZE: UInt = 0x08
private let OP_CRCR: UInt = 0x18          // 64-bit
private let OP_DCBAAP: UInt = 0x30        // 64-bit
private let OP_CONFIG: UInt = 0x38
private let OP_PORTSC_BASE: UInt = 0x400  // per-port, stride 0x10

private let USBCMD_RS: UInt32 = 1 << 0
private let USBCMD_HCRST: UInt32 = 1 << 1
private let USBSTS_HCH: UInt32 = 1 << 0    // HC halted
private let USBSTS_CNR: UInt32 = 1 << 11   // controller not ready
private let CRCR_RCS: UInt64 = 1 << 0      // ring cycle state

// PORTSC bits.
private let PORTSC_CCS: UInt32 = 1 << 0    // current connect status
private let PORTSC_PED: UInt32 = 1 << 1    // port enabled
private let PORTSC_PP: UInt32 = 1 << 9     // port power
// Write-1-to-clear change bits (CSC..CEC) + PED — preserve across a RW write.
private let PORTSC_RW1C_MASK: UInt32 = (0x7F << 17) | PORTSC_PED

// --- Interrupter 0 runtime registers (at BAR0 + RTSOFF + 0x20) ---------------
private let RT_IR0: UInt = 0x20
private let IR_ERSTSZ: UInt = 0x08
private let IR_ERSTBA: UInt = 0x10        // 64-bit
private let IR_ERDP: UInt = 0x18          // 64-bit

// A TRB is 16 bytes; one PMM page holds 256 of them.
private let TRBS_PER_RING = 256
private let TRB_TYPE_LINK: UInt32 = 6 << 10   // control dword: TRB type field

private var xhciBase: UInt = 0
private var xhciOp: UInt = 0
private var xhciRt: UInt = 0
private var xhciDb: UInt = 0
private var xhciMaxSlots: UInt32 = 0
private var xhciMaxPorts: UInt32 = 0

// --- register accessors -----------------------------------------------------
private func capR32(_ o: UInt) -> UInt32 { mmio_read32(xhciBase + o) }
private func opR32(_ o: UInt) -> UInt32 { mmio_read32(xhciOp + o) }
private func opW32(_ o: UInt, _ v: UInt32) { mmio_write32(xhciOp + o, v) }
// 64-bit xHCI registers are two 32-bit halves, low written first.
private func opW64(_ o: UInt, _ v: UInt64) {
    mmio_write32(xhciOp + o, UInt32(v & 0xFFFF_FFFF))
    mmio_write32(xhciOp + o + 4, UInt32(v >> 32))
}
private func rtW32(_ o: UInt, _ v: UInt32) { mmio_write32(xhciRt + o, v) }
private func rtW64(_ o: UInt, _ v: UInt64) {
    mmio_write32(xhciRt + o, UInt32(v & 0xFFFF_FFFF))
    mmio_write32(xhciRt + o + 4, UInt32(v >> 32))
}
private func portSC(_ port: UInt32) -> UInt {
    xhciOp + OP_PORTSC_BASE + UInt(port - 1) * 0x10
}

// --- cache maintenance (DMA structures), mirroring virtio_input.swift -------
private func xhciClean(_ pa: UInt, _ n: Int) {
    var a = pa & ~UInt(63)
    let end = pa + UInt(n)
    while a < end { dc_cvac(a); a += 64 }
    dsb_sy()
}
private func xhciZeroPage(_ pa: UInt) {
    let p = UnsafeMutableRawPointer(bitPattern: pa)!
    var i = 0
    while i < 4096 { p.storeBytes(of: UInt8(0), toByteOffset: i, as: UInt8.self); i += 1 }
}

// Poll an operational register until (value & mask) == want, bounded so a wedged
// controller can never hang the boot. Returns true if the condition was met.
private func opWaitMasked(_ o: UInt, _ mask: UInt32, _ want: UInt32) -> Bool {
    var spins = 0
    while spins < 1_000_000 {
        if (opR32(o) & mask) == want { return true }
        spins += 1
    }
    return false
}

// Bring the controller up to the running state. Returns false if it never
// becomes ready, reset never completes, or it refuses to leave the halted state.
private func xhciStartController() -> Bool {
    // 1. Wait for CNR to clear, then halt the controller before resetting.
    if !opWaitMasked(OP_USBSTS, USBSTS_CNR, 0) { return false }
    if (opR32(OP_USBSTS) & USBSTS_HCH) == 0 {
        opW32(OP_USBCMD, opR32(OP_USBCMD) & ~USBCMD_RS)
        if !opWaitMasked(OP_USBSTS, USBSTS_HCH, USBSTS_HCH) { return false }
    }

    // 2. Reset: set HCRST, wait for it (and CNR) to clear.
    opW32(OP_USBCMD, USBCMD_HCRST)
    if !opWaitMasked(OP_USBCMD, USBCMD_HCRST, 0) { return false }
    if !opWaitMasked(OP_USBSTS, USBSTS_CNR, 0) { return false }

    // 3. Enable all device slots the controller supports.
    opW32(OP_CONFIG, xhciMaxSlots)

    // 4. Device Context Base Address Array (one zeroed page; entry 0 may point
    //    at the scratchpad buffer array if the controller demands scratchpad).
    let dcbaa = pmm_alloc_page()
    if dcbaa == 0 { return false }
    xhciZeroPage(dcbaa)
    if !xhciSetupScratchpad(dcbaa) { return false }
    xhciClean(dcbaa, 4096)
    opW64(OP_DCBAAP, UInt64(dcbaa))

    // 5. Command ring: one page, last TRB a Link back to the start with Toggle
    //    Cycle so the ring is valid even though M1 issues no commands.
    let cmdRing = pmm_alloc_page()
    if cmdRing == 0 { return false }
    xhciZeroPage(cmdRing)
    let link = UnsafeMutableRawPointer(bitPattern: cmdRing + UInt((TRBS_PER_RING - 1) * 16))!
    link.storeBytes(of: UInt64(cmdRing), toByteOffset: 0, as: UInt64.self)
    link.storeBytes(of: UInt32(0), toByteOffset: 8, as: UInt32.self)
    link.storeBytes(of: TRB_TYPE_LINK | (1 << 1) /* TC */, toByteOffset: 12, as: UInt32.self)
    xhciClean(cmdRing, 4096)
    opW64(OP_CRCR, UInt64(cmdRing) | CRCR_RCS)

    // 6. Event ring (interrupter 0): one segment + a one-entry segment table.
    let evtRing = pmm_alloc_page()
    let erst = pmm_alloc_page()
    if evtRing == 0 || erst == 0 { return false }
    xhciZeroPage(evtRing)
    xhciZeroPage(erst)
    let e = UnsafeMutableRawPointer(bitPattern: erst)!
    e.storeBytes(of: UInt64(evtRing), toByteOffset: 0, as: UInt64.self)      // ring segment base
    e.storeBytes(of: UInt32(TRBS_PER_RING), toByteOffset: 8, as: UInt32.self) // segment size
    e.storeBytes(of: UInt32(0), toByteOffset: 12, as: UInt32.self)
    xhciClean(evtRing, 4096)
    xhciClean(erst, 4096)
    rtW32(RT_IR0 + IR_ERSTSZ, 1)
    rtW64(RT_IR0 + IR_ERDP, UInt64(evtRing))
    rtW64(RT_IR0 + IR_ERSTBA, UInt64(erst))   // last: arms the interrupter

    // 7. Run. The controller clears HCH once it is actually running.
    opW32(OP_USBCMD, opR32(OP_USBCMD) | USBCMD_RS)
    if !opWaitMasked(OP_USBSTS, USBSTS_HCH, 0) { return false }
    return true
}

// Some controllers require the driver to provide scratchpad buffers; QEMU's
// xHCI reports zero, but real hardware may not. Allocate the buffer-pointer
// array and the buffers, and publish the array in DCBAA[0]. Returns false only
// on allocation failure.
private func xhciSetupScratchpad(_ dcbaa: UInt) -> Bool {
    let sp2 = capR32(CAP_HCSPARAMS2)
    let hi = (sp2 >> 21) & 0x1F
    let lo = (sp2 >> 27) & 0x1F
    let count = Int((hi << 5) | lo)
    if count == 0 { return true }
    if count > 512 { return false }   // would overflow one page of 8-byte pointers
    let array = pmm_alloc_page()
    if array == 0 { return false }
    xhciZeroPage(array)
    let ap = UnsafeMutableRawPointer(bitPattern: array)!
    var i = 0
    while i < count {
        let buf = pmm_alloc_page()
        if buf == 0 { return false }
        xhciZeroPage(buf)
        xhciClean(buf, 4096)
        ap.storeBytes(of: UInt64(buf), toByteOffset: i * 8, as: UInt64.self)
        i += 1
    }
    xhciClean(array, 4096)
    UnsafeMutableRawPointer(bitPattern: dcbaa)!.storeBytes(of: UInt64(array), toByteOffset: 0, as: UInt64.self)
    return true
}

// Power on every root-hub port and report any with a device attached. Returns
// the number of connected ports. Detection is the M1 acceptance criterion.
private func xhciScanPorts() -> Int {
    var connected = 0
    var port: UInt32 = 1
    while port <= xhciMaxPorts {
        let reg = portSC(port)
        // Power the port (preserving the write-1-to-clear change bits), then give
        // the connect status a bounded settle window.
        var v = mmio_read32(reg)
        if (v & PORTSC_PP) == 0 {
            mmio_write32(reg, (v & ~PORTSC_RW1C_MASK) | PORTSC_PP)
        }
        var spins = 0
        while (mmio_read32(reg) & PORTSC_CCS) == 0 && spins < 100_000 { spins += 1 }
        v = mmio_read32(reg)
        if (v & PORTSC_CCS) != 0 {
            connected += 1
            let speed = (v >> 10) & 0xF
            uartPuts("USB1: device connected on xHCI port ")
            uartPutUInt(UInt64(port))
            uartPuts(" speed ")
            uartPutUInt(UInt64(speed))
            uartPuts(v & PORTSC_PED != 0 ? " (enabled)\n" : "\n")
        }
        port += 1
    }
    return connected
}

/// Bring up the xHCI controller at `bar0` and detect attached devices.
/// Returns true if the controller reached the running state.
func xhciInit(_ bar0: UInt) -> Bool {
    xhciBase = bar0
    let capLen = UInt(mmio_read8(xhciBase + CAP_CAPLENGTH))
    xhciOp = xhciBase + capLen
    xhciRt = xhciBase + UInt(capR32(CAP_RTSOFF) & ~UInt32(0x1F))
    xhciDb = xhciBase + UInt(capR32(CAP_DBOFF) & ~UInt32(0x3))

    let hcs1 = capR32(CAP_HCSPARAMS1)
    xhciMaxSlots = hcs1 & 0xFF
    xhciMaxPorts = (hcs1 >> 24) & 0xFF
    // HCIVERSION is the upper half of the CAPLENGTH dword; read it via a 32-bit
    // access since QEMU's xHCI cap region rejects sub-word reads (returns 0).
    let ver = (capR32(0x00) >> 16) & 0xFFFF

    uartPuts("USB1: xHCI ")
    uartPutHex(UInt(ver))
    uartPuts(" at ")
    uartPutHex(bar0)
    uartPuts(" slots ")
    uartPutUInt(UInt64(xhciMaxSlots))
    uartPuts(" ports ")
    uartPutUInt(UInt64(xhciMaxPorts))
    uartPuts("\n")

    if !xhciStartController() {
        uartPuts("USB1: xHCI controller failed to start\n")
        return false
    }
    let connected = xhciScanPorts()
    uartPuts("USB1 OK: xHCI up, ")
    uartPutUInt(UInt64(connected))
    uartPuts(" device(s) connected\n")
    return true
}

/// Top-level USB probe: find the xHCI controller on PCI and bring it up. No-op
/// (with a log line) when no controller is present, so it is safe on every boot.
func usbProbe() {
    guard let xhci = pciFindByClass(classCode: XHCI_CLASS, subclass: XHCI_SUBCLASS, progIf: XHCI_PROGIF) else {
        uartPuts("USB1: no xHCI controller found\n")
        return
    }
    _ = xhciInit(xhci.bar0)
}
