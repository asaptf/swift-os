// SPDX-License-Identifier: Apache-2.0
// acpi.swift — minimal ACPI platform discovery for the H-series bare-metal arc.
//
// The Hetzner ARM cloud VM (and QEMU `virt` in its default ACPI mode) presents
// no FDT — H0 confirmed the firmware publishes only ACPI. This parser walks the
// RSDP → XSDT → table set the UEFI loader forwards (RSDP pointer in x6) and
// derives the platform map the kernel needs: the GIC (MADT), the PCIe ECAM
// (MCFG), the console UART (SPCR), the CPU topology (MADT GICC entries), and the
// PSCI conduit (FADT). It fills the same `PlatformInfo` the FDT parser produces,
// so `platformInit` applies either source uniformly.
//
// Like the FDT parser this runs with the MMU off, where unaligned multi-byte
// accesses to Device-typed RAM fault. Every field is therefore assembled from
// byte loads routed through a non-inlined `rd8`, so each access stays byte-sized.

@inline(never) @_optimize(none)
private func rd8(_ p: UInt, _ off: UInt) -> UInt8 {
    return UnsafePointer<UInt8>(bitPattern: p + off)!.pointee
}
private func rd16(_ p: UInt, _ o: UInt) -> UInt16 {
    UInt16(rd8(p, o)) | (UInt16(rd8(p, o + 1)) << 8)
}
private func rd32(_ p: UInt, _ o: UInt) -> UInt32 {
    UInt32(rd8(p, o)) | (UInt32(rd8(p, o + 1)) << 8)
        | (UInt32(rd8(p, o + 2)) << 16) | (UInt32(rd8(p, o + 3)) << 24)
}
private func rd64(_ p: UInt, _ o: UInt) -> UInt64 {
    UInt64(rd32(p, o)) | (UInt64(rd32(p, o + 4)) << 32)
}

// True if the 4-byte signature at table `t` equals `s`.
private func sigEquals(_ t: UInt, _ s: StaticString) -> Bool {
    if s.utf8CodeUnitCount != 4 { return false }
    let sp = s.utf8Start
    var i: UInt = 0
    while i < 4 {
        if rd8(t, i) != sp[Int(i)] { return false }
        i += 1
    }
    return true
}

// ACPI System Description Table header is 36 bytes: Signature(4) Length(u32 @4)
// Revision(1) Checksum(1) OEMID(6) ... The table body follows at offset 36.
private let sdtHeaderLen: UInt = 36

// --- MADT (signature "APIC") interrupt-controller structures -----------------
private func parseMadt(_ t: UInt, into info: inout PlatformInfo) {
    let length = UInt(rd32(t, 4))
    // body: LocalInterruptControllerAddress(u32 @36) Flags(u32 @40), structures @44
    var off: UInt = 44
    var cpu = 0
    while off + 2 <= length {
        let type = rd8(t, off)
        let slen = UInt(rd8(t, off + 1))
        if slen < 2 { break }
        switch type {
        case 0x0B:   // GIC CPU Interface (GICC)
            // +8 ACPIProcessorUID(u32) +12 Flags(u32) ... +24 MPIDR? layout:
            // ACPI GICC: +0 type +1 len +2 reserved(2) +4 CPUInterfaceNumber(u32)
            // +8 ACPIProcessorUID(u32) +12 Flags(u32) +16 ParkingProtocol(u32)
            // +20 PerformanceGSIV(u32) +24 ParkedAddress(u64) +32 PhysicalBase(u64)
            // +40 GICV(u64) +48 GICH(u64) +56 VGICMaintenanceGSIV(u32)
            // +60 GICRBaseAddress(u64) +68 MPIDR(u64) ...
            let flags = rd32(t, off + 12)
            if (flags & 1) != 0 && cpu < 8 {   // Enabled
                let mpidr = rd64(t, off + 68)
                let aff0 = UInt32(mpidr & 0xFF)
                setCpuAff(&info, cpu, aff0)
                if aff0 < 32 { info.cpuPsciEnableMask |= UInt32(1) << aff0 }  // PSCI-released
                cpu += 1
                // Prefer the GICR base advertised per-CPU (GICv3) if we lack one.
                if !info.gicIsV3 {
                    let gicr = rd64(t, off + 60)
                    if gicr != 0 { info.gicCpu = UInt(gicr); info.gicIsV3 = true }
                }
            }
        case 0x0C:   // GIC Distributor (GICD)
            // +8 GICD PhysicalBaseAddress(u64) +16 SystemVectorBase(u32) +20 Version(u8)
            info.gicDist = UInt(rd64(t, off + 8))
            info.haveGic = true
            let version = rd8(t, off + 20)
            if version >= 3 { info.gicIsV3 = true }
        case 0x0E:   // GIC Redistributor (GICR)
            // +4 DiscoveryRangeBaseAddress(u64) +12 RangeLength(u32)
            let gicr = UInt(rd64(t, off + 4))
            if gicr != 0 { info.gicCpu = gicr; info.gicIsV3 = true }
        default:
            break
        }
        off += slen
    }
    if cpu > 0 {
        info.cpuCount = UInt32(cpu)
        info.haveCpuTopology = true
    }
}

private func setCpuAff(_ info: inout PlatformInfo, _ idx: Int, _ aff0: UInt32) {
    switch idx {
    case 0: info.cpuAff0_0 = aff0
    case 1: info.cpuAff0_1 = aff0
    case 2: info.cpuAff0_2 = aff0
    case 3: info.cpuAff0_3 = aff0
    case 4: info.cpuAff0_4 = aff0
    case 5: info.cpuAff0_5 = aff0
    case 6: info.cpuAff0_6 = aff0
    case 7: info.cpuAff0_7 = aff0
    default: break
    }
}

// --- MCFG (signature "MCFG"): PCIe ECAM ------------------------------------
// Writes platform.pcieEcamBase directly (a single aligned global UInt store, safe
// with the MMU off) rather than via PlatformInfo — adding a field to that struct
// perturbs its layout and triggers unaligned vectorized stores under strict-align.
private func parseMcfg(_ t: UInt) {
    // header(36) + reserved(8); allocation entries @44, 16 bytes each:
    // BaseAddress(u64) PCISegment(u16) StartBus(u8) EndBus(u8) reserved(u32).
    let length = UInt(rd32(t, 4))
    if 44 + 8 <= length {
        let ecam = UInt(rd64(t, 44))
        if ecam != 0 { platform.pcieEcamBase = ecam }
    }
}

// --- SPCR (signature "SPCR"): console UART ---------------------------------
private func parseSpcr(_ t: UInt, into info: inout PlatformInfo) {
    // +36 InterfaceType(u8) +37 reserved(3) +40 BaseAddress = Generic Address
    // Structure: AddressSpaceId(u8) BitWidth(u8) BitOffset(u8) AccessSize(u8)
    // Address(u64 @44).
    let addr = UInt(rd64(t, 44))
    if addr != 0 {
        info.uartBase = addr
        info.haveUart = true
        // PL011 on virt/Hetzner is SPI 1 → INTID 33 (matches the FDT path default).
        info.uartIrq = 33
        info.haveUartIrq = true
    }
}

// --- FADT (signature "FACP"): PSCI conduit ---------------------------------
private func parseFadt(_ t: UInt, into info: inout PlatformInfo) {
    // ARM Boot Architecture Flags (u16 @129): bit0 PSCI_COMPLIANT, bit1 PSCI_USE_HVC.
    let length = UInt(rd32(t, 4))
    if 131 <= length {
        let armFlags = rd16(t, 129)
        if (armFlags & 1) != 0 {   // PSCI compliant
            info.psciMethod = (armFlags & 2) != 0 ? platformPsciMethodHvc : platformPsciMethodSmc
            info.psciCpuOn = 0xC400_0003   // PSCI_CPU_ON (the standard AArch64 fn id)
            info.havePsci = true
        }
    }
}

/// Parse the ACPI tables the loader pointed us at and fill `info`. Returns true
/// only when a usable GIC was found (the minimum to drive the board). Uses
/// byte-wise reads so it is safe with the MMU off.
func acpiParse(_ rsdp: UInt, into info: inout PlatformInfo) -> Bool {
    if rsdp == 0 { return false }
    if !sigEquals(rsdp, "RSD ") { return false }   // "RSD PTR " — first 4 bytes
    // RSDP: Revision(u8 @15); XsdtAddress(u64 @24) for revision >= 2.
    let revision = rd8(rsdp, 15)
    let xsdt: UInt
    if revision >= 2 {
        xsdt = UInt(rd64(rsdp, 24))
    } else {
        xsdt = UInt(rd32(rsdp, 16))   // RsdtAddress (32-bit table pointers)
    }
    if xsdt == 0 { return false }
    let use64 = revision >= 2
    if use64 && !sigEquals(xsdt, "XSDT") { return false }
    if !use64 && !sigEquals(xsdt, "RSDT") { return false }

    let length = UInt(rd32(xsdt, 4))
    let entrySize: UInt = use64 ? 8 : 4
    var off: UInt = sdtHeaderLen
    while off + entrySize <= length {
        let t = use64 ? UInt(rd64(xsdt, off)) : UInt(rd32(xsdt, off))
        off += entrySize
        if t == 0 { continue }
        if sigEquals(t, "APIC") { parseMadt(t, into: &info) }
        else if sigEquals(t, "MCFG") { parseMcfg(t) }
        else if sigEquals(t, "SPCR") { parseSpcr(t, into: &info) }
        else if sigEquals(t, "FACP") { parseFadt(t, into: &info) }
    }

    info.valid = info.haveGic
    return info.haveGic
}
