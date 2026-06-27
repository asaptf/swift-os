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
private let R_DEVFEAT: UInt    = 0x010
private let R_DEVFEATSEL: UInt = 0x014
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

private let VIRTIO_BLK_T_IN: UInt32 = 0    // read from disk into memory
private let VIRTIO_BLK_T_OUT: UInt32 = 1   // write from memory to disk (U1b)
private let VIRTIO_BLK_T_FLUSH: UInt32 = 4 // flush the device write cache to media (U1h)
private let VIRTIO_BLK_F_FLUSH: UInt32 = 1 << 9 // device feature: cache-flush command supported
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
private var blkActiveDevice = -1
private var blkFlushOK: Bool = false // current device negotiated VIRTIO_BLK_F_FLUSH

private let maxBlkDevices = 8
private let maxSwosbaseImages = 4
private var blkDeviceMmio = [UInt](repeating: 0, count: maxBlkDevices)
private var blkDeviceCapacity = [UInt64](repeating: 0, count: maxBlkDevices)
private var blkDeviceRingBase = [UInt](repeating: 0, count: maxBlkDevices)
private var blkDeviceDataBase = [UInt](repeating: 0, count: maxBlkDevices)
private var blkDeviceQn = [UInt32](repeating: 0, count: maxBlkDevices)
private var blkDeviceAvailIdx = [UInt16](repeating: 0, count: maxBlkDevices)
private var blkDeviceLastUsed = [UInt16](repeating: 0, count: maxBlkDevices)
private var blkDeviceFlushOK = [Bool](repeating: false, count: maxBlkDevices)
private var blkDeviceReady = [Bool](repeating: false, count: maxBlkDevices)
private var blkDeviceCount = 0
private var swosbaseDevice = [Int](repeating: -1, count: maxSwosbaseImages)
private var swosbaseCount = 0
private var pkgStoreDevice = -1
private var pkgStoreCapacity: UInt64 = 0

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

// U1f: when an A/B update-store disk is selected, blkStoreDevice is its index
// and blkPayloadDevice is a separate SWOSBASE disk attached as the update
// payload (-1 if none). Operations are serial on the single CPU; reads are
// slot/offset-relative only on the store path. SMP: set once at boot before EL0
// runs.
private var blkStoreDevice = -1
private var blkPayloadDevice = -1

// U1g-4: the GPT/ESP boot disk (sector 1 is the "EFI PART" GPT header), when one
// is attached on virtio-mmio alongside the base/store. The kernel reads it to
// find the kernel A/B manifest the loader uses (and, later, to stage kernels).
// blkServedDevice is the device the base/store is served from, so we can
// re-select it after a detour to the ESP disk. SMP: set once at boot before EL0
// runs.
private var blkEspDevice = -1
private var blkServedDevice = -1

// D0: a writable persistent "data" disk, identified by the sector-0 magic
// "SWDATAFS". Distinct from the read-only base/store/ESP; it hosts the /data tier
// (datafs, D1+). SMP: set once at boot before EL0 runs.
private var blkDataDevice = -1

// V1: every writable SWDATAFS "data" disk, in scan order, so additional disks /
// Hetzner Volumes can be mounted as further datafs volumes. blkDataDevices[0] is
// the same device as blkDataDevice (= datafs volume 0 = /data); 1..N mount under
// /mnt. SMP: set once at boot before EL0 runs.
private let maxDataVolumes = 4
private var blkDataDevices = [Int](repeating: -1, count: maxDataVolumes)
private var blkDataDeviceCount = 0

// D2: count successful data-disk cache flushes (fsync/sync), for the boot self-test.
private var blkDataFlushes: UInt64 = 0

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
private func blkSaveActiveState() {
    if blkActiveDevice < 0 || blkActiveDevice >= maxBlkDevices { return }
    blkDeviceAvailIdx[blkActiveDevice] = blkAvailIdx
    blkDeviceLastUsed[blkActiveDevice] = blkLastUsed
    blkDeviceFlushOK[blkActiveDevice] = blkFlushOK
}

private func blkLoadActiveState(_ index: Int) {
    blkMmio = blkDeviceMmio[index]
    blkRingBase = blkDeviceRingBase[index]
    blkDataBase = blkDeviceDataBase[index]
    blkQn = blkDeviceQn[index]
    blkAvailIdx = blkDeviceAvailIdx[index]
    blkLastUsed = blkDeviceLastUsed[index]
    blkCapacity = blkDeviceCapacity[index]
    blkFlushOK = blkDeviceFlushOK[index]
    blkActiveDevice = index
}

// Bring up a single virtio-blk device: reset, negotiate, set up its private
// request virtqueue, and read the capacity. Returns capacity in sectors.
private func blkBringUp(_ index: Int) -> UInt64 {
    if index < 0 || index >= blkDeviceCount { return 0 }
    blkSaveActiveState()
    blkMmio = blkDeviceMmio[index]
    blkActiveDevice = index

    if blkDeviceRingBase[index] == 0 {
        let r = pmm_alloc_page()
        if r == 0 { blkMmio = 0; blkActiveDevice = -1; return 0 }
        blkDeviceRingBase[index] = r
    }
    if blkDeviceDataBase[index] == 0 {
        let d = pmm_alloc_page()
        if d == 0 { blkMmio = 0; blkActiveDevice = -1; return 0 }
        blkDeviceDataBase[index] = d
    }
    blkRingBase = blkDeviceRingBase[index]
    blkDataBase = blkDeviceDataBase[index]
    if blkMultiBase == 0 {
        let mb = pmm_alloc_pages(BLK_MULTI_PAGES)
        if mb == 0 { blkMmio = 0; blkActiveDevice = -1; return 0 }
        blkMultiBase = mb
    }

    mmio_write32(blkMmio + R_STATUS, 0)               // reset
    mmio_write32(blkMmio + R_STATUS, S_ACK)
    mmio_write32(blkMmio + R_STATUS, S_ACK | S_DRV)
    // Accept VIRTIO_F_VERSION_1 (feature bit 32, word 1). In word 0 accept only
    // VIRTIO_BLK_F_FLUSH if offered; ignore every other block feature.
    blkFlushOK = false
    mmio_write32(blkMmio + R_DEVFEATSEL, 0)
    let dev0 = mmio_read32(blkMmio + R_DEVFEAT)
    var drv0: UInt32 = 0
    if (dev0 & VIRTIO_BLK_F_FLUSH) != 0 {
        drv0 |= VIRTIO_BLK_F_FLUSH
        blkFlushOK = true
    }
    mmio_write32(blkMmio + R_DRVFEATSEL, 1); mmio_write32(blkMmio + R_DRVFEAT, 1)
    mmio_write32(blkMmio + R_DRVFEATSEL, 0); mmio_write32(blkMmio + R_DRVFEAT, drv0)
    mmio_write32(blkMmio + R_STATUS, S_ACK | S_DRV | S_FEATOK)
    if (mmio_read32(blkMmio + R_STATUS) & S_FEATOK) == 0 { blkMmio = 0; blkActiveDevice = -1; return 0 }

    mmio_write32(blkMmio + R_QSEL, 0)
    let maxq = mmio_read32(blkMmio + R_QNUMMAX)
    if maxq == 0 { blkMmio = 0; blkActiveDevice = -1; return 0 }
    blkQn = maxq < UInt32(BLK_QSZ) ? maxq : UInt32(BLK_QSZ)
    mmio_write32(blkMmio + R_QNUM, blkQn)

    blkZeroPage(blkRingBase)
    blkAvailIdx = 0
    blkLastUsed = 0
    blkClean(blkRingBase + OFF_AVAIL, 32)
    blkClean(blkRingBase + OFF_USED, 72)

    let da = UInt64(blkRingBase + OFF_DESC)
    let aa = UInt64(blkRingBase + OFF_AVAIL)
    let ua = UInt64(blkRingBase + OFF_USED)
    mmio_write32(blkMmio + R_QDESCL, UInt32(da & 0xFFFF_FFFF)); mmio_write32(blkMmio + R_QDESCH, UInt32(da >> 32))
    mmio_write32(blkMmio + R_QDRVL,  UInt32(aa & 0xFFFF_FFFF)); mmio_write32(blkMmio + R_QDRVH,  UInt32(aa >> 32))
    mmio_write32(blkMmio + R_QDEVL,  UInt32(ua & 0xFFFF_FFFF)); mmio_write32(blkMmio + R_QDEVH,  UInt32(ua >> 32))
    mmio_write32(blkMmio + R_QREADY, 1)
    mmio_write32(blkMmio + R_STATUS, S_ACK | S_DRV | S_FEATOK | S_DRVOK)

    // Capacity (config space offset 0): number of 512-byte sectors, LE u64.
    let lo = mmio_read32(blkMmio + R_CONFIG + 0)
    let hi = mmio_read32(blkMmio + R_CONFIG + 4)
    blkCapacity = (UInt64(hi) << 32) | UInt64(lo)
    blkDeviceCapacity[index] = blkCapacity
    blkDeviceQn[index] = blkQn
    blkDeviceAvailIdx[index] = blkAvailIdx
    blkDeviceLastUsed[index] = blkLastUsed
    blkDeviceFlushOK[index] = blkFlushOK
    blkDeviceReady[index] = true
    return blkCapacity
}

private func blkSelectDevice(_ index: Int) -> Bool {
    if index < 0 || index >= blkDeviceCount { return false }
    if blkActiveDevice == index { return true }
    blkSaveActiveState()
    if blkDeviceReady[index] {
        blkLoadActiveState(index)
        return blkMmio != 0 && blkRingBase != 0 && blkDataBase != 0
    }
    return blkBringUp(index) != 0
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

private func blkBounceIsPackageStore() -> Bool {
    let bounce = UnsafeRawPointer(bitPattern: blkDataBase + OFF_BOUNCE)!
    let magic: StaticString = "SWPKGST1"
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

// True if the bounce buffer currently starts with the GPT header magic
// "EFI PART" (the GPT header lives at LBA 1). Used to pick out the ESP/GPT boot
// disk among several block devices (U1g-4).
private func blkBounceIsEfiPart() -> Bool {
    let bounce = UnsafeRawPointer(bitPattern: blkDataBase + OFF_BOUNCE)!
    let magic: StaticString = "EFI PART"
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

// True if the bounce buffer currently starts with the "SWDATAFS" magic of the
// persistent /data disk (datafs superblock at sector 0). D0 stamps the magic on
// the host-built image; D1 fills in the rest of the superblock.
private func blkBounceIsDataFs() -> Bool {
    let bounce = UnsafeRawPointer(bitPattern: blkDataBase + OFF_BOUNCE)!
    let magic: StaticString = "SWDATAFS"
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

// Write the internal bounce buffer to one sector on the currently selected
// device. Returns 0 on success. The caller chooses the device through
// blkSelectDevice and prepares the bounce contents.
private func blkDoWriteBounce(_ sector: UInt64) -> Int32 {
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

// Write one sector from `src` to the currently selected device. Returns 0 on
// success. The caller chooses the device through blkSelectDevice.
private func blkDoWrite(_ sector: UInt64, _ src: UnsafeRawPointer?) -> Int32 {
    guard let input = src else { return -1 }
    let bp = UnsafeMutableRawPointer(bitPattern: blkDataBase + OFF_BOUNCE)!
    var i = 0
    while i < SECTOR_SIZE {
        bp.storeBytes(of: input.load(fromByteOffset: i, as: UInt8.self), toByteOffset: i, as: UInt8.self)
        i += 1
    }
    return blkDoWriteBounce(sector)
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

// U1h: ask the device to flush its write cache to stable media. A two-descriptor
// chain — header (device-read, type=FLUSH, sector 0) + status (device-write) —
// with no data. Returns 0 on success (or when the device does not support FLUSH:
// there is nothing to flush, so a write was already as durable as it gets). The
// kernel issues this after committing a manifest or staged-slot write so those
// survive a host crash even with a write-back host cache (no cache=writethrough).
private func blkDoFlush() -> Int32 {
    if blkMmio == 0 { return -1 }
    if !blkFlushOK { return 0 } // device has no volatile write cache to flush

    let hdr = blkDataBase + OFF_HDR
    let status = blkDataBase + OFF_STATUS

    let hp = UnsafeMutableRawPointer(bitPattern: hdr)!
    hp.storeBytes(of: VIRTIO_BLK_T_FLUSH, toByteOffset: 0, as: UInt32.self)
    hp.storeBytes(of: UInt32(0), toByteOffset: 4, as: UInt32.self) // reserved
    hp.storeBytes(of: UInt64(0), toByteOffset: 8, as: UInt64.self) // sector (ignored for FLUSH)
    UnsafeMutableRawPointer(bitPattern: status)!.storeBytes(of: UInt8(0xFF), toByteOffset: 0, as: UInt8.self)
    blkClean(hdr, 16)
    blkClean(status, 1)

    blkDescSet(0, addr: UInt64(hdr), len: 16, flags: VIRTQ_DESC_F_NEXT, next: 1)
    blkDescSet(1, addr: UInt64(status), len: 1, flags: VIRTQ_DESC_F_WRITE, next: 0)
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

// Scan the virtio-mmio window (base/stride/count from the HAL) for block
// devices and select the disk to serve the read-only base from. A boot medium
// may carry several disks (e.g. a GPT boot disk plus the base storage), so we
// prefer, in order: an A/B update-store disk ("SWOSBOOT" magic at sector 0),
// then a packed base image ("SWOSBASE"), then the first block device. Returns
// the selected disk's capacity in sectors, or 0. For an update-store disk the
// caller then runs updateStoreInit() to pick a slot and set the base offset.
func virtioBlkInit(_ base: UInt, _ stride: UInt, _ count: UInt32) -> UInt64 {
    blkMmio = 0
    blkActiveDevice = -1
    blkFlushOK = false
    blkDeviceCount = 0
    swosbaseCount = 0
    pkgStoreDevice = -1
    pkgStoreCapacity = 0
    blkBaseByteOffset = 0
    blkFallbackByteOffset = blkNoFallback
    blkStoreDevice = -1
    blkPayloadDevice = -1
    blkEspDevice = -1
    blkServedDevice = -1
    blkDataDevice = -1
    blkDataDeviceCount = 0
    for j in 0..<maxDataVolumes { blkDataDevices[j] = -1 }
    for j in 0..<maxBlkDevices {
        blkDeviceMmio[j] = 0
        blkDeviceCapacity[j] = 0
        blkDeviceRingBase[j] = 0
        blkDeviceDataBase[j] = 0
        blkDeviceQn[j] = 0
        blkDeviceAvailIdx[j] = 0
        blkDeviceLastUsed[j] = 0
        blkDeviceFlushOK[j] = false
        blkDeviceReady[j] = false
    }
    for j in 0..<maxSwosbaseImages { swosbaseDevice[j] = -1 }

    // Scan all block devices, classifying each by its sector-0 magic. A store
    // disk wins selection; a separate SWOSBASE disk is the base image, or — when
    // a store is present — the A/B update payload (U1f).
    var firstIndex = -1
    var baseDev = -1
    var storeDev = -1
    var espDev = -1
    var dataFsDev = -1
    var i: UInt32 = 0
    while i < count {
        let m = base + UInt(i) * stride
        i += 1
        if mmio_read32(m + R_MAGIC) != VIRTIO_MAGIC { continue }
        if mmio_read32(m + R_VERSION) != 2 { continue }      // modern only
        if mmio_read32(m + R_DEVID) != VIRTIO_ID_BLOCK { continue }
        if blkDeviceCount >= maxBlkDevices { continue }
        let devIndex = blkDeviceCount
        blkDeviceCount += 1
        blkDeviceMmio[devIndex] = m
        if firstIndex < 0 { firstIndex = devIndex }
        if blkBringUp(devIndex) == 0 { continue }
        if blkDoRead(0) == 0 {
            if storeDev < 0 && blkBounceIsSwosboot() {
                storeDev = devIndex
            } else if blkBounceIsSwosbase() {
                if baseDev < 0 { baseDev = devIndex }
                if swosbaseCount < maxSwosbaseImages {
                    swosbaseDevice[swosbaseCount] = devIndex
                    swosbaseCount += 1
                }
            } else if blkBounceIsPackageStore() && pkgStoreDevice < 0 {
                pkgStoreDevice = devIndex
                pkgStoreCapacity = blkCapacity
            } else if blkBounceIsDataFs() {
                if dataFsDev < 0 { dataFsDev = devIndex }   // volume 0 = /data
                if blkDataDeviceCount < maxDataVolumes {
                    blkDataDevices[blkDataDeviceCount] = devIndex
                    blkDataDeviceCount += 1
                }
            }
            if espDev < 0 && blkDoRead(1) == 0 && blkBounceIsEfiPart() {
                espDev = devIndex
            }
        }
    }

    blkEspDevice = espDev
    blkDataDevice = dataFsDev

    if storeDev >= 0 {
        blkStoreDevice = storeDev
        blkPayloadDevice = baseDev
        blkServedDevice = storeDev
        if blkSelectDevice(storeDev) { return blkDeviceCapacity[storeDev] }
    }

    if baseDev >= 0 {
        blkServedDevice = baseDev
        if blkSelectDevice(baseDev) { return blkDeviceCapacity[baseDev] }
    }

    // No SWOSBASE disk; fall back to the first block device (if any).
    if firstIndex >= 0 {
        blkServedDevice = firstIndex
        if blkSelectDevice(firstIndex) { return blkDeviceCapacity[firstIndex] }
    }
    blkMmio = 0
    blkActiveDevice = -1
    return 0
}

func virtioBlkAvailable() -> Bool { blkServedDevice >= 0 || swosbaseCount > 0 || blkMmio != 0 }
func virtioBlkCapacity() -> UInt64 {
    if blkServedDevice >= 0 { return blkDeviceCapacity[blkServedDevice] }
    if swosbaseCount > 0 { return blkDeviceCapacity[swosbaseDevice[0]] }
    return blkCapacity
}
func virtioBlkSwosbaseImageCount() -> Int { swosbaseCount }
func virtioBlkPackageStoreAvailable() -> Bool { pkgStoreDevice >= 0 }
func virtioBlkPackageStoreCapacityBytes() -> UInt64 { pkgStoreCapacity * UInt64(SECTOR_SIZE) }

// --- generalized per-volume block I/O (V0: multi-volume datafs) --------------
// A "volume" is any writable virtio-blk device that carries a datafs. The
// datafs layer is device-indexed: slot 0 binds the legacy persistent /data disk
// (blkDataDevice), and later volumes bind additional writable disks/Hetzner
// Volumes. Each call restores the served base/store device afterward, exactly
// like the original D0 path, so later base reads are unaffected.

// The device index of the legacy persistent /data disk (datafs volume 0), or -1.
func virtioBlkDataDeviceIndex() -> Int { blkDataDevice }
// V1: number of writable SWDATAFS data volumes discovered (>=1 when /data exists).
func virtioBlkDataVolumeCount() -> Int { blkDataDeviceCount }
// The virtio-blk device backing data volume `ordinal` (0 = /data), or -1.
func virtioBlkDataDeviceIndexAt(_ ordinal: Int) -> Int {
    if ordinal < 0 || ordinal >= blkDataDeviceCount { return -1 }
    return blkDataDevices[ordinal]
}
// Capacity of `dev` in 512-byte sectors (0 if out of range / absent).
func virtioBlkVolumeCapacitySectors(_ dev: Int) -> UInt64 {
    if dev < 0 || dev >= blkDeviceCount { return 0 }
    return blkDeviceCapacity[dev]
}
// Read [byteOff, byteOff+len) from `dev` into `buf`. 0 on success.
func virtioBlkVolumeReadRange(_ dev: Int, _ byteOff: UInt64, _ buf: UnsafeMutableRawPointer?, _ len: UInt32) -> Int32 {
    if dev < 0 { return -1 }
    let rc = virtioBlkReadRangeFromDevice(dev, byteOff, buf, len)
    if blkServedDevice >= 0 { _ = blkSelectDevice(blkServedDevice) }
    return rc
}
// Write `buf` to [byteOff, byteOff+len) on `dev` (read-modify-write for partial
// sectors), bounds-checked against the device capacity. 0 on success.
func virtioBlkVolumeWriteRange(_ dev: Int, _ byteOff: UInt64, _ buf: UnsafeRawPointer?, _ len: UInt32) -> Int32 {
    if dev < 0 || dev >= blkDeviceCount { return -1 }
    let cap = blkDeviceCapacity[dev] * UInt64(SECTOR_SIZE)
    if byteOff + UInt64(len) > cap { return -2 }
    let rc = virtioBlkWriteRangeToDevice(dev, byteOff, buf, len)
    if blkServedDevice >= 0 { _ = blkSelectDevice(blkServedDevice) }
    return rc
}
// Flush `dev`'s write cache to stable media. Pairs with a preceding write so it
// survives a host crash. The /data disk's success counter (D2) is preserved for
// its compatibility wrapper below. 0 on success.
func virtioBlkVolumeFlush(_ dev: Int) -> Int32 {
    if dev < 0 { return -1 }
    if !blkSelectDevice(dev) { return -1 }
    let rc = blkDoFlush()
    if rc == 0 && dev == blkDataDevice { blkDataFlushes &+= 1 }
    if blkServedDevice >= 0 { _ = blkSelectDevice(blkServedDevice) }
    return rc
}

// --- persistent /data disk (D0) — compatibility wrappers over volume 0 -------
// True if a writable persistent data disk (sector-0 magic "SWDATAFS") is present.
func virtioBlkDataAvailable() -> Bool { blkDataDevice >= 0 }
// Capacity of the data disk in 512-byte sectors (0 if none).
func virtioBlkDataCapacitySectors() -> UInt64 { virtioBlkVolumeCapacitySectors(blkDataDevice) }
func virtioBlkDataReadRange(_ byteOff: UInt64, _ buf: UnsafeMutableRawPointer?, _ len: UInt32) -> Int32 {
    virtioBlkVolumeReadRange(blkDataDevice, byteOff, buf, len)
}
func virtioBlkDataWriteRange(_ byteOff: UInt64, _ buf: UnsafeRawPointer?, _ len: UInt32) -> Int32 {
    virtioBlkVolumeWriteRange(blkDataDevice, byteOff, buf, len)
}
func virtioBlkDataFlush() -> Int32 { virtioBlkVolumeFlush(blkDataDevice) }
// D2: number of successful data-disk flushes since boot.
func virtioBlkDataFlushCount() -> UInt64 { blkDataFlushes }

// --- A/B update store: active/fallback slot offsets (U1a) --------------------
// True if the selected disk is an A/B update-store disk (sector 0 is SWOSBOOT).
func virtioBlkIsUpdateStore() -> Bool {
    if blkStoreDevice < 0 { return false }
    if !blkSelectDevice(blkStoreDevice) { return false }
    return blkBounceMagicIsSwosboot()
}
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
func virtioBlkHasPayload() -> Bool { blkPayloadDevice >= 0 }
// Re-bring-up and select the payload device for reading; returns its capacity in
// sectors (0 if none/failed). Operations are serial on the single CPU, so the
// caller reads what it needs, then calls virtioBlkReselectStore(). Reads on the
// payload are absolute (blkBaseByteOffset applies only to the store base path).
func virtioBlkSelectPayload() -> UInt64 {
    if blkPayloadDevice < 0 { return 0 }
    if !blkSelectDevice(blkPayloadDevice) { return 0 }
    return blkDeviceCapacity[blkPayloadDevice]
}
// Re-select the update-store disk after using the payload.
func virtioBlkReselectStore() {
    if blkStoreDevice >= 0 { _ = blkSelectDevice(blkStoreDevice) }
}
// OS-3b: write `buf` to [byteOff, byteOff+len) on the update-store disk
// (read-modify-write for partial sectors), bounds-checked against the store
// capacity. Used by the capability-gated slot-staging path to fill the inactive
// A/B slot from a userland buffer. `byteOff` is absolute on the store disk (the
// caller adds the slot's base offset). Restores the served device afterward.
func virtioBlkStoreWriteRange(_ byteOff: UInt64, _ buf: UnsafeRawPointer?, _ len: UInt32) -> Int32 {
    if blkStoreDevice < 0 { return -1 }
    let cap = blkDeviceCapacity[blkStoreDevice] * UInt64(SECTOR_SIZE)
    if byteOff + UInt64(len) > cap { return -2 }
    let rc = virtioBlkWriteRangeToDevice(blkStoreDevice, byteOff, buf, len)
    if blkServedDevice >= 0 { _ = blkSelectDevice(blkServedDevice) }
    return rc
}

// --- ESP/GPT boot disk (U1g-4) ----------------------------------------------
// True if a GPT/ESP boot disk is attached on virtio-mmio (the loader's disk).
func virtioBlkHasEsp() -> Bool { blkEspDevice >= 0 }
// Re-bring-up and select the ESP disk for absolute reads; returns its capacity in
// sectors (0 if none). The caller reads what it needs, then calls
// virtioBlkReselectServed() to return to the base/store. Serial on the one CPU.
func virtioBlkSelectEsp() -> UInt64 {
    if blkEspDevice < 0 { return 0 }
    if !blkSelectDevice(blkEspDevice) { return 0 }
    return blkDeviceCapacity[blkEspDevice]
}
// Re-select the device the base/store is served from (after an ESP detour).
func virtioBlkReselectServed() {
    if blkServedDevice >= 0 { _ = blkSelectDevice(blkServedDevice) }
}

// Read one 512-byte sector from the currently selected device into `buf`.
// Used by explicit device detours such as payload and ESP reads.
func virtioBlkReadCurrent(_ sector: UInt64, _ buf: UnsafeMutableRawPointer?) -> Int32 {
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

// Read one 512-byte sector from the served base/store device into `buf`.
// Blocking: issues the request and spins on the used ring until it completes.
func virtioBlkRead(_ sector: UInt64, _ buf: UnsafeMutableRawPointer?) -> Int32 {
    if blkServedDevice >= 0 && !blkSelectDevice(blkServedDevice) { return -1 }
    return virtioBlkReadCurrent(sector, buf)
}

// Write one 512-byte sector from `buf` to absolute `sector`. Returns 0 on
// success. Absolute (NOT slot-relative): U1b uses it to persist the SWOSBOOT
// boot manifest at LBA 0/1, which lives outside the A/B image slots.
func virtioBlkWriteSector(_ sector: UInt64, _ buf: UnsafeRawPointer?) -> Int32 {
    if blkMmio == 0 { return -1 }
    if blkStoreDevice >= 0 && !blkSelectDevice(blkStoreDevice) { return -1 }
    guard let src = buf else { return -1 }
    let bounce = UnsafeMutableRawPointer(bitPattern: blkDataBase + OFF_BOUNCE)!
    var i = 0
    while i < SECTOR_SIZE {
        bounce.storeBytes(of: src.load(fromByteOffset: i, as: UInt8.self), toByteOffset: i, as: UInt8.self)
        i += 1
    }
    return blkDoWriteBounce(sector)
}

// Write one 512-byte sector to `sector` of the CURRENTLY-SELECTED device (no
// re-select), the write-side mirror of virtioBlkReadCurrent. Used by ESP/FAT
// writes after virtioBlkSelectEsp(): virtioBlkWriteSector would force the store
// device, which mis-targets when a SWOSBOOT store is also attached (the OS-1
// coordinated topology). Caller is responsible for selecting the device first.
func virtioBlkWriteCurrent(_ sector: UInt64, _ buf: UnsafeRawPointer?) -> Int32 {
    if blkMmio == 0 { return -1 }
    guard let src = buf else { return -1 }
    let bounce = UnsafeMutableRawPointer(bitPattern: blkDataBase + OFF_BOUNCE)!
    var i = 0
    while i < SECTOR_SIZE {
        bounce.storeBytes(of: src.load(fromByteOffset: i, as: UInt8.self), toByteOffset: i, as: UInt8.self)
        i += 1
    }
    return blkDoWriteBounce(sector)
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

// U1h: true if the currently-bound device negotiated VIRTIO_BLK_F_FLUSH, i.e. it
// has a volatile write cache that virtioBlkFlush() can push to stable media.
func virtioBlkFlushSupported() -> Bool { blkFlushOK }

// U1h: flush the device write cache to stable media. 0 on success (also when the
// device exposes no flush, since the write is then already durable). Call after
// committing a manifest or staged-slot write so it survives a host crash even
// without a cache=writethrough host backend.
func virtioBlkFlush() -> Int32 { blkDoFlush() }

// Read an arbitrary byte range [byteOff, byteOff+len) into `buf`, spanning
// sectors as needed. Returns 0 on success, negative on error. Used to back the
// read-only VFS with extents into the disk image (M11c). U1f-2a: pulls whole
// runs of sectors per request (blkDoMulti) instead of one at a time — the signed
// base image's per-file content hashes (vfsInit) end-to-end verify these reads.
func virtioBlkReadRange(_ byteOff: UInt64, _ buf: UnsafeMutableRawPointer?, _ len: UInt32) -> Int32 {
    if blkServedDevice < 0 { return -1 }
    return virtioBlkReadRangeFromDevice(blkServedDevice, byteOff, buf, len, applyBaseOffset: true)
}

private func virtioBlkReadRangeFromDevice(_ device: Int, _ byteOff: UInt64,
                                          _ buf: UnsafeMutableRawPointer?, _ len: UInt32,
                                          applyBaseOffset: Bool = false) -> Int32 {
    if device < 0 || device >= blkDeviceCount { return -1 }
    if !blkSelectDevice(device) { return -1 }
    guard let out = buf else { return -1 }
    let multi = UnsafeRawPointer(bitPattern: blkMultiBase)!
    var done: UInt32 = 0
    while done < len {
        // U1a: reads are relative to the active A/B slot's image offset (0 for
        // the legacy single-image disk), so the VFS mount/verify path is slot
        // agnostic.
        let baseOff = applyBaseOffset ? blkBaseByteOffset : 0
        let pos = baseOff + byteOff + UInt64(done)
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

func virtioBlkReadRangeFromImage(_ image: Int, _ byteOff: UInt64, _ buf: UnsafeMutableRawPointer?, _ len: UInt32) -> Int32 {
    if image < 0 || image >= swosbaseCount { return -1 }
    return virtioBlkReadRangeFromDevice(swosbaseDevice[image], byteOff, buf, len)
}

func virtioBlkReadPackageStoreRange(_ byteOff: UInt64, _ buf: UnsafeMutableRawPointer?, _ len: UInt32) -> Int32 {
    if pkgStoreDevice < 0 { return -1 }
    return virtioBlkReadRangeFromDevice(pkgStoreDevice, byteOff, buf, len)
}

private func virtioBlkWriteRangeToDevice(_ device: Int, _ byteOff: UInt64,
                                         _ buf: UnsafeRawPointer?, _ len: UInt32) -> Int32 {
    if len == 0 { return 0 }
    if device < 0 || device >= blkDeviceCount { return -1 }
    if !blkSelectDevice(device) { return -1 }
    guard let input = buf else { return -1 }

    let bounce = UnsafeMutableRawPointer(bitPattern: blkDataBase + OFF_BOUNCE)!
    var done: UInt32 = 0
    while done < len {
        let pos = byteOff + UInt64(done)
        let sec = pos / UInt64(SECTOR_SIZE)
        let within = UInt32(pos % UInt64(SECTOR_SIZE))
        var chunk = UInt32(SECTOR_SIZE) - within
        if chunk > len - done { chunk = len - done }

        if within != 0 || chunk != UInt32(SECTOR_SIZE) {
            let readRc = blkDoRead(sec)
            if readRc != 0 { return readRc }
        } else {
            var z = 0
            while z < SECTOR_SIZE {
                bounce.storeBytes(of: UInt8(0), toByteOffset: z, as: UInt8.self)
                z += 1
            }
        }

        var i: UInt32 = 0
        while i < chunk {
            bounce.storeBytes(of: input.load(fromByteOffset: Int(done + i), as: UInt8.self),
                              toByteOffset: Int(within + i), as: UInt8.self)
            i += 1
        }

        let writeRc = blkDoWriteBounce(sec)
        if writeRc != 0 { return writeRc }
        done += chunk
    }
    return 0
}

func virtioBlkWritePackageStoreRange(_ byteOff: UInt64, _ buf: UnsafeRawPointer?, _ len: UInt32) -> Int32 {
    if pkgStoreDevice < 0 { return -1 }
    if byteOff + UInt64(len) > virtioBlkPackageStoreCapacityBytes() { return -2 }
    return virtioBlkWriteRangeToDevice(pkgStoreDevice, byteOff, buf, len)
}
