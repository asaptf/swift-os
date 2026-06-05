// fdt.swift - a minimal flattened-device-tree (FDT/DTB) reader.
//
// QEMU `-kernel` hands the kernel a pointer to a flattened device tree in x0.
// The DTB describes the actual hardware map (RAM, UART, interrupt controller),
// which lets us discover those addresses at runtime instead of hardcoding the
// QEMU `virt` constants - a prerequisite for UEFI boot and any non-QEMU host.
//
// This reader is deliberately pure: it touches no MMIO, no UART, and no heap,
// so the same code compiles for the kernel (Embedded Swift) and for a host unit
// test (full Swift) - see tests/fdt_test.swift. It extracts only what M9 needs:
// the /memory reg, the PL011 UART reg + IRQ, and the GICv2 dist/CPU regs.
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
    var haveGic: Bool {
        get { (flags & platformInfoHaveGic) != 0 }
        set { setFlag(platformInfoHaveGic, newValue) }
    }
    var haveVirtio: Bool {
        get { (flags & platformInfoHaveVirtio) != 0 }
        set { setFlag(platformInfoHaveVirtio, newValue) }
    }

    private mutating func setFlag(_ flag: UInt32, _ enabled: Bool) {
        if enabled {
            flags |= flag
        } else {
            flags &= ~flag
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
    return info
}

/// In-place form used by the kernel to avoid large struct return/copy code in
/// the early boot path, where strict alignment checking is already enabled.
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
                               devIsMemory, devIsPl011, devIsGic, devIsVirtio,
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

/// Apply a finished device node's captured properties to the platform info.
private func finalizeDevice(_ info: inout PlatformInfo,
                            _ addrCells: Int, _ sizeCells: Int,
                            _ isMemory: Bool, _ isPl011: Bool, _ isGic: Bool,
                            _ isVirtio: Bool,
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
        let (dist, _) = regPair(rp, 0, addrCells, sizeCells)
        let (cpu, _) = regPair(rp, 1, addrCells, sizeCells)
        info.haveGic = true
        info.gicDist = dist
        info.gicCpu = cpu
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
