// SPDX-License-Identifier: Apache-2.0
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
private let VIRTIO_BLK_T_OUT: UInt32 = 1 // write from memory to disk (U1b)
private let SECTOR_SIZE = 512

// U1f-2a: multi-sector transfers. One request can move up to BLK_MULTI_SECTORS
// consecutive sectors via a single variable-length data descriptor, instead of
// one sector per request. This is the prerequisite for staging a multi-MB image
// (U1f-2b): copying it one sector at a time is far too slow under TCG. The DMA
// region (blkMultiBase) is BLK_MULTI_PAGES contiguous PMM pages, allocated once.
private let BLK_MULTI_SECTORS = 128   // 64 KiB per request
private let BLK_MULTI_PAGES = (BLK_MULTI_SECTORS * SECTOR_SIZE + 4095) / 4096

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
private var blkMultiBase: UInt = 0  // PA of the BLK_MULTI_PAGES-page multi-sector DMA region (U1f-2a)
private var blkQn: UInt32 = 0
private var blkAvailIdx: UInt16 = 0
private var blkLastUsed: UInt16 = 0
private var blkCapacity: UInt64 = 0 // device capacity in 512-byte sectors

// U1a (A/B update store): byte offset added to every base-image read
// (virtioBlkReadRange). 0 means "the base image starts at sector 0 of the
// selected disk" (the legacy single-image case). On an A/B update-store disk
// the kernel sets this to the active slot's image offset so the unchanged VFS
// mount/verify path reads the active slot transparently. blkFallbackByteOffset
// is the known-good slot's offset, consumed once by virtioBlkUseFallbackBase()
// if the active slot fails verification. SMP: set once at boot before EL0 runs.
private let blkNoFallback: UInt64 = .max
private var blkBaseByteOffset: UInt64 = 0
private var blkFallbackByteOffset: UInt64 = blkNoFallback

// U1f: when an A/B update-store disk is the selected device, blkStoreMmio is its
// MMIO base (so we can re-select it) and blkPayloadMmio is a separate SWOSBASE
// disk attached as the update payload (0 if none). The single-device driver
// reaches the payload by re-bringing-up between the two (operations are serial
// on the single CPU); reads are slot/offset-relative only on the store path.
// SMP: set once at boot before EL0 runs.
private var blkStoreMmio: UInt = 0
private var blkPayloadMmio: UInt = 0

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

// True if the bounce buffer currently starts with the "SWOSBOOT" magic of an
// A/B update-store disk (the boot manifest sits at sector 0). Preferred over a
// bare SWOSBASE disk when both are attached.
private func blkBounceIsSwosboot() -> Bool {
    let bounce = UnsafeRawPointer(bitPattern: blkDataBase + OFF_BOUNCE)!
    let magic: StaticString = "SWOSBOOT"
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

// Write the bounce buffer (already filled by the caller) to one sector. Returns
// 0 on success. U1b: lets the kernel persist the SWOSBOOT boot manifest. The
// data descriptor is device-READABLE here (no F_WRITE) — the device reads our
// bytes and stores them; only the status byte is device-written.
private func blkDoWrite(_ sector: UInt64) -> Int32 {
    if blkMmio == 0 { return -1 }
    if blkCapacity != 0 && sector >= blkCapacity { return -2 }

    let hdr = blkDataBase + OFF_HDR
    let status = blkDataBase + OFF_STATUS
    let bounce = blkDataBase + OFF_BOUNCE

    let hp = UnsafeMutableRawPointer(bitPattern: hdr)!
    hp.storeBytes(of: VIRTIO_BLK_T_OUT, toByteOffset: 0, as: UInt32.self) // type
    hp.storeBytes(of: UInt32(0), toByteOffset: 4, as: UInt32.self)        // reserved
    hp.storeBytes(of: sector, toByteOffset: 8, as: UInt64.self)
    UnsafeMutableRawPointer(bitPattern: status)!.storeBytes(of: UInt8(0xFF), toByteOffset: 0, as: UInt8.self)
    blkClean(hdr, 16)
    blkClean(status, 1)
    blkClean(bounce, SECTOR_SIZE) // flush our data so the device reads it

    // Three-descriptor chain: header (device-read), data (device-read),
    // status (device-write).
    blkDescSet(0, addr: UInt64(hdr), len: 16, flags: VIRTQ_DESC_F_NEXT, next: 1)
    blkDescSet(1, addr: UInt64(bounce), len: UInt32(SECTOR_SIZE),
               flags: VIRTQ_DESC_F_NEXT, next: 2)
    blkDescSet(2, addr: UInt64(status), len: 1, flags: VIRTQ_DESC_F_WRITE, next: 0)
    blkClean(blkRingBase + OFF_DESC, BLK_QSZ * 16)

    blkAvailAdd(descIdx: 0)
    blkClean(blkRingBase + OFF_AVAIL, 32)

    mmio_write32(blkMmio + R_QNOTIFY, 0)

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
    return 0
}

// U1f-2a: transfer `count` (1...BLK_MULTI_SECTORS) consecutive sectors between
// the disk and the multi-sector DMA region (blkMultiBase) in a single virtio
// request, using one variable-length data descriptor (count*512 bytes). `write`
// selects T_OUT — the data descriptor is device-READABLE, the device stores our
// bytes — vs T_IN, device-writable. The caller fills blkMultiBase before a write
// and reads it after a read. Returns 0 on success, negative on error.
private func blkDoMulti(_ sector: UInt64, _ count: Int, write: Bool) -> Int32 {
    if blkMmio == 0 { return -1 }
    if count < 1 || count > BLK_MULTI_SECTORS { return -4 }
    if blkCapacity != 0 && sector &+ UInt64(count) > blkCapacity { return -2 }

    let hdr = blkDataBase + OFF_HDR
    let status = blkDataBase + OFF_STATUS
    let data = blkMultiBase
    let nbytes = count * SECTOR_SIZE

    let hp = UnsafeMutableRawPointer(bitPattern: hdr)!
    hp.storeBytes(of: write ? VIRTIO_BLK_T_OUT : VIRTIO_BLK_T_IN, toByteOffset: 0, as: UInt32.self)
    hp.storeBytes(of: UInt32(0), toByteOffset: 4, as: UInt32.self)
    hp.storeBytes(of: sector, toByteOffset: 8, as: UInt64.self)
    UnsafeMutableRawPointer(bitPattern: status)!.storeBytes(of: UInt8(0xFF), toByteOffset: 0, as: UInt8.self)
    blkClean(hdr, 16)
    blkClean(status, 1)
    blkClean(data, nbytes) // flush our bytes (write) / evict dirty lines (read)

    // Three-descriptor chain: header (device-read), data, status (device-write).
    let dataFlags: UInt16 = write ? VIRTQ_DESC_F_NEXT : (VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_WRITE)
    blkDescSet(0, addr: UInt64(hdr), len: 16, flags: VIRTQ_DESC_F_NEXT, next: 1)
    blkDescSet(1, addr: UInt64(data), len: UInt32(nbytes), flags: dataFlags, next: 2)
    blkDescSet(2, addr: UInt64(status), len: 1, flags: VIRTQ_DESC_F_WRITE, next: 0)
    blkClean(blkRingBase + OFF_DESC, BLK_QSZ * 16)

    blkAvailAdd(descIdx: 0)
    blkClean(blkRingBase + OFF_AVAIL, 32)

    mmio_write32(blkMmio + R_QNOTIFY, 0)

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
    if !write { blkInvalidate(data, nbytes) }
    return 0
}

// Scan the virtio-mmio window (base/stride/count from the HAL) for block
// devices and select the disk to serve the read-only base from. A boot medium
// may carry several disks (e.g. a GPT boot disk plus the base storage), so we
// prefer, in order: an A/B update-store disk ("SWOSBOOT" magic at sector 0),
// then a packed base image ("SWOSBASE"), then the first block device. Returns
// the selected disk's capacity in sectors, or 0. For an update-store disk the
// caller then runs updateStoreInit() to pick a slot and set the base offset.
func virtioBlkInit(_ base: UInt, _ stride: UInt, _ count: UInt32) -> UInt64 {
    blkMmio = 0
    blkBaseByteOffset = 0
    blkFallbackByteOffset = blkNoFallback
    blkStoreMmio = 0
    blkPayloadMmio = 0
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
    if blkMultiBase == 0 {
        let mb = pmm_alloc_pages(BLK_MULTI_PAGES)
        if mb == 0 { return 0 }
        blkMultiBase = mb
    }

    // Scan all block devices, classifying each by its sector-0 magic. A store
    // disk wins selection; a separate SWOSBASE disk is the base image, or — when
    // a store is present — the A/B update payload (U1f).
    var first: UInt = 0
    var baseDev: UInt = 0
    var storeDev: UInt = 0
    var i: UInt32 = 0
    while i < count {
        let m = base + UInt(i) * stride
        i += 1
        if mmio_read32(m + R_MAGIC) != VIRTIO_MAGIC { continue }
        if mmio_read32(m + R_VERSION) != 2 { continue }      // modern only
        if mmio_read32(m + R_DEVID) != VIRTIO_ID_BLOCK { continue }
        if first == 0 { first = m }
        if blkBringUp(m) == 0 { continue }
        if blkDoRead(0) != 0 { continue }
        if storeDev == 0 && blkBounceIsSwosboot() { storeDev = m }
        else if baseDev == 0 && blkBounceIsSwosbase() { baseDev = m }
    }

    if storeDev != 0 {
        // A/B update-store disk: serve the base from it; a SWOSBASE disk attached
        // alongside is the update payload (U1f).
        blkStoreMmio = storeDev
        blkPayloadMmio = baseDev
        return blkBringUp(storeDev)
    }
    // No update-store disk: prefer a SWOSBASE base image, else the first device.
    if baseDev != 0 { return blkBringUp(baseDev) }
    if first != 0 { return blkBringUp(first) }
    blkMmio = 0
    return 0
}

func virtioBlkAvailable() -> Bool { blkMmio != 0 }
func virtioBlkCapacity() -> UInt64 { blkCapacity }

// --- A/B update store: active/fallback slot offsets (U1a) --------------------
// True if the selected disk is an A/B update-store disk (sector 0 is SWOSBOOT).
func virtioBlkIsUpdateStore() -> Bool { blkMmio != 0 && blkBounceMagicIsSwosboot() }
// Re-reads sector 0; used by updateStoreInit before it parses the manifest.
private func blkBounceMagicIsSwosboot() -> Bool {
    blkDoRead(0) == 0 && blkBounceIsSwosboot()
}
// Point base-image reads at the active slot's image offset (bytes from sector 0).
func virtioBlkSetBaseByteOffset(_ off: UInt64) { blkBaseByteOffset = off }
// Record the known-good fallback slot's offset for virtioBlkUseFallbackBase().
func virtioBlkSetFallbackByteOffset(_ off: UInt64) { blkFallbackByteOffset = off }
// True once the base offset names an A/B slot rather than the legacy sector 0.
func virtioBlkUsingStore() -> Bool { blkBaseByteOffset != 0 }
// Switch base reads to the fallback slot (consumed once). Returns false if there
// is no distinct fallback, so the caller does not loop.
func virtioBlkUseFallbackBase() -> Bool {
    if blkFallbackByteOffset == blkNoFallback { return false }
    if blkFallbackByteOffset == blkBaseByteOffset { return false }
    blkBaseByteOffset = blkFallbackByteOffset
    blkFallbackByteOffset = blkNoFallback
    return true
}

// --- A/B update payload disk (U1f) ------------------------------------------
// True if a separate SWOSBASE disk is attached as the update payload.
func virtioBlkHasPayload() -> Bool { blkPayloadMmio != 0 }
// Re-bring-up and select the payload device for reading; returns its capacity in
// sectors (0 if none/failed). Operations are serial on the single CPU, so the
// caller reads what it needs, then calls virtioBlkReselectStore(). Reads on the
// payload are absolute (blkBaseByteOffset applies only to the store base path).
func virtioBlkSelectPayload() -> UInt64 {
    if blkPayloadMmio == 0 { return 0 }
    return blkBringUp(blkPayloadMmio)
}
// Re-select the update-store disk after using the payload.
func virtioBlkReselectStore() {
    if blkStoreMmio != 0 { _ = blkBringUp(blkStoreMmio) }
}

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

// Write one 512-byte sector from `buf` to absolute `sector`. Returns 0 on
// success. Absolute (NOT slot-relative): U1b uses it to persist the SWOSBOOT
// boot manifest at LBA 0/1, which lives outside the A/B image slots.
func virtioBlkWriteSector(_ sector: UInt64, _ buf: UnsafeRawPointer?) -> Int32 {
    if blkMmio == 0 { return -1 }
    guard let src = buf else { return -1 }
    let bounce = UnsafeMutableRawPointer(bitPattern: blkDataBase + OFF_BOUNCE)!
    var i = 0
    while i < SECTOR_SIZE {
        bounce.storeBytes(of: src.load(fromByteOffset: i, as: UInt8.self), toByteOffset: i, as: UInt8.self)
        i += 1
    }
    return blkDoWrite(sector)
}

// U1f-2a: read `count` (1...BLK_MULTI_SECTORS) consecutive 512-byte sectors from
// absolute `sector` into `buf` in a single virtio request — far fewer round
// trips than looping virtioBlkRead, which is what makes staging a multi-MB image
// (U1f-2b) tractable under TCG. Absolute, like virtioBlkRead; the A/B slot offset
// (blkBaseByteOffset) applies only to virtioBlkReadRange.
func virtioBlkReadSectors(_ sector: UInt64, _ buf: UnsafeMutableRawPointer?, _ count: Int) -> Int32 {
    guard let dst = buf else { return -1 }
    let rc = blkDoMulti(sector, count, write: false)
    if rc != 0 { return rc }
    dst.copyMemory(from: UnsafeRawPointer(bitPattern: blkMultiBase)!, byteCount: count * SECTOR_SIZE)
    return 0
}

// U1f-2a: write `count` (1...BLK_MULTI_SECTORS) consecutive 512-byte sectors from
// `buf` to absolute `sector` in a single virtio request. Absolute, like
// virtioBlkWriteSector.
func virtioBlkWriteSectors(_ sector: UInt64, _ buf: UnsafeRawPointer?, _ count: Int) -> Int32 {
    guard let src = buf else { return -1 }
    if count < 1 || count > BLK_MULTI_SECTORS { return -4 }
    UnsafeMutableRawPointer(bitPattern: blkMultiBase)!.copyMemory(from: src, byteCount: count * SECTOR_SIZE)
    return blkDoMulti(sector, count, write: true)
}

// U1f-2b: the stage copy moves sectors disk-to-disk through the driver's own
// multi-sector DMA buffer with NO intermediate kernel copy. blkMultiBase
// survives a bring-up (only the ring page is re-initialized), so the caller can
// read into it from the payload device, re-select the store, and write it back.
// The maximum sectors per call (so the caller chunks correctly).
func virtioBlkMultiMax() -> Int { BLK_MULTI_SECTORS }
// Read `count` sectors from absolute `sector` of the current device into the
// internal DMA buffer (no copy out). Pair with virtioBlkFlushMulti.
func virtioBlkFillMulti(_ sector: UInt64, _ count: Int) -> Int32 { blkDoMulti(sector, count, write: false) }
// Write the internal DMA buffer's first `count` sectors to absolute `sector` of
// the current device. Pair with virtioBlkFillMulti.
func virtioBlkFlushMulti(_ sector: UInt64, _ count: Int) -> Int32 { blkDoMulti(sector, count, write: true) }

// Read an arbitrary byte range [byteOff, byteOff+len) into `buf`, spanning
// sectors as needed. Returns 0 on success, negative on error. Used to back the
// read-only VFS with extents into the disk image (M11c). U1f-2a: pulls whole
// runs of sectors per request (blkDoMulti) instead of one at a time — the signed
// base image's per-file content hashes (vfsInit) end-to-end verify these reads.
func virtioBlkReadRange(_ byteOff: UInt64, _ buf: UnsafeMutableRawPointer?, _ len: UInt32) -> Int32 {
    if blkMmio == 0 { return -1 }
    guard let out = buf else { return -1 }
    let multi = UnsafeRawPointer(bitPattern: blkMultiBase)!
    var done: UInt32 = 0
    while done < len {
        // U1a: reads are relative to the active A/B slot's image offset (0 for
        // the legacy single-image disk), so the VFS mount/verify path is slot
        // agnostic.
        let pos = blkBaseByteOffset + byteOff + UInt64(done)
        let sec = pos / UInt64(SECTOR_SIZE)
        let within = UInt32(pos % UInt64(SECTOR_SIZE))
        // Cover within+remaining bytes, capped to the DMA region and capacity.
        let need = UInt64(within) + UInt64(len - done)
        var secCount = Int((need + UInt64(SECTOR_SIZE) - 1) / UInt64(SECTOR_SIZE))
        if secCount > BLK_MULTI_SECTORS { secCount = BLK_MULTI_SECTORS }
        if blkCapacity != 0 && sec + UInt64(secCount) > blkCapacity {
            secCount = Int(blkCapacity - sec)
        }
        if secCount < 1 { return -2 }
        let rc = blkDoMulti(sec, secCount, write: false)
        if rc != 0 { return rc }
        var chunk = UInt32(secCount * SECTOR_SIZE) - within
        if chunk > len - done { chunk = len - done }
        out.advanced(by: Int(done)).copyMemory(
            from: multi.advanced(by: Int(within)), byteCount: Int(chunk))
        done += chunk
    }
    return 0
}
