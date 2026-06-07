// virtio_blk.swift — minimal polled virtio 1.0 (modern, MMIO) block driver.
//
// M11b: gives the kernel synchronous, read-only access to a virtio-blk disk so
// the packed read-only base image can be served from a real disk instead of
// kernel literals (M11c). The QEMU `virt` board exposes virtio transports over
// virtio-mmio; we scan the device-tree-discovered window (kernel HAL) for a
// block device (device id 2), negotiate VIRTIO_F_VERSION_1, bring up one
// request virtqueue, and read 512-byte sectors one at a time by driving the
// descriptor chain and POLLING the used ring — no IRQ wiring, like the
// virtio-input keyboard.
//
// Swift rewrite of the former virtio_blk.c, following virtio_net.swift: the ring
// and the bounce/header/status buffers are PMM pages (naturally aligned, no
// static __attribute__((aligned)) needed), and MMIO plus cache maintenance go
// through the io.h C bridge. Single-threaded blocking reads are fine for a
// read-only base. We clean what the device reads and invalidate what it writes;
// no-ops under TCG, real work under a caching accelerator.

// virtio-mmio register offsets (same layout as virtio_net.swift).
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
private let R_CONFIG: UInt     = 0x100

private let VIRTIO_MAGIC: UInt32 = 0x74726976   // "virt"
private let VIRTIO_ID_BLOCK: UInt32 = 2

private let S_ACK: UInt32    = 1
private let S_DRV: UInt32    = 2
private let S_DRVOK: UInt32  = 4
private let S_FEATOK: UInt32 = 8

private let BLK_QSZ = 8
private let VIRTQ_DESC_F_NEXT: UInt16  = 1
private let VIRTQ_DESC_F_WRITE: UInt16 = 2

private let VIRTIO_BLK_T_IN: UInt32 = 0  // read from disk into memory
private let SECTOR_SIZE = 512

// Ring page layout: descriptor table, available ring, and used ring carved out
// of one 4 KiB page at fixed, naturally-aligned offsets (as in virtio_net.swift).
private let OFF_DESC: UInt  = 0x000
private let OFF_AVAIL: UInt = 0x080
private let OFF_USED: UInt  = 0x100

// Data page layout: each region on its own 64-byte cache line so a clean of one
// (device-read header) never interferes with an invalidate of another
// (device-written bounce buffer / status byte).
private let OFF_BOUNCE: UInt = 0x000  // 512 bytes (lines 0..7), device-write
private let OFF_HDR: UInt    = 0x200  // 16 bytes (line 8), device-read
private let OFF_STATUS: UInt = 0x240  // 1 byte (line 9), device-write

private var blkMmio: UInt = 0
private var blkRingBase: UInt = 0   // PA of the page holding desc/avail/used
private var blkDataBase: UInt = 0   // PA of the page holding bounce/hdr/status
private var blkQn: UInt32 = 0
private var blkAvailIdx: UInt16 = 0
private var blkLastUsed: UInt16 = 0
private var blkCapacity: UInt64 = 0 // device capacity in 512-byte sectors

// --- cache maintenance ------------------------------------------------------
private func blkClean(_ pa: UInt, _ n: Int) {
    var a = pa & ~UInt(63)
    let end = pa + UInt(n)
    while a < end { dc_cvac(a); a += 64 }
    dsb_sy()
}
private func blkInvalidate(_ pa: UInt, _ n: Int) {
    dsb_sy()
    var a = pa & ~UInt(63)
    let end = pa + UInt(n)
    while a < end { dc_ivac(a); a += 64 }
    dsb_sy()
}
private func blkZeroPage(_ pa: UInt) {
    let p = UnsafeMutableRawPointer(bitPattern: pa)!
    var i = 0
    while i < 4096 { p.storeBytes(of: UInt8(0), toByteOffset: i, as: UInt8.self); i += 1 }
}

// --- virtqueue accessors (little-endian native, aligned by layout) ----------
private func blkDescSet(_ i: Int, addr: UInt64, len: UInt32, flags: UInt16, next: UInt16) {
    let d = UnsafeMutableRawPointer(bitPattern: blkRingBase + OFF_DESC + UInt(i * 16))!
    d.storeBytes(of: addr, toByteOffset: 0, as: UInt64.self)
    d.storeBytes(of: len, toByteOffset: 8, as: UInt32.self)
    d.storeBytes(of: flags, toByteOffset: 12, as: UInt16.self)
    d.storeBytes(of: next, toByteOffset: 14, as: UInt16.self)
}

private func blkAvailAdd(descIdx: UInt16) {
    let avail = UnsafeMutableRawPointer(bitPattern: blkRingBase + OFF_AVAIL)!
    let slot = Int(blkAvailIdx % UInt16(blkQn))
    avail.storeBytes(of: descIdx, toByteOffset: 4 + slot * 2, as: UInt16.self) // ring[slot]
    blkAvailIdx &+= 1
    avail.storeBytes(of: blkAvailIdx, toByteOffset: 2, as: UInt16.self)        // avail.idx
}

private func blkUsedIdx() -> UInt16 {
    UnsafeRawPointer(bitPattern: blkRingBase + OFF_USED)!.load(fromByteOffset: 2, as: UInt16.self)
}

// --- bring-up ---------------------------------------------------------------
// Bring up a single virtio-blk transport at `m`: reset, negotiate, set up the
// request virtqueue, and read the capacity. Sets blkMmio/blkQn/blkCapacity and
// returns the capacity in sectors, or 0 on failure (blkMmio cleared).
private func blkBringUp(_ m: UInt) -> UInt64 {
    blkMmio = m

    mmio_write32(m + R_STATUS, 0)               // reset
    mmio_write32(m + R_STATUS, S_ACK)
    mmio_write32(m + R_STATUS, S_ACK | S_DRV)
    // Accept only VIRTIO_F_VERSION_1 (feature bit 32); ignore block features.
    mmio_write32(m + R_DRVFEATSEL, 1); mmio_write32(m + R_DRVFEAT, 1)
    mmio_write32(m + R_DRVFEATSEL, 0); mmio_write32(m + R_DRVFEAT, 0)
    mmio_write32(m + R_STATUS, S_ACK | S_DRV | S_FEATOK)
    if (mmio_read32(m + R_STATUS) & S_FEATOK) == 0 { blkMmio = 0; return 0 }

    mmio_write32(m + R_QSEL, 0)
    let maxq = mmio_read32(m + R_QNUMMAX)
    if maxq == 0 { blkMmio = 0; return 0 }
    blkQn = maxq < UInt32(BLK_QSZ) ? maxq : UInt32(BLK_QSZ)
    mmio_write32(m + R_QNUM, blkQn)

    blkZeroPage(blkRingBase)
    blkAvailIdx = 0
    blkLastUsed = 0
    blkClean(blkRingBase + OFF_AVAIL, 32)
    blkClean(blkRingBase + OFF_USED, 72)

    let da = UInt64(blkRingBase + OFF_DESC)
    let aa = UInt64(blkRingBase + OFF_AVAIL)
    let ua = UInt64(blkRingBase + OFF_USED)
    mmio_write32(m + R_QDESCL, UInt32(da & 0xFFFF_FFFF)); mmio_write32(m + R_QDESCH, UInt32(da >> 32))
    mmio_write32(m + R_QDRVL,  UInt32(aa & 0xFFFF_FFFF)); mmio_write32(m + R_QDRVH,  UInt32(aa >> 32))
    mmio_write32(m + R_QDEVL,  UInt32(ua & 0xFFFF_FFFF)); mmio_write32(m + R_QDEVH,  UInt32(ua >> 32))
    mmio_write32(m + R_QREADY, 1)
    mmio_write32(m + R_STATUS, S_ACK | S_DRV | S_FEATOK | S_DRVOK)

    // Capacity (config space offset 0): number of 512-byte sectors, LE u64.
    let lo = mmio_read32(m + R_CONFIG + 0)
    let hi = mmio_read32(m + R_CONFIG + 4)
    blkCapacity = (UInt64(hi) << 32) | UInt64(lo)
    return blkCapacity
}

// True if the bounce buffer currently starts with the packed-base "SWOSBASE"
// magic (so we can pick the base-image disk out of several block devices).
private func blkBounceIsSwosbase() -> Bool {
    let bounce = UnsafeRawPointer(bitPattern: blkDataBase + OFF_BOUNCE)!
    let magic: StaticString = "SWOSBASE"
    var ok = true
    magic.withUTF8Buffer { m in
        var i = 0
        while i < 8 {
            if bounce.load(fromByteOffset: i, as: UInt8.self) != m[i] { ok = false }
            i += 1
        }
    }
    return ok
}

// Read one sector into the internal bounce buffer. Returns 0 on success.
private func blkDoRead(_ sector: UInt64) -> Int32 {
    if blkMmio == 0 { return -1 }
    if blkCapacity != 0 && sector >= blkCapacity { return -2 }

    let hdr = blkDataBase + OFF_HDR
    let status = blkDataBase + OFF_STATUS
    let bounce = blkDataBase + OFF_BOUNCE

    // virtio-blk request header (device-readable part of the chain).
    let hp = UnsafeMutableRawPointer(bitPattern: hdr)!
    hp.storeBytes(of: VIRTIO_BLK_T_IN, toByteOffset: 0, as: UInt32.self) // type
    hp.storeBytes(of: UInt32(0), toByteOffset: 4, as: UInt32.self)       // reserved
    hp.storeBytes(of: sector, toByteOffset: 8, as: UInt64.self)
    UnsafeMutableRawPointer(bitPattern: status)!.storeBytes(of: UInt8(0xFF), toByteOffset: 0, as: UInt8.self)
    blkClean(hdr, 16)
    blkClean(status, 1)
    blkClean(bounce, SECTOR_SIZE)

    // Three-descriptor chain: header (device-read), data (device-write),
    // status (device-write).
    blkDescSet(0, addr: UInt64(hdr), len: 16, flags: VIRTQ_DESC_F_NEXT, next: 1)
    blkDescSet(1, addr: UInt64(bounce), len: UInt32(SECTOR_SIZE),
               flags: VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_WRITE, next: 2)
    blkDescSet(2, addr: UInt64(status), len: 1, flags: VIRTQ_DESC_F_WRITE, next: 0)
    blkClean(blkRingBase + OFF_DESC, BLK_QSZ * 16)

    blkAvailAdd(descIdx: 0) // chain head descriptor index
    blkClean(blkRingBase + OFF_AVAIL, 32)

    mmio_write32(blkMmio + R_QNOTIFY, 0)

    // Poll the used ring for completion.
    let target = blkLastUsed &+ 1
    while true {
        blkInvalidate(blkRingBase + OFF_USED, 72)
        if blkUsedIdx() == target { break }
    }
    blkLastUsed = target

    let ist = mmio_read32(blkMmio + R_ISTATUS)
    if ist != 0 { mmio_write32(blkMmio + R_IACK, ist) }

    blkInvalidate(status, 1)
    if UnsafeRawPointer(bitPattern: status)!.load(fromByteOffset: 0, as: UInt8.self) != 0 { return -3 }

    blkInvalidate(bounce, SECTOR_SIZE)
    return 0
}

// Scan the virtio-mmio window (base/stride/count from the HAL) for block
// devices and select the packed base image: a boot medium may carry several
// disks (e.g. a GPT boot disk plus the SWOSBASE base image), so we prefer the
// one whose sector 0 holds the SWOSBASE magic, falling back to the first block
// device otherwise. Returns the selected disk's capacity in sectors, or 0.
func virtioBlkInit(_ base: UInt, _ stride: UInt, _ count: UInt32) -> UInt64 {
    blkMmio = 0
    // The ring and data pages are allocated once and reused across bring-up
    // attempts, mirroring the C version's static buffers (no per-scan leak).
    if blkRingBase == 0 {
        let r = pmm_alloc_page()
        if r == 0 { return 0 }
        blkRingBase = r
    }
    if blkDataBase == 0 {
        let d = pmm_alloc_page()
        if d == 0 { return 0 }
        blkDataBase = d
    }

    var first: UInt = 0
    var i: UInt32 = 0
    while i < count {
        let m = base + UInt(i) * stride
        i += 1
        if mmio_read32(m + R_MAGIC) != VIRTIO_MAGIC { continue }
        if mmio_read32(m + R_VERSION) != 2 { continue }      // modern only
        if mmio_read32(m + R_DEVID) != VIRTIO_ID_BLOCK { continue }
        if first == 0 { first = m }
        if blkBringUp(m) == 0 { continue }
        if blkDoRead(0) == 0 && blkBounceIsSwosbase() {
            return blkCapacity // packed base image — this is the one we want
        }
    }
    // No SWOSBASE disk; fall back to the first block device (if any).
    if first != 0 { return blkBringUp(first) }
    blkMmio = 0
    return 0
}

func virtioBlkAvailable() -> Bool { blkMmio != 0 }
func virtioBlkCapacity() -> UInt64 { blkCapacity }

// Read one 512-byte sector into `buf`. Returns 0 on success, negative on error.
// Blocking: issues the request and spins on the used ring until it completes.
func virtioBlkRead(_ sector: UInt64, _ buf: UnsafeMutableRawPointer?) -> Int32 {
    let rc = blkDoRead(sector)
    if rc != 0 { return rc }
    guard let dst = buf else { return -1 }
    let bounce = UnsafeRawPointer(bitPattern: blkDataBase + OFF_BOUNCE)!
    var i = 0
    while i < SECTOR_SIZE {
        dst.storeBytes(of: bounce.load(fromByteOffset: i, as: UInt8.self), toByteOffset: i, as: UInt8.self)
        i += 1
    }
    return 0
}

// Read an arbitrary byte range [byteOff, byteOff+len) into `buf`, spanning
// sectors as needed. Returns 0 on success, negative on error. Used to back the
// read-only VFS with extents into the disk image (M11c).
func virtioBlkReadRange(_ byteOff: UInt64, _ buf: UnsafeMutableRawPointer?, _ len: UInt32) -> Int32 {
    if blkMmio == 0 { return -1 }
    guard let out = buf else { return -1 }
    let bounce = UnsafeRawPointer(bitPattern: blkDataBase + OFF_BOUNCE)!
    var done: UInt32 = 0
    while done < len {
        let pos = byteOff + UInt64(done)
        let sec = pos / UInt64(SECTOR_SIZE)
        let within = UInt32(pos % UInt64(SECTOR_SIZE))
        let rc = blkDoRead(sec)
        if rc != 0 { return rc }
        var chunk = UInt32(SECTOR_SIZE) - within
        if chunk > len - done { chunk = len - done }
        var i: UInt32 = 0
        while i < chunk {
            out.storeBytes(of: bounce.load(fromByteOffset: Int(within + i), as: UInt8.self),
                           toByteOffset: Int(done + i), as: UInt8.self)
            i += 1
        }
        done += chunk
    }
    return 0
}
