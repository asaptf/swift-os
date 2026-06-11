// SPDX-License-Identifier: Apache-2.0
// virtio_rng.swift — minimal polled virtio 1.0 (modern, MMIO) RNG driver.
//
// QEMU and cloud hypervisors expose hardware/runtime entropy to guests through
// virtio-rng (device id 4). SSHD needs that before its KEX ephemeral material can
// be treated as VM-deployable rather than image-seeded development randomness.
// This driver mirrors the existing virtio-blk/input shape: one synchronous
// request virtqueue, no IRQ wiring, cache maintenance through io.h, and a tiny
// syscall-facing read function.

private let VIRTIO_ID_RNG: UInt32 = 4

// virtio-mmio register offsets.
private let R_MAGIC: UInt      = 0x000
private let R_VERSION: UInt    = 0x004
private let R_DEVID: UInt      = 0x008
private let R_DRVFEAT: UInt    = 0x020
private let R_DRVFEATSEL: UInt = 0x024
private let R_QSEL: UInt       = 0x030
private let R_QNUMMAX: UInt    = 0x034
private let R_QNUM: UInt       = 0x038
private let R_QREADY: UInt     = 0x044
private let R_QNOTIFY: UInt    = 0x050
private let R_ISTATUS: UInt    = 0x060
private let R_IACK: UInt       = 0x064
private let R_STATUS: UInt     = 0x070
private let R_QDESCL: UInt     = 0x080
private let R_QDESCH: UInt     = 0x084
private let R_QDRVL: UInt      = 0x090
private let R_QDRVH: UInt      = 0x094
private let R_QDEVL: UInt      = 0x0a0
private let R_QDEVH: UInt      = 0x0a4

private let VIRTIO_MAGIC: UInt32 = 0x74726976   // "virt"

private let S_ACK: UInt32    = 1
private let S_DRV: UInt32    = 2
private let S_DRVOK: UInt32  = 4
private let S_FEATOK: UInt32 = 8

private let RNG_QSZ = 1
private let RNG_BUF_SIZE = 256
private let RNG_SPIN_LIMIT = 2_000_000
private let VIRTQ_DESC_F_WRITE: UInt16 = 2

private let OFF_DESC: UInt  = 0x000
private let OFF_AVAIL: UInt = 0x080
private let OFF_USED: UInt  = 0x100

private var rngMmio: UInt = 0
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

func virtioRngInit() -> Bool {
    rngMmio = 0
    var i: UInt32 = 0
    while i < platform.virtioMmioCount {
        let m = platform.virtioMmioBase + UInt(i) * platform.virtioMmioStride
        if mmio_read32(m + R_MAGIC) == VIRTIO_MAGIC &&
           mmio_read32(m + R_DEVID) == VIRTIO_ID_RNG {
            rngMmio = m
            break
        }
        i += 1
    }
    if rngMmio == 0 { return false }

    if rngRingBase == 0 {
        let r = pmm_alloc_page()
        if r == 0 { rngMmio = 0; return false }
        rngRingBase = r
    }
    if rngDataBase == 0 {
        let d = pmm_alloc_page()
        if d == 0 { rngMmio = 0; return false }
        rngDataBase = d
    }
    rngZeroPage(rngRingBase)
    rngZeroPage(rngDataBase)
    rngAvailIdx = 0
    rngLastUsed = 0

    mmio_write32(rngMmio + R_STATUS, 0)
    mmio_write32(rngMmio + R_STATUS, S_ACK)
    mmio_write32(rngMmio + R_STATUS, S_ACK | S_DRV)
    mmio_write32(rngMmio + R_DRVFEATSEL, 1)
    mmio_write32(rngMmio + R_DRVFEAT, 1) // VIRTIO_F_VERSION_1
    mmio_write32(rngMmio + R_DRVFEATSEL, 0)
    mmio_write32(rngMmio + R_DRVFEAT, 0)
    mmio_write32(rngMmio + R_STATUS, S_ACK | S_DRV | S_FEATOK)
    if (mmio_read32(rngMmio + R_STATUS) & S_FEATOK) == 0 {
        rngMmio = 0
        return false
    }

    mmio_write32(rngMmio + R_QSEL, 0)
    let maxq = mmio_read32(rngMmio + R_QNUMMAX)
    if maxq == 0 {
        rngMmio = 0
        return false
    }
    rngQn = maxq < UInt32(RNG_QSZ) ? maxq : UInt32(RNG_QSZ)
    mmio_write32(rngMmio + R_QNUM, rngQn)
    rngClean(rngRingBase + OFF_AVAIL, 16)
    rngClean(rngRingBase + OFF_USED, 16)

    let da = UInt64(rngRingBase + OFF_DESC)
    let aa = UInt64(rngRingBase + OFF_AVAIL)
    let ua = UInt64(rngRingBase + OFF_USED)
    mmio_write32(rngMmio + R_QDESCL, UInt32(da & 0xFFFF_FFFF))
    mmio_write32(rngMmio + R_QDESCH, UInt32(da >> 32))
    mmio_write32(rngMmio + R_QDRVL, UInt32(aa & 0xFFFF_FFFF))
    mmio_write32(rngMmio + R_QDRVH, UInt32(aa >> 32))
    mmio_write32(rngMmio + R_QDEVL, UInt32(ua & 0xFFFF_FFFF))
    mmio_write32(rngMmio + R_QDEVH, UInt32(ua >> 32))
    mmio_write32(rngMmio + R_QREADY, 1)
    mmio_write32(rngMmio + R_STATUS, S_ACK | S_DRV | S_FEATOK | S_DRVOK)
    return true
}

func virtioRngAvailable() -> Bool {
    rngMmio != 0
}

private func virtioRngRequest(_ maxBytes: Int) -> Int {
    if rngMmio == 0 { return -19 } // ENODEV
    let want = maxBytes < RNG_BUF_SIZE ? maxBytes : RNG_BUF_SIZE
    if want <= 0 { return 0 }

    rngDescSet(UInt64(rngDataBase), UInt32(want), VIRTQ_DESC_F_WRITE)
    rngClean(rngRingBase + OFF_DESC, 16)
    rngInvalidate(rngDataBase, want)
    rngAvailAdd()
    rngClean(rngRingBase + OFF_AVAIL, 16)
    mmio_write32(rngMmio + R_QNOTIFY, 0)

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

    let ist = mmio_read32(rngMmio + R_ISTATUS)
    if ist != 0 { mmio_write32(rngMmio + R_IACK, ist) }
    return got > 0 ? got : -5
}

func virtioRngRead(_ dst: UnsafeMutablePointer<UInt8>, _ count: Int) -> Int {
    if count < 0 { return -22 }
    if count == 0 { return 0 }
    if rngMmio == 0 { return -19 }

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
