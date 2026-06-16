// SPDX-License-Identifier: Apache-2.0
// fdt.swift - a minimal flattened-device-tree (FDT/DTB) reader.
//
// QEMU `-kernel` hands the kernel a pointer to a flattened device tree in x0.
// The DTB describes the actual hardware map (RAM, UART, interrupt controller),
// which lets us discover those addresses at runtime instead of hardcoding the
// QEMU `virt` constants - a prerequisite for UEFI boot and any non-QEMU host.
//
// This reader is deliberately pure: it touches no MMIO, no UART, and no heap,
// so the same code compiles for the kernel (Embedded Swift) and for a host unit
// test (full Swift) - see tests/fdt_test.swift. It extracts only what bring-up
// needs: the /memory reg, the PL011 UART reg + IRQ, the GICv2 dist/CPU regs,
// virtio-mmio slots, and the S0f/S0g /cpus + PSCI discovery scaffold.
//
// FDT format reference: the Devicetree Specification, section "Flattened
// Devicetree (DTB) Format". All header and token fields are big-endian u32.

// FDT structure-block tokens.
private let fdtBeginNode: UInt32 = 1
private let fdtEndNode: UInt32 = 2
private let fdtProp: UInt32 = 3
private let fdtNop: UInt32 = 4
private let fdtEnd: UInt32 = 9

private let fdtMagic: UInt32 = 0xd00d_feed

private let platformInfoValid: UInt32 = 1 << 0
private let platformInfoHaveRam: UInt32 = 1 << 1
private let platformInfoHaveUart: UInt32 = 1 << 2
private let platformInfoHaveUartIrq: UInt32 = 1 << 3
private let platformInfoHaveGic: UInt32 = 1 << 4
private let platformInfoHaveVirtio: UInt32 = 1 << 5
private let platformInfoHaveCpuTopology: UInt32 = 1 << 6
private let platformInfoHavePsci: UInt32 = 1 << 7
// H1: the GIC node is "arm,gic-v3" — its second reg range is the redistributor
// base, not a GICC window. Kept in the flags word (not a stored Bool) so the
// struct stays 8-byte aligned for the MMU-off early parse (strict-align).
private let platformInfoGicV3: UInt32 = 1 << 8

private let platformMaxCpuSlots = 8

let platformCpuEnableUnknown: UInt32 = 0
let platformCpuEnablePsci: UInt32 = 1

let platformPsciMethodNone: UInt32 = 0
let platformPsciMethodHvc: UInt32 = 1
let platformPsciMethodSmc: UInt32 = 2

/// Hardware constants discovered from the device tree. Fields are only valid
/// when their matching `have*` flag is set; the caller keeps its defaults
/// otherwise so a missing or partial DTB never regresses a known-good board.
///
/// Keep the stored layout naturally aligned. The kernel builds with strict
/// alignment checking, and returning this struct by value must not make Swift
/// generate unaligned stack loads/stores.
struct PlatformInfo {
    var ramBase: UInt = 0
    var ramSize: UInt = 0
    var gicDist: UInt = 0
    var gicCpu: UInt = 0
    var uartBase: UInt = 0
    // virtio-mmio device window. QEMU virt exposes a contiguous bank of
    // identical "virtio,mmio" transport slots; we capture the lowest base, the
    // per-slot stride (each reg size), and how many slots there are so the
    // block driver can scan the bank for the device it wants.
    var virtioBase: UInt = 0
    var virtioStride: UInt = 0
    // 32-bit fields grouped after the pointers: the parser runs before the MMU
    // is enabled (RAM is Device-typed then), so the layout must stay naturally
    // aligned or a wide unaligned load would fault.
    var uartIrq: UInt32 = 0
    var virtioCount: UInt32 = 0
    var cpuCount: UInt32 = 0
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
    private var flags: UInt32 = 0

    var valid: Bool {
        get { (flags & platformInfoValid) != 0 }
        set { setFlag(platformInfoValid, newValue) }
    }
    var haveRam: Bool {
        get { (flags & platformInfoHaveRam) != 0 }
        set { setFlag(platformInfoHaveRam, newValue) }
    }
    var haveUart: Bool {
        get { (flags & platformInfoHaveUart) != 0 }
        set { setFlag(platformInfoHaveUart, newValue) }
    }
    var haveUartIrq: Bool {
        get { (flags & platformInfoHaveUartIrq) != 0 }
        set { setFlag(platformInfoHaveUartIrq, newValue) }
    }
    var gicIsV3: Bool {
        get { (flags & platformInfoGicV3) != 0 }
        set { setFlag(platformInfoGicV3, newValue) }
    }
    var haveGic: Bool {
        get { (flags & platformInfoHaveGic) != 0 }
        set { setFlag(platformInfoHaveGic, newValue) }
    }
    var haveVirtio: Bool {
        get { (flags & platformInfoHaveVirtio) != 0 }
        set { setFlag(platformInfoHaveVirtio, newValue) }
    }
    var haveCpuTopology: Bool {
        get { (flags & platformInfoHaveCpuTopology) != 0 }
        set { setFlag(platformInfoHaveCpuTopology, newValue) }
    }
    var havePsci: Bool {
        get { (flags & platformInfoHavePsci) != 0 }
        set { setFlag(platformInfoHavePsci, newValue) }
    }

    func cpuAff0(_ index: UInt32) -> UInt32 {
        switch index {
        case 0: return cpuAff0_0
        case 1: return cpuAff0_1
        case 2: return cpuAff0_2
        case 3: return cpuAff0_3
        case 4: return cpuAff0_4
        case 5: return cpuAff0_5
        case 6: return cpuAff0_6
        case 7: return cpuAff0_7
        default: return UInt32.max
        }
    }

    mutating func appendCpuAff0(_ aff0: UInt32) {
        if cpuCount >= UInt32(platformMaxCpuSlots) { return }

        var i: UInt32 = 0
        while i < cpuCount {
            if cpuAff0(i) == aff0 { return }
            i += 1
        }

        setCpuAff0(cpuCount, aff0)
        cpuCount += 1
        haveCpuTopology = true
    }

    mutating func markCpuEnableMethod(_ aff0: UInt32, _ method: UInt32) {
        if aff0 >= UInt32(platformMaxCpuSlots) { return }
        if method == platformCpuEnablePsci {
            cpuPsciEnableMask |= UInt32(1) << aff0
        }
    }

    func cpuUsesPsci(_ index: UInt32) -> Bool {
        let aff0 = cpuAff0(index)
        if aff0 >= UInt32(platformMaxCpuSlots) { return false }
        return (cpuPsciEnableMask & (UInt32(1) << aff0)) != 0
    }

    private mutating func setFlag(_ flag: UInt32, _ enabled: Bool) {
        if enabled {
            flags |= flag
        } else {
            flags &= ~flag
        }
    }

    private mutating func setCpuAff0(_ index: UInt32, _ aff0: UInt32) {
        switch index {
        case 0: cpuAff0_0 = aff0
        case 1: cpuAff0_1 = aff0
        case 2: cpuAff0_2 = aff0
        case 3: cpuAff0_3 = aff0
        case 4: cpuAff0_4 = aff0
        case 5: cpuAff0_5 = aff0
        case 6: cpuAff0_6 = aff0
        case 7: cpuAff0_7 = aff0
        default: break
        }
    }

    mutating func reset() {
        ramBase = 0
        ramSize = 0
        uartBase = 0
        gicDist = 0
        gicCpu = 0
        uartIrq = 0
        virtioBase = 0
        virtioStride = 0
        virtioCount = 0
        cpuCount = 0
        cpuAff0_0 = 0
        cpuAff0_1 = 0
        cpuAff0_2 = 0
        cpuAff0_3 = 0
        cpuAff0_4 = 0
        cpuAff0_5 = 0
        cpuAff0_6 = 0
        cpuAff0_7 = 0
        cpuPsciEnableMask = 0
        psciMethod = platformPsciMethodNone
        psciCpuOn = 0
        flags = 0
    }
}

// ---- low-level helpers -----------------------------------------------------

// Single-byte load forced through a non-inlinable, non-optimized function. The
// parser may run before the MMU is enabled, where all RAM is Device-typed and
// any unaligned access faults. Plain byte loops let LLVM coalesce adjacent
// `p[i]` reads into wider unaligned loads (e.g. an unaligned `ldr w`), which
// then fault on Device memory. Routing every byte through `rd8` keeps each
// access byte-sized and naturally aligned, so the reader is safe in either
// MMU state. This is a one-time boot-path cost.
@inline(never) @_optimize(none)
private func rd8(_ p: UnsafePointer<UInt8>, _ i: Int) -> UInt8 {
    return p[i]
}

private func be32(_ p: UnsafePointer<UInt8>) -> UInt32 {
    return (UInt32(rd8(p, 0)) << 24) | (UInt32(rd8(p, 1)) << 16)
         | (UInt32(rd8(p, 2)) << 8) | UInt32(rd8(p, 3))
}

@inline(__always)
private func align4(_ x: Int) -> Int { (x + 3) & ~3 }

/// True if the NUL-terminated C string at `p` equals the static string `s`.
private func cstrEquals(_ p: UnsafePointer<UInt8>, _ s: StaticString) -> Bool {
    let sp = s.utf8Start
    let n = s.utf8CodeUnitCount
    var i = 0
    while i < n {
        if rd8(p, i) != sp[i] { return false }
        i += 1
    }
    return rd8(p, n) == 0
}

/// True if the node name at `p` begins with the static prefix `s` (e.g. the
/// "memory" of "memory@40000000").
private func nameStartsWith(_ p: UnsafePointer<UInt8>, _ s: StaticString) -> Bool {
    let sp = s.utf8Start
    let n = s.utf8CodeUnitCount
    var i = 0
    while i < n {
        if rd8(p, i) != sp[i] { return false }
        i += 1
    }
    return true
}

/// True if the `compatible` value (a list of NUL-terminated strings packed into
/// `len` bytes) contains an entry equal to `s`.
private func compatibleHas(_ vp: UnsafePointer<UInt8>, _ len: Int, _ s: StaticString) -> Bool {
    var i = 0
    while i < len {
        if cstrEquals(vp + i, s) { return true }
        while i < len && rd8(vp, i) != 0 { i += 1 }
        i += 1 // step past the NUL
    }
    return false
}

/// Read `count` big-endian 32-bit cells starting at `p` into one address value.
private func readCells(_ p: UnsafePointer<UInt8>, _ count: Int) -> UInt {
    var value: UInt = 0
    var k = 0
    while k < count {
        value = (value << 32) | UInt(be32(p + k * 4))
        k += 1
    }
    return value
}

/// Decode the `index`-th (address, size) pair of a `reg` property given the
/// governing #address-cells / #size-cells.
private func regPair(_ base: UnsafePointer<UInt8>, _ index: Int,
                     _ addrCells: Int, _ sizeCells: Int) -> (UInt, UInt) {
    let entry = base + index * (addrCells + sizeCells) * 4
    let addr = readCells(entry, addrCells)
    let size = readCells(entry + addrCells * 4, sizeCells)
    return (addr, size)
}

// ---- parser ----------------------------------------------------------------

/// Walk the device tree at `base` in a single pass and extract the M9 hardware
/// map. Returns `valid == false` (and otherwise-empty info) if the header magic
/// does not match, so the caller can fall back to defaults.
func fdtParse(_ base: UnsafePointer<UInt8>) -> PlatformInfo {
    var info = PlatformInfo()
    fdtParseInto(base, &info)
    if info.valid {
        fdtParseSmpInto(base, &info)
    }
    return info
}

/// In-place hardware-map form used by the kernel to avoid large struct
/// return/copy code in the early boot path, where strict alignment checking is
/// already enabled and RAM is still Device-typed. SMP/PSCI discovery is a
/// separate pass that runs after the MMU is enabled.
func fdtParseInto(_ base: UnsafePointer<UInt8>, _ info: inout PlatformInfo) {
    info.reset()
    if be32(base) != fdtMagic { return }

    // Validate the header before trusting any offset. The kernel scans RAM for
    // the DTB (QEMU's `-kernel` ELF path does not reliably pass it in x0), so a
    // chance magic match on stale bytes must not walk the parser off into a
    // fault. Everything below is bounded by the header's own totalsize.
    let totalSize = Int(be32(base + 4))
    let version = Int(be32(base + 20))
    if totalSize < 0x40 || totalSize > 0x0040_0000 { return } // 4 MiB ceiling
    if version < 16 || version > 17 { return }

    let structOff = Int(be32(base + 8))
    let stringsOff = Int(be32(base + 12))
    let structSize = Int(be32(base + 36))
    let stringsSize = Int(be32(base + 32))
    if structOff < 0 || stringsOff < 0 { return }
    if structOff >= totalSize || stringsOff > totalSize { return }

    var structLimit = structOff + structSize
    if structSize <= 0 || structLimit > totalSize { structLimit = totalSize }
    var stringsLimit = stringsOff + stringsSize
    if stringsSize <= 0 || stringsLimit > totalSize { stringsLimit = totalSize }
    if structOff >= structLimit { return }

    info.valid = true
    let strings = base + stringsOff

    // Root cell sizes govern child reg decoding. QEMU virt uses 2/2; we read
    // them from the root node's properties (which precede its child nodes) and
    // default to 2/2 if absent.
    var addrCells = 2
    var sizeCells = 2

    // Per depth-2 device node, accumulated as we see its properties.
    var inDevice = false
    var devIsMemory = false
    var devIsPl011 = false
    var devIsGic = false
    var devGicV3 = false
    var devIsVirtio = false
    var devRegPtr: UnsafePointer<UInt8>? = nil
    var devIrqPtr: UnsafePointer<UInt8>? = nil
    var devIrqLen = 0

    var cursor = structOff
    var depth = 0

    while cursor + 4 <= structLimit {
        let token = be32(base + cursor)
        if token == fdtEnd { break }

        if token == fdtBeginNode {
            let namePtr = base + cursor + 4
            var nameLen = 0
            while cursor + 4 + nameLen < structLimit && rd8(namePtr, nameLen) != 0 { nameLen += 1 }
            depth += 1
            if depth == 2 {
                inDevice = true
                devIsMemory = nameStartsWith(namePtr, "memory")
                devIsPl011 = false
                devIsGic = false
                devGicV3 = false
                devIsVirtio = false
                devRegPtr = nil
                devIrqPtr = nil
                devIrqLen = 0
            }
            cursor += 4 + align4(nameLen + 1)
            continue
        }

        if token == fdtEndNode {
            if depth == 2 && inDevice {
                finalizeDevice(&info, addrCells, sizeCells,
                               devIsMemory, devIsPl011, devIsGic, devGicV3, devIsVirtio,
                               devRegPtr, devIrqPtr, devIrqLen)
                inDevice = false
            }
            depth -= 1
            cursor += 4
            continue
        }

        if token == fdtProp {
            if cursor + 12 > structLimit { break }
            let len = Int(be32(base + cursor + 4))
            let nameOff = Int(be32(base + cursor + 8))
            if len < 0 || cursor + 12 + len > structLimit { break }
            let valPtr = base + cursor + 12

            // Only consult the name if it lands inside the strings block.
            if nameOff >= 0 && stringsOff + nameOff < stringsLimit {
                let propName = strings + nameOff
                if depth == 1 {
                    if cstrEquals(propName, "#address-cells") {
                        addrCells = Int(be32(valPtr))
                    } else if cstrEquals(propName, "#size-cells") {
                        sizeCells = Int(be32(valPtr))
                    }
                } else if depth == 2 && inDevice {
                    if cstrEquals(propName, "reg") {
                        devRegPtr = valPtr
                    } else if cstrEquals(propName, "compatible") {
                        if compatibleHas(valPtr, len, "arm,pl011") { devIsPl011 = true }
                        if compatibleHas(valPtr, len, "arm,cortex-a15-gic") ||
                           compatibleHas(valPtr, len, "arm,gic-400") { devIsGic = true }
                        if compatibleHas(valPtr, len, "arm,gic-v3") {
                            devIsGic = true
                            devGicV3 = true
                        }
                        if compatibleHas(valPtr, len, "virtio,mmio") { devIsVirtio = true }
                    } else if cstrEquals(propName, "interrupts") {
                        devIrqPtr = valPtr
                        devIrqLen = len
                    }
                }
            }
            cursor += 12 + align4(len)
            continue
        }

        // FDT_NOP or anything unexpected: skip the token word.
        cursor += 4
    }
}

/// Post-MMU SMP discovery pass. It reuses the same pure DTB byte helpers, but
/// is intentionally separate from the early hardware-map parser so extra local
/// state cannot perturb the MMU-off Device-memory stack layout.
func fdtParseSmpInto(_ base: UnsafePointer<UInt8>, _ info: inout PlatformInfo) {
    info.cpuCount = 0
    info.cpuAff0_0 = 0
    info.cpuAff0_1 = 0
    info.cpuAff0_2 = 0
    info.cpuAff0_3 = 0
    info.cpuAff0_4 = 0
    info.cpuAff0_5 = 0
    info.cpuAff0_6 = 0
    info.cpuAff0_7 = 0
    info.cpuPsciEnableMask = 0
    info.psciMethod = platformPsciMethodNone
    info.psciCpuOn = 0
    info.haveCpuTopology = false
    info.havePsci = false

    if be32(base) != fdtMagic { return }

    let totalSize = Int(be32(base + 4))
    let version = Int(be32(base + 20))
    if totalSize < 0x40 || totalSize > 0x0040_0000 { return }
    if version < 16 || version > 17 { return }

    let structOff = Int(be32(base + 8))
    let stringsOff = Int(be32(base + 12))
    let structSize = Int(be32(base + 36))
    let stringsSize = Int(be32(base + 32))
    if structOff < 0 || stringsOff < 0 { return }
    if structOff >= totalSize || stringsOff > totalSize { return }

    var structLimit = structOff + structSize
    if structSize <= 0 || structLimit > totalSize { structLimit = totalSize }
    var stringsLimit = stringsOff + stringsSize
    if stringsSize <= 0 || stringsLimit > totalSize { stringsLimit = totalSize }
    if structOff >= structLimit { return }

    let strings = base + stringsOff
    var inCpus = false
    var inCpu = false
    var cpuIsCpu = false
    var cpuHaveReg = false
    var cpuAff0: UInt32 = 0
    var cpuEnableMethod = platformCpuEnableUnknown
    var cpuAddrCells = 1
    var inPsci = false
    var psciCompatible = false
    var psciHaveMethod = false
    var psciHaveCpuOn = false
    var psciMethod = platformPsciMethodNone
    var psciCpuOn: UInt32 = 0

    var cursor = structOff
    var depth = 0

    while cursor + 4 <= structLimit {
        let token = be32(base + cursor)
        if token == fdtEnd { break }

        if token == fdtBeginNode {
            let namePtr = base + cursor + 4
            var nameLen = 0
            while cursor + 4 + nameLen < structLimit && rd8(namePtr, nameLen) != 0 { nameLen += 1 }
            depth += 1
            if depth == 2 {
                inCpus = cstrEquals(namePtr, "cpus")
                if inCpus { cpuAddrCells = 1 }
                inPsci = cstrEquals(namePtr, "psci")
                psciCompatible = false
                psciHaveMethod = false
                psciHaveCpuOn = false
                psciMethod = platformPsciMethodNone
                psciCpuOn = 0
            } else if depth == 3 && inCpus {
                inCpu = true
                cpuIsCpu = false
                cpuHaveReg = false
                cpuAff0 = 0
                cpuEnableMethod = platformCpuEnableUnknown
            }
            cursor += 4 + align4(nameLen + 1)
            continue
        }

        if token == fdtEndNode {
            if depth == 3 && inCpus && inCpu {
                if cpuHaveReg && cpuIsCpu {
                    info.appendCpuAff0(cpuAff0)
                    info.markCpuEnableMethod(cpuAff0, cpuEnableMethod)
                }
                inCpu = false
            }
            if depth == 2 && inPsci {
                if psciCompatible && psciHaveMethod && psciHaveCpuOn {
                    info.havePsci = true
                    info.psciMethod = psciMethod
                    info.psciCpuOn = psciCpuOn
                }
                inPsci = false
            }
            if depth == 2 && inCpus {
                inCpus = false
            }
            depth -= 1
            cursor += 4
            continue
        }

        if token == fdtProp {
            if cursor + 12 > structLimit { break }
            let len = Int(be32(base + cursor + 4))
            let nameOff = Int(be32(base + cursor + 8))
            if len < 0 || cursor + 12 + len > structLimit { break }
            let valPtr = base + cursor + 12

            if nameOff >= 0 && stringsOff + nameOff < stringsLimit {
                let propName = strings + nameOff
                if depth == 2 && inPsci {
                    if cstrEquals(propName, "compatible") {
                        psciCompatible = compatibleHas(valPtr, len, "arm,psci-1.0") ||
                                         compatibleHas(valPtr, len, "arm,psci-0.2") ||
                                         compatibleHas(valPtr, len, "arm,psci")
                    } else if cstrEquals(propName, "method") && len >= 4 {
                        if cstrEquals(valPtr, "hvc") {
                            psciMethod = platformPsciMethodHvc
                            psciHaveMethod = true
                        } else if cstrEquals(valPtr, "smc") {
                            psciMethod = platformPsciMethodSmc
                            psciHaveMethod = true
                        }
                    } else if cstrEquals(propName, "cpu_on") && len >= 4 {
                        psciCpuOn = be32(valPtr)
                        psciHaveCpuOn = true
                    }
                } else if depth == 2 && inCpus {
                    if cstrEquals(propName, "#address-cells") && len >= 4 {
                        cpuAddrCells = Int(be32(valPtr))
                    }
                } else if depth == 3 && inCpus && inCpu {
                    if cstrEquals(propName, "reg") &&
                       cpuAddrCells > 0 && cpuAddrCells <= 2 &&
                       len >= cpuAddrCells * 4 {
                        cpuAff0 = UInt32(readCells(valPtr, cpuAddrCells) & 0xFF)
                        cpuHaveReg = true
                    } else if cstrEquals(propName, "device_type") {
                        cpuIsCpu = cstrEquals(valPtr, "cpu")
                    } else if cstrEquals(propName, "enable-method") && len >= 5 {
                        if cstrEquals(valPtr, "psci") {
                            cpuEnableMethod = platformCpuEnablePsci
                        }
                    }
                }
            }
            cursor += 12 + align4(len)
            continue
        }

        cursor += 4
    }
}

/// Apply a finished device node's captured properties to the platform info.
private func finalizeDevice(_ info: inout PlatformInfo,
                            _ addrCells: Int, _ sizeCells: Int,
                            _ isMemory: Bool, _ isPl011: Bool, _ isGic: Bool,
                            _ isGicV3: Bool, _ isVirtio: Bool,
                            _ regPtr: UnsafePointer<UInt8>?,
                            _ irqPtr: UnsafePointer<UInt8>?, _ irqLen: Int) {
    if isMemory, let rp = regPtr {
        let (b, sz) = regPair(rp, 0, addrCells, sizeCells)
        info.haveRam = true
        info.ramBase = b
        info.ramSize = sz
    }
    if isPl011, let rp = regPtr {
        let (b, _) = regPair(rp, 0, addrCells, sizeCells)
        info.haveUart = true
        info.uartBase = b
        // GIC interrupt specifier: <type number flags>. type 0 = SPI (+32),
        // type 1 = PPI (+16). PL011 on virt is <0 1 4> -> SPI 1 -> INTID 33.
        if let ip = irqPtr, irqLen >= 12 {
            let type = be32(ip)
            let number = be32(ip + 4)
            info.haveUartIrq = true
            info.uartIrq = (type == 0) ? number + 32 : number + 16
        }
    }
    if isGic, let rp = regPtr {
        // reg = <GICD_base GICD_size SECOND_base SECOND_size ...>. On GICv2 the
        // second range is the GICC MMIO window; on GICv3 it is the first
        // redistributor region. We keep both in gicCpu and disambiguate with
        // gicIsV3 (platformInit routes it to gicCpu or gicRedist accordingly).
        let (dist, _) = regPair(rp, 0, addrCells, sizeCells)
        let (second, _) = regPair(rp, 1, addrCells, sizeCells)
        info.haveGic = true
        info.gicDist = dist
        info.gicCpu = second
        info.gicIsV3 = isGicV3
    }
    if isVirtio, let rp = regPtr {
        // The transport slots are identical and contiguous; record the lowest
        // base, the per-slot stride, and the slot count.
        let (b, sz) = regPair(rp, 0, addrCells, sizeCells)
        if !info.haveVirtio || b < info.virtioBase { info.virtioBase = b }
        info.virtioStride = sz
        info.virtioCount += 1
        info.haveVirtio = true
    }
}
