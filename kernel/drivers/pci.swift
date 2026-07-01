// SPDX-License-Identifier: Apache-2.0
// pci.swift — minimal PCIe ECAM enumeration for the virtio-PCI transport (H2).
//
// The QEMU `virt` board (with `-cpu max`) and the Hetzner ARM cloud VM expose
// virtio devices over PCIe, not virtio-mmio. This file scans PCI configuration
// space through the ECAM window, sizes and assigns BARs (under `-kernel` direct
// boot there is no firmware to program them; under UEFI we reuse the firmware's
// assignment), and parses the virtio-pci vendor capabilities that point at the
// modern device structures. virtio_transport.swift turns that into a working
// virtqueue; the device drivers (virtio-rng first) stay transport-agnostic.
//
// Scope: enough to find a modern virtio 1.0 device on bus 0 and resolve its
// COMMON / NOTIFY / ISR / DEVICE config structures. No bridges, no MSI-X, no
// multi-bus recursion (QEMU virt / the VM put virtio functions on bus 0).

let PCI_VENDOR_VIRTIO: UInt16 = 0x1AF4

// Config-space register offsets.
private let CFG_VENDOR: UInt32 = 0x00
private let CFG_DEVICE: UInt32 = 0x02
private let CFG_COMMAND: UInt32 = 0x04
private let CFG_STATUS: UInt32 = 0x06
private let CFG_CAP_PTR: UInt32 = 0x34
private let CFG_BAR0: UInt32 = 0x10
private let CFG_SUBSYSTEM_ID: UInt32 = 0x2E   // legacy/transitional: virtio device type
private let CFG_HEADER_TYPE: UInt32 = 0x0E    // bit 7 = multifunction, bits 0..6 = layout
private let CFG_SECONDARY_BUS: UInt32 = 0x19  // header type 1 (PCI-to-PCI bridge)
private let HEADER_TYPE_BRIDGE: UInt8 = 1

private let CMD_MEM_SPACE: UInt16 = 1 << 1
private let CMD_BUS_MASTER: UInt16 = 1 << 2
private let STATUS_CAP_LIST: UInt16 = 1 << 4

// PCI capability IDs.
private let CAP_ID_VENDOR: UInt8 = 0x09

// virtio-pci capability cfg_type values (virtio 1.0 §4.1.4).
let VIRTIO_PCI_CAP_COMMON_CFG: UInt8 = 1
let VIRTIO_PCI_CAP_NOTIFY_CFG: UInt8 = 2
let VIRTIO_PCI_CAP_ISR_CFG: UInt8 = 3
let VIRTIO_PCI_CAP_DEVICE_CFG: UInt8 = 4

// virtio-pci device id ranges: modern devices use 0x1040 + virtio device type;
// transitional/legacy devices use 0x1000..0x103F and carry the virtio type in
// the PCI Subsystem ID. Both expose the modern capability structures, so the
// modern transport drives either once we know the type.
private let VIRTIO_PCI_DEVICE_ID_BASE: UInt16 = 0x1040

// The virtio device type of a function (vendor 0x1AF4), or nil if not virtio.
private func pciVirtioDeviceType(_ b: UInt32, _ d: UInt32, _ f: UInt32) -> UInt32? {
    if pciRead16(b, d, f, CFG_VENDOR) != PCI_VENDOR_VIRTIO { return nil }
    let id = pciRead16(b, d, f, CFG_DEVICE)
    if id >= 0x1040 && id <= 0x107F { return UInt32(id - VIRTIO_PCI_DEVICE_ID_BASE) }
    if id >= 0x1000 && id <= 0x103F { return UInt32(pciRead16(b, d, f, CFG_SUBSYSTEM_ID)) }
    return nil
}

// 32-bit PCI MMIO window (QEMU virt: CPU 0x1000_0000..0x3eff_0000, identity-
// mapped pci==cpu). BARs are assigned here so they fall inside the 1 GiB block
// the early MMU map already covers; no high-window mapping is needed.
private let PCI_MMIO32_BASE: UInt = 0x1000_0000
private let PCI_MMIO32_LIMIT: UInt = 0x3eff_0000
private var pciBarNext: UInt = PCI_MMIO32_BASE

/// Resolved modern virtio-pci device: the addresses (in mapped MMIO space) of
/// its config structures. `notifyMultiplier` scales a queue's notify offset.
struct VirtioPciDevice {
    var bus: UInt32 = 0
    var dev: UInt32 = 0
    var fn: UInt32 = 0
    var deviceType: UInt32 = 0
    var common: UInt = 0
    var notify: UInt = 0          // base of the notify structure (per-queue offset added later)
    var notifyMultiplier: UInt32 = 0
    var isr: UInt = 0
    var device: UInt = 0
    var valid: Bool { common != 0 && notify != 0 }
}

// --- ECAM config-space accessors --------------------------------------------

private func pciCfg(_ b: UInt32, _ d: UInt32, _ f: UInt32, _ off: UInt32) -> UInt {
    platform.pcieEcamBase
        + (UInt(b) << 20) + (UInt(d) << 15) + (UInt(f) << 12) + UInt(off)
}
private func pciRead8(_ b: UInt32, _ d: UInt32, _ f: UInt32, _ o: UInt32) -> UInt8 {
    mmio_read8(pciCfg(b, d, f, o))
}
private func pciRead16(_ b: UInt32, _ d: UInt32, _ f: UInt32, _ o: UInt32) -> UInt16 {
    mmio_read16(pciCfg(b, d, f, o))
}
private func pciRead32(_ b: UInt32, _ d: UInt32, _ f: UInt32, _ o: UInt32) -> UInt32 {
    mmio_read32(pciCfg(b, d, f, o))
}
private func pciWrite16(_ b: UInt32, _ d: UInt32, _ f: UInt32, _ o: UInt32, _ v: UInt16) {
    mmio_write16(pciCfg(b, d, f, o), v)
}
private func pciWrite32(_ b: UInt32, _ d: UInt32, _ f: UInt32, _ o: UInt32, _ v: UInt32) {
    mmio_write32(pciCfg(b, d, f, o), v)
}

private func pciBarAlloc(_ size: UInt) -> UInt {
    if size == 0 { return 0 }
    let aligned = (pciBarNext + (size - 1)) & ~(size - 1)
    if aligned + size > PCI_MMIO32_LIMIT { return 0 }
    pciBarNext = aligned + size
    return aligned
}

// Size and (if needed) assign all six BARs of a function into the 32-bit window.
// Returns the assigned/firmware base address of each BAR (0 if absent/IO). A
// 64-bit BAR occupies two slots; the high slot's entry is left 0.
private func pciAssignBars(_ b: UInt32, _ d: UInt32, _ f: UInt32) -> InlineArray<6, UInt> {
    var bars: InlineArray<6, UInt> = .init(repeating: 0)
    // Disable memory decoding while we probe BAR sizes with all-ones writes.
    let cmd = pciRead16(b, d, f, CFG_COMMAND)
    pciWrite16(b, d, f, CFG_COMMAND, cmd & ~CMD_MEM_SPACE)

    var i = 0
    while i < 6 {
        let off = CFG_BAR0 + UInt32(i) * 4
        let orig = pciRead32(b, d, f, off)
        if (orig & 1) != 0 { i += 1; continue }       // I/O BAR — not used by virtio modern
        let is64 = ((orig >> 1) & 0x3) == 2
        let origHi: UInt32 = is64 ? pciRead32(b, d, f, off + 4) : 0

        // Size: write all-ones, read back the writable bits.
        pciWrite32(b, d, f, off, 0xFFFF_FFFF)
        var mask = UInt64(pciRead32(b, d, f, off) & ~UInt32(0xF))
        if is64 {
            pciWrite32(b, d, f, off + 4, 0xFFFF_FFFF)
            mask |= UInt64(pciRead32(b, d, f, off + 4)) << 32
        } else {
            mask |= 0xFFFF_FFFF_0000_0000
        }
        let size = (~mask) &+ 1

        let curBase = UInt(orig & ~UInt32(0xF)) | (UInt(origHi) << 32)
        var base = curBase
        if base == 0 {
            base = pciBarAlloc(UInt(size))   // unassigned (direct -kernel boot)
        }
        pciWrite32(b, d, f, off, UInt32(base & 0xFFFF_FFFF))
        if is64 { pciWrite32(b, d, f, off + 4, UInt32(base >> 32)) }

        bars[i] = base
        i += is64 ? 2 : 1
    }

    // Re-enable memory decoding + bus mastering (DMA for the virtqueues).
    pciWrite16(b, d, f, CFG_COMMAND, (cmd | CMD_MEM_SPACE | CMD_BUS_MASTER))
    return bars
}

// Walk the capability list and fill the virtio config-structure addresses.
private func pciResolveVirtioCaps(_ b: UInt32, _ d: UInt32, _ f: UInt32,
                                  _ bars: InlineArray<6, UInt>,
                                  into out: inout VirtioPciDevice) {
    if (pciRead16(b, d, f, CFG_STATUS) & STATUS_CAP_LIST) == 0 { return }
    var cap = UInt32(pciRead8(b, d, f, CFG_CAP_PTR) & 0xFC)
    var hops = 0
    while cap != 0 && hops < 48 {
        let id = pciRead8(b, d, f, cap)
        let next = UInt32(pciRead8(b, d, f, cap + 1) & 0xFC)
        if id == CAP_ID_VENDOR {
            // virtio_pci_cap: +3 cfg_type, +4 bar, +8 offset(u32), +12 length(u32).
            let cfgType = pciRead8(b, d, f, cap + 3)
            let barIdx = Int(pciRead8(b, d, f, cap + 4))
            let offset = pciRead32(b, d, f, cap + 8)
            if barIdx < 6 && bars[barIdx] != 0 {
                let addr = bars[barIdx] + UInt(offset)
                switch cfgType {
                case VIRTIO_PCI_CAP_COMMON_CFG: out.common = addr
                case VIRTIO_PCI_CAP_NOTIFY_CFG:
                    out.notify = addr
                    out.notifyMultiplier = pciRead32(b, d, f, cap + 16) // notify_off_multiplier
                case VIRTIO_PCI_CAP_ISR_CFG: out.isr = addr
                case VIRTIO_PCI_CAP_DEVICE_CFG: out.device = addr
                default: break
                }
            }
        }
        cap = next
        hops += 1
    }
}

// Resolve a single function known to be the wanted virtio device type.
private func pciResolveFunction(_ b: UInt32, _ d: UInt32, _ f: UInt32,
                                _ deviceType: UInt32) -> VirtioPciDevice? {
    var out = VirtioPciDevice()
    out.bus = b; out.dev = d; out.fn = f; out.deviceType = deviceType
    let bars = pciAssignBars(b, d, f)
    pciResolveVirtioCaps(b, d, f, bars, into: &out)
    return out.valid ? out : nil
}

// Scan one PCI bus for a virtio device of `deviceType`, recursing through any
// PCI-to-PCI bridge (PCIe root port) into its secondary bus. Real cloud VMs
// (Hetzner) place virtio functions behind root ports on non-zero buses — only
// the GPU sits on bus 0 — so a bus-0-only scan misses the NIC/RNG/SCSI. On UEFI
// the firmware has already programmed the bridge secondary-bus numbers and BAR
// windows; we just follow them. `depth` bounds the recursion as a loop guard.
private func pciScanBusForVirtio(_ bus: UInt32, _ deviceType: UInt32, _ depth: Int) -> VirtioPciDevice? {
    if depth > 32 { return nil }
    var d: UInt32 = 0
    while d < 32 {
        if pciRead16(bus, d, 0, CFG_VENDOR) != 0xFFFF {
            let multifn = (pciRead8(bus, d, 0, CFG_HEADER_TYPE) & 0x80) != 0
            let fnCount: UInt32 = multifn ? 8 : 1
            var f: UInt32 = 0
            while f < fnCount {
                if pciRead16(bus, d, f, CFG_VENDOR) != 0xFFFF {
                    if pciVirtioDeviceType(bus, d, f) == deviceType,
                       let found = pciResolveFunction(bus, d, f, deviceType) {
                        return found
                    }
                    // PCI-to-PCI bridge / PCIe root port: descend into its bus.
                    if (pciRead8(bus, d, f, CFG_HEADER_TYPE) & 0x7F) == HEADER_TYPE_BRIDGE {
                        let secondary = UInt32(pciRead8(bus, d, f, CFG_SECONDARY_BUS))
                        if secondary != 0 && secondary != bus,
                           let found = pciScanBusForVirtio(secondary, deviceType, depth + 1) {
                            return found
                        }
                    }
                }
                f += 1
            }
        }
        d += 1
    }
    return nil
}

/// Find a modern virtio-pci device of the given virtio device type (e.g. 4 for
/// RNG, 1 for net), descending through PCIe root ports, assign/resolve its BARs
/// and config structures, and return it. Returns nil if PCI is disabled (no
/// ECAM) or no such device is present.
func virtioPciFindDevice(deviceType: UInt32) -> VirtioPciDevice? {
    if platform.pcieEcamBase == 0 { return nil }
    return pciScanBusForVirtio(0, deviceType, 0)
}

// V4b: collect up to `max` modern virtio-pci devices of `deviceType` in a SINGLE
// pass, filling out[0..<returned]. Unlike virtioPciFindDevice (first match), this
// brings up every matching function — the block driver needs it to enumerate
// several virtio-blk disks (e.g. multiple Hetzner Cloud Volumes). Single-pass is
// essential: pciResolveFunction assigns BARs, so re-scanning per index would
// re-place an already-configured device's BARs. Returns the number found.
func virtioPciCollectDevices(deviceType: UInt32,
                             into out: UnsafeMutablePointer<VirtioPciDevice>, max: Int) -> Int {
    if platform.pcieEcamBase == 0 || max <= 0 { return 0 }
    var count = 0
    pciCollectBusForVirtio(0, deviceType, 0, out, max, &count)
    return count
}

private func pciCollectBusForVirtio(_ bus: UInt32, _ deviceType: UInt32, _ depth: Int,
                                    _ out: UnsafeMutablePointer<VirtioPciDevice>, _ max: Int,
                                    _ count: inout Int) {
    if depth > 32 || count >= max { return }
    var d: UInt32 = 0
    while d < 32 {
        if pciRead16(bus, d, 0, CFG_VENDOR) != 0xFFFF {
            let multifn = (pciRead8(bus, d, 0, CFG_HEADER_TYPE) & 0x80) != 0
            let fnCount: UInt32 = multifn ? 8 : 1
            var f: UInt32 = 0
            while f < fnCount {
                if pciRead16(bus, d, f, CFG_VENDOR) != 0xFFFF {
                    if pciVirtioDeviceType(bus, d, f) == deviceType,
                       let found = pciResolveFunction(bus, d, f, deviceType) {
                        out[count] = found
                        count += 1
                        if count >= max { return }
                    }
                    // Descend through a PCI-to-PCI bridge / PCIe root port.
                    if (pciRead8(bus, d, f, CFG_HEADER_TYPE) & 0x7F) == HEADER_TYPE_BRIDGE {
                        let secondary = UInt32(pciRead8(bus, d, f, CFG_SECONDARY_BUS))
                        if secondary != 0 && secondary != bus {
                            pciCollectBusForVirtio(secondary, deviceType, depth + 1, out, max, &count)
                            if count >= max { return }
                        }
                    }
                }
                f += 1
            }
        }
        d += 1
    }
}

// --- generic class-code discovery (non-virtio controllers, e.g. xHCI) -------

private let CFG_REV_CLASS: UInt32 = 0x08   // rev(8) | progif(8) | subclass(8) | class(8)
private let CFG_INT_PIN: UInt32 = 0x3D     // INTx pin: 1=INTA..4=INTD, 0=none

/// A PCI function located by class code, with all BARs assigned and memory +
/// bus-mastering enabled (pciAssignBars). `bar0` is the CPU-visible MMIO base of
/// BAR0; `intxPin` is the INTx pin the function asserts (0 = none). This is the
/// hook the xHCI driver uses; virtio devices keep using virtioPciFindDevice.
struct PciClassDevice {
    var bus: UInt32 = 0
    var dev: UInt32 = 0
    var fn: UInt32 = 0
    var bar0: UInt = 0
    var intxPin: UInt8 = 0
}

private func pciScanBusForClass(_ bus: UInt32, _ cls: UInt8, _ sub: UInt8,
                                _ progif: UInt8, _ depth: Int) -> PciClassDevice? {
    if depth > 32 { return nil }
    var d: UInt32 = 0
    while d < 32 {
        if pciRead16(bus, d, 0, CFG_VENDOR) != 0xFFFF {
            let multifn = (pciRead8(bus, d, 0, CFG_HEADER_TYPE) & 0x80) != 0
            let fnCount: UInt32 = multifn ? 8 : 1
            var f: UInt32 = 0
            while f < fnCount {
                if pciRead16(bus, d, f, CFG_VENDOR) != 0xFFFF {
                    let rc = pciRead32(bus, d, f, CFG_REV_CLASS)
                    if UInt8((rc >> 24) & 0xFF) == cls,
                       UInt8((rc >> 16) & 0xFF) == sub,
                       UInt8((rc >> 8) & 0xFF) == progif {
                        let bars = pciAssignBars(bus, d, f)
                        if bars[0] != 0 {
                            var out = PciClassDevice()
                            out.bus = bus; out.dev = d; out.fn = f
                            out.bar0 = bars[0]
                            out.intxPin = pciRead8(bus, d, f, CFG_INT_PIN)
                            return out
                        }
                    }
                    // Descend through a PCI-to-PCI bridge / PCIe root port.
                    if (pciRead8(bus, d, f, CFG_HEADER_TYPE) & 0x7F) == HEADER_TYPE_BRIDGE {
                        let secondary = UInt32(pciRead8(bus, d, f, CFG_SECONDARY_BUS))
                        if secondary != 0, secondary != bus,
                           let found = pciScanBusForClass(secondary, cls, sub, progif, depth + 1) {
                            return found
                        }
                    }
                }
                f += 1
            }
        }
        d += 1
    }
    return nil
}

/// Find the first PCI function matching (class, subclass, prog-IF), descending
/// through PCIe root ports; assign its BARs and enable memory + bus-mastering.
/// Returns nil if PCI is disabled (no ECAM) or no such device is present. Used
/// to locate the xHCI USB controller (class 0x0C, subclass 0x03, prog-IF 0x30).
func pciFindByClass(classCode: UInt8, subclass: UInt8, progIf: UInt8) -> PciClassDevice? {
    if platform.pcieEcamBase == 0 { return nil }
    return pciScanBusForClass(0, classCode, subclass, progIf, 0)
}
