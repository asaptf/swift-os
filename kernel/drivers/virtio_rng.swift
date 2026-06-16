// SPDX-License-Identifier: Apache-2.0
// virtio_rng.swift — polled virtio 1.0 RNG driver over the transport abstraction.
//
// QEMU and cloud hypervisors expose hardware/runtime entropy through virtio-rng
// (device type 4). SSHD needs that before its KEX ephemeral material can be
// treated as VM-deployable rather than image-seeded development randomness.
// The driver binds over `VirtioTransport`: virtio-mmio on QEMU `virt`, or
// virtio-pci on `-cpu max` / the Hetzner ARM VM (H2). Only the device control
// plane goes through the transport; the virtqueue ring memory is identical.

private let VIRTIO_ID_RNG: UInt32 = 4

// virtio-mmio identity registers (only what the MMIO discovery scan needs; the
// control-plane registers live behind VirtioTransport now).
private let R_MAGIC: UInt = 0x000
private let R_DEVID: UInt = 0x008
private let VIRTIO_MAGIC: UInt32 = 0x74726976   // "virt"

private let RNG_QSZ = 1
private let RNG_BUF_SIZE = 256
private let RNG_SPIN_LIMIT = 2_000_000
private let VIRTQ_DESC_F_WRITE: UInt16 = 2

// Split-virtqueue ring layout within one page (desc | avail | used).
private let OFF_DESC: UInt = 0x000
private let OFF_AVAIL: UInt = 0x080
private let OFF_USED: UInt = 0x100

private var rngXport = VirtioTransport(mmio: 0)
private var rngActive = false
private var rngRingBase: UInt = 0
private var rngDataBase: UInt = 0
private var rngQn: UInt32 = 0
private var rngAvailIdx: UInt16 = 0
private var rngLastUsed: UInt16 = 0

private func rngClean(_ pa: UInt, _ n: Int) {
    var a = pa & ~UInt(63)
    let end = pa + UInt(n)
    while a < end { dc_cvac(a); a += 64 }
    dsb_sy()
}

private func rngInvalidate(_ pa: UInt, _ n: Int) {
    dsb_sy()
    var a = pa & ~UInt(63)
    let end = pa + UInt(n)
    while a < end { dc_ivac(a); a += 64 }
    dsb_sy()
}

private func rngZeroPage(_ pa: UInt) {
    let p = UnsafeMutableRawPointer(bitPattern: pa)!
    var i = 0
    while i < 4096 {
        p.storeBytes(of: UInt8(0), toByteOffset: i, as: UInt8.self)
        i += 1
    }
}

private func rngDescSet(_ addr: UInt64, _ len: UInt32, _ flags: UInt16) {
    let d = UnsafeMutableRawPointer(bitPattern: rngRingBase + OFF_DESC)!
    d.storeBytes(of: addr, toByteOffset: 0, as: UInt64.self)
    d.storeBytes(of: len, toByteOffset: 8, as: UInt32.self)
    d.storeBytes(of: flags, toByteOffset: 12, as: UInt16.self)
    d.storeBytes(of: UInt16(0), toByteOffset: 14, as: UInt16.self)
}

private func rngAvailAdd() {
    let avail = UnsafeMutableRawPointer(bitPattern: rngRingBase + OFF_AVAIL)!
    avail.storeBytes(of: UInt16(0), toByteOffset: 4, as: UInt16.self)
    rngAvailIdx &+= 1
    avail.storeBytes(of: rngAvailIdx, toByteOffset: 2, as: UInt16.self)
}

private func rngUsedIdx() -> UInt16 {
    UnsafeRawPointer(bitPattern: rngRingBase + OFF_USED)!.load(fromByteOffset: 2, as: UInt16.self)
}

private func rngUsedID() -> UInt32 {
    UnsafeRawPointer(bitPattern: rngRingBase + OFF_USED + 4)!.load(fromByteOffset: 0, as: UInt32.self)
}

private func rngUsedLen() -> UInt32 {
    UnsafeRawPointer(bitPattern: rngRingBase + OFF_USED + 4)!.load(fromByteOffset: 4, as: UInt32.self)
}

// Locate a virtio-rng device: prefer virtio-mmio (the QEMU `virt` default), fall
// back to virtio-pci (the GICv3 / Hetzner profile). Returns nil if neither.
private func rngFindTransport() -> VirtioTransport? {
    var i: UInt32 = 0
    while i < platform.virtioMmioCount {
        let m = platform.virtioMmioBase + UInt(i) * platform.virtioMmioStride
        if mmio_read32(m + R_MAGIC) == VIRTIO_MAGIC &&
           mmio_read32(m + R_DEVID) == VIRTIO_ID_RNG {
            return VirtioTransport(mmio: m)
        }
        i += 1
    }
    if let dev = virtioPciFindDevice(deviceType: VIRTIO_ID_RNG) {
        return VirtioTransport(pci: dev)
    }
    return nil
}

func virtioRngInit() -> Bool {
    rngActive = false
    guard let xport = rngFindTransport() else { return false }
    rngXport = xport

    if rngRingBase == 0 {
        let r = pmm_alloc_page()
        if r == 0 { return false }
        rngRingBase = r
    }
    if rngDataBase == 0 {
        let d = pmm_alloc_page()
        if d == 0 { return false }
        rngDataBase = d
    }
    rngZeroPage(rngRingBase)
    rngZeroPage(rngDataBase)
    rngAvailIdx = 0
    rngLastUsed = 0

    rngXport.reset()
    rngXport.setStatus(VIRTIO_STATUS_ACK)
    rngXport.setStatus(VIRTIO_STATUS_ACK | VIRTIO_STATUS_DRIVER)
    if !rngXport.negotiateVersion1() { return false }

    let da = UInt64(rngRingBase + OFF_DESC)
    let aa = UInt64(rngRingBase + OFF_AVAIL)
    let ua = UInt64(rngRingBase + OFF_USED)
    let size = rngXport.setupQueue(0, requested: UInt32(RNG_QSZ), desc: da, avail: aa, used: ua)
    if size == 0 { return false }
    rngQn = size
    rngClean(rngRingBase + OFF_AVAIL, 16)
    rngClean(rngRingBase + OFF_USED, 16)

    rngXport.setStatus(VIRTIO_STATUS_ACK | VIRTIO_STATUS_DRIVER |
                       VIRTIO_STATUS_FEATURES_OK | VIRTIO_STATUS_DRIVER_OK)
    rngActive = true
    return true
}

func virtioRngAvailable() -> Bool { rngActive }

/// H2: which transport the active virtio-rng is bound to ("mmio", "pci", or
/// "none"). Used by the H2 acceptance probe / boot log.
func virtioRngTransportName() -> StaticString {
    if !rngActive { return "none" }
    return rngXport.isPci ? "pci" : "mmio"
}

private func virtioRngRequest(_ maxBytes: Int) -> Int {
    if !rngActive { return -19 } // ENODEV
    let want = maxBytes < RNG_BUF_SIZE ? maxBytes : RNG_BUF_SIZE
    if want <= 0 { return 0 }

    rngDescSet(UInt64(rngDataBase), UInt32(want), VIRTQ_DESC_F_WRITE)
    rngClean(rngRingBase + OFF_DESC, 16)
    rngInvalidate(rngDataBase, want)
    rngAvailAdd()
    rngClean(rngRingBase + OFF_AVAIL, 16)
    rngXport.notify(queue: 0)

    var spins = 0
    while true {
        rngInvalidate(rngRingBase + OFF_USED, 16)
        if rngUsedIdx() != rngLastUsed { break }
        spins += 1
        if spins >= RNG_SPIN_LIMIT { return -5 } // EIO
    }

    if (rngUsedID() % rngQn) != 0 { return -5 }
    var got = Int(rngUsedLen())
    if got > want { got = want }
    rngLastUsed &+= 1
    rngInvalidate(rngDataBase, got)
    rngXport.ackInterrupt()
    return got > 0 ? got : -5
}

func virtioRngRead(_ dst: UnsafeMutablePointer<UInt8>, _ count: Int) -> Int {
    if count < 0 { return -22 }
    if count == 0 { return 0 }
    if !rngActive { return -19 }

    var done = 0
    while done < count {
        let n = virtioRngRequest(count - done)
        if n < 0 {
            return done > 0 ? done : n
        }
        if n == 0 {
            return done > 0 ? done : -5
        }
        let src = UnsafeRawPointer(bitPattern: rngDataBase)!
        var i = 0
        while i < n {
            dst[done + i] = src.load(fromByteOffset: i, as: UInt8.self)
            i += 1
        }
        done += n
    }
    return done
}
