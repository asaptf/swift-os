// SPDX-License-Identifier: Apache-2.0
// virtio_net_user.swift — userland virtio-net driver core, shared by the NS2 probe
// (/bin/netdriverprobe) and the NS3 restartable net service (/bin/netsvc). It brings
// up the RX (queue 0) and TX (queue 1) virtqueues entirely from EL0 over a mapped
// MMIO window, resolving every ring/buffer physical address via SYS_virt_to_phys (so
// no allocation need be physically contiguous — each 2048-byte buffer fits in a
// page). MMIO/ring access goes through the volatile swiftos_mmio_* / swiftos_dmb
// bridges. Plain frames (Ethernet, no virtio_net_hdr) cross the vnetTx/vnetRxNext
// boundary; the 12-byte virtio_net_hdr is handled internally.
//
// Caveat (same as the input driver): ring/buffer visibility relies on TCG cache
// coherence; real-HW cache maintenance for userland DMA is a later hardening step.

// virtio-mmio registers + status.
let vnR_MAGIC: UInt = 0x00, vnR_DEVID: UInt = 0x08
let vnR_DEVFEAT: UInt = 0x10, vnR_DEVFEATSEL: UInt = 0x14
let vnR_DRVFEAT: UInt = 0x20, vnR_DRVFEATSEL: UInt = 0x24
let vnR_QSEL: UInt = 0x30, vnR_QNUMMAX: UInt = 0x34, vnR_QNUM: UInt = 0x38
let vnR_QREADY: UInt = 0x44, vnR_QNOTIFY: UInt = 0x50, vnR_STATUS: UInt = 0x70
let vnR_QDESCL: UInt = 0x80, vnR_QDESCH: UInt = 0x84
let vnR_QDRVL: UInt = 0x90, vnR_QDRVH: UInt = 0x94
let vnR_QDEVL: UInt = 0xa0, vnR_QDEVH: UInt = 0xa4
let vnR_CONFIG: UInt = 0x100
let vnMagic: UInt32 = 0x74726976, vnDevIdNet: UInt32 = 1
let vnS_ACK: UInt32 = 1, vnS_DRV: UInt32 = 2, vnS_DRVOK: UInt32 = 4, vnS_FEATOK: UInt32 = 8

let vnQSZ = 8
let vnBUFSZ: UInt = 2048
let vnHDR = 12               // virtio_net_hdr length (virtio 1.0)
let vnOFF_DESC: UInt = 0x000, vnOFF_AVAIL: UInt = 0x200, vnOFF_USED: UInt = 0x400
let vnDESC_F_WRITE: UInt16 = 2
let vnFrameMax = Int(vnBUFSZ) - vnHDR

struct VnetQueue {
    var ringVA: UInt = 0, ringPA: UInt = 0
    var qn: UInt32 = 0
    var availIdx: UInt16 = 0
    var lastUsed: UInt16 = 0
}

// A fully-initialized userland virtio-net driver bound to one device.
struct VnetDriver {
    var mmio: UInt = 0
    var fd: Int32 = -1
    var rxq = VnetQueue()
    var txq = VnetQueue()
    var rxBufVA: UInt = 0
    var txBufVA: UInt = 0
    var mac = [UInt8](repeating: 0, count: 6)
    var ok = false
}

private func vnSetupQueue(_ mmio: UInt, _ fd: Int32, _ q: UInt32, _ out: inout VnetQueue) -> Bool {
    swiftos_mmio_write32(mmio + vnR_QSEL, q)
    let maxq = swiftos_mmio_read32(mmio + vnR_QNUMMAX)
    if maxq == 0 { return false }
    out.qn = maxq < UInt32(vnQSZ) ? maxq : UInt32(vnQSZ)
    swiftos_mmio_write32(mmio + vnR_QNUM, out.qn)
    let ringVA = swiftos_mmap(4096, Int32(SWIFTOS_PROT_READ | SWIFTOS_PROT_WRITE))
    if ringVA == 0 { return false }
    let pa = swiftos_virt_to_phys(ringVA, fd)
    if pa < 0 { return false }
    out.ringVA = ringVA
    out.ringPA = UInt(bitPattern: Int(pa))
    let d = out.ringPA + vnOFF_DESC, a = out.ringPA + vnOFF_AVAIL, u = out.ringPA + vnOFF_USED
    swiftos_mmio_write32(mmio + vnR_QDESCL, UInt32(d & 0xFFFF_FFFF)); swiftos_mmio_write32(mmio + vnR_QDESCH, UInt32(d >> 32))
    swiftos_mmio_write32(mmio + vnR_QDRVL, UInt32(a & 0xFFFF_FFFF)); swiftos_mmio_write32(mmio + vnR_QDRVH, UInt32(a >> 32))
    swiftos_mmio_write32(mmio + vnR_QDEVL, UInt32(u & 0xFFFF_FFFF)); swiftos_mmio_write32(mmio + vnR_QDEVH, UInt32(u >> 32))
    swiftos_mmio_write32(mmio + vnR_QREADY, 1)
    return true
}

private func vnDesc(_ q: VnetQueue, _ i: Int, _ pa: UInt, _ len: UInt32, _ flags: UInt16) {
    let base = q.ringVA + vnOFF_DESC + UInt(i * 16)
    swiftos_mmio_write64(base + 0, pa)
    swiftos_mmio_write32(base + 8, len)
    swiftos_mmio_write16(base + 12, flags)
    swiftos_mmio_write16(base + 14, 0)
}

// Bring the device up over its mapped MMIO window `mmio` (the grant fd resolves
// physical addresses). Returns a driver with ok == true on success.
func vnetInit(_ mmio: UInt, _ fd: Int32) -> VnetDriver {
    var d = VnetDriver()
    d.mmio = mmio; d.fd = fd
    if swiftos_mmio_read32(mmio + vnR_MAGIC) != vnMagic ||
       swiftos_mmio_read32(mmio + vnR_DEVID) != vnDevIdNet { return d }

    swiftos_mmio_write32(mmio + vnR_STATUS, 0)
    swiftos_mmio_write32(mmio + vnR_STATUS, vnS_ACK)
    swiftos_mmio_write32(mmio + vnR_STATUS, vnS_ACK | vnS_DRV)
    swiftos_mmio_write32(mmio + vnR_DEVFEATSEL, 0)
    let feat0 = swiftos_mmio_read32(mmio + vnR_DEVFEAT)
    let haveMac = (feat0 & (UInt32(1) << 5)) != 0
    swiftos_mmio_write32(mmio + vnR_DRVFEATSEL, 1); swiftos_mmio_write32(mmio + vnR_DRVFEAT, 1) // VERSION_1
    swiftos_mmio_write32(mmio + vnR_DRVFEATSEL, 0); swiftos_mmio_write32(mmio + vnR_DRVFEAT, haveMac ? (UInt32(1) << 5) : 0)
    swiftos_mmio_write32(mmio + vnR_STATUS, vnS_ACK | vnS_DRV | vnS_FEATOK)
    if (swiftos_mmio_read32(mmio + vnR_STATUS) & vnS_FEATOK) == 0 { return d }

    if haveMac {
        let lo = swiftos_mmio_read32(mmio + vnR_CONFIG + 0), hi = swiftos_mmio_read32(mmio + vnR_CONFIG + 4)
        d.mac[0] = UInt8(lo & 0xff); d.mac[1] = UInt8((lo >> 8) & 0xff)
        d.mac[2] = UInt8((lo >> 16) & 0xff); d.mac[3] = UInt8((lo >> 24) & 0xff)
        d.mac[4] = UInt8(hi & 0xff); d.mac[5] = UInt8((hi >> 8) & 0xff)
    } else {
        d.mac = [0x52, 0x54, 0x00, 0x12, 0x34, 0x56]
    }

    if !vnSetupQueue(mmio, fd, 0, &d.rxq) || !vnSetupQueue(mmio, fd, 1, &d.txq) { return d }
    let rxPages = UInt((vnQSZ * Int(vnBUFSZ) + 4095) / 4096)
    d.rxBufVA = swiftos_mmap(rxPages * 4096, Int32(SWIFTOS_PROT_READ | SWIFTOS_PROT_WRITE))
    d.txBufVA = swiftos_mmap(4096, Int32(SWIFTOS_PROT_READ | SWIFTOS_PROT_WRITE))
    if d.rxBufVA == 0 || d.txBufVA == 0 { return d }

    var i = 0
    while i < Int(d.rxq.qn) {
        let bpa = swiftos_virt_to_phys(d.rxBufVA + UInt(i) * vnBUFSZ, fd)
        if bpa < 0 { return d }
        vnDesc(d.rxq, i, UInt(bitPattern: Int(bpa)), UInt32(vnBUFSZ), vnDESC_F_WRITE)
        swiftos_mmio_write16(d.rxq.ringVA + vnOFF_AVAIL + 4 + UInt(i * 2), UInt16(i))
        i += 1
    }
    d.rxq.availIdx = UInt16(d.rxq.qn)
    swiftos_mmio_write16(d.rxq.ringVA + vnOFF_AVAIL + 2, d.rxq.availIdx)
    swiftos_dmb()
    swiftos_mmio_write32(mmio + vnR_STATUS, vnS_ACK | vnS_DRV | vnS_FEATOK | vnS_DRVOK)
    swiftos_mmio_write32(mmio + vnR_QNOTIFY, 0) // kick RX
    d.ok = true
    return d
}

// Transmit one Ethernet frame (`len` bytes at `frame`). Prepends a zeroed
// virtio_net_hdr in the TX buffer, submits descriptor 0, and kicks the TX queue.
func vnetTx(_ d: inout VnetDriver, _ frame: UInt, _ len: Int) {
    if len <= 0 || len > vnFrameMax { return }
    var k = 0
    while k < vnHDR { UnsafeMutableRawPointer(bitPattern: d.txBufVA + UInt(k))!.storeBytes(of: UInt8(0), as: UInt8.self); k += 1 }
    k = 0
    while k < len {
        let b = UnsafeRawPointer(bitPattern: frame + UInt(k))!.load(as: UInt8.self)
        UnsafeMutableRawPointer(bitPattern: d.txBufVA + UInt(vnHDR + k))!.storeBytes(of: b, as: UInt8.self)
        k += 1
    }
    let txPA = swiftos_virt_to_phys(d.txBufVA, d.fd)
    if txPA < 0 { return }
    vnDesc(d.txq, 0, UInt(bitPattern: Int(txPA)), UInt32(vnHDR + len), 0) // device reads
    swiftos_mmio_write16(d.txq.ringVA + vnOFF_AVAIL + 4, 0)
    d.txq.availIdx &+= 1
    swiftos_mmio_write16(d.txq.ringVA + vnOFF_AVAIL + 2, d.txq.availIdx)
    swiftos_dmb()
    swiftos_mmio_write32(d.mmio + vnR_QNOTIFY, 1)
}

// Pull the next received Ethernet frame (virtio_net_hdr stripped) into `out`
// (capacity `cap`), refill its RX descriptor, and re-kick RX. Returns the frame
// length copied, or 0 if nothing is pending / it does not fit.
func vnetRxNext(_ d: inout VnetDriver, _ out: UInt, _ cap: Int) -> Int {
    swiftos_dmb()
    let uidx = swiftos_mmio_read16(d.rxq.ringVA + vnOFF_USED + 2)
    if d.rxq.lastUsed == uidx { return 0 }
    let slot = Int(d.rxq.lastUsed % UInt16(d.rxq.qn))
    let id = swiftos_mmio_read32(d.rxq.ringVA + vnOFF_USED + 4 + UInt(slot * 8)) % d.rxq.qn
    let usedLen = swiftos_mmio_read32(d.rxq.ringVA + vnOFF_USED + 8 + UInt(slot * 8))
    let pkt = d.rxBufVA + UInt(id) * vnBUFSZ + UInt(vnHDR)
    var n = Int(usedLen) - vnHDR
    if n < 0 { n = 0 }
    if n > cap { n = cap }
    var k = 0
    while k < n {
        let b = UnsafeRawPointer(bitPattern: pkt + UInt(k))!.load(as: UInt8.self)
        UnsafeMutableRawPointer(bitPattern: out + UInt(k))!.storeBytes(of: b, as: UInt8.self)
        k += 1
    }
    // Refill this buffer back into the available ring.
    let bpa = swiftos_virt_to_phys(d.rxBufVA + UInt(id) * vnBUFSZ, d.fd)
    if bpa >= 0 { vnDesc(d.rxq, Int(id), UInt(bitPattern: Int(bpa)), UInt32(vnBUFSZ), vnDESC_F_WRITE) }
    swiftos_mmio_write16(d.rxq.ringVA + vnOFF_AVAIL + 4 + UInt((Int(d.rxq.availIdx) % Int(d.rxq.qn)) * 2), UInt16(id))
    d.rxq.availIdx &+= 1
    swiftos_mmio_write16(d.rxq.ringVA + vnOFF_AVAIL + 2, d.rxq.availIdx)
    d.rxq.lastUsed &+= 1
    swiftos_dmb()
    swiftos_mmio_write32(d.mmio + vnR_QNOTIFY, 0)
    return n
}

// ---- ARP helpers (shared by the NS2 probe and the NS3 demo client) ---------
// Big-endian frame helpers into normal RAM.
func vnW16(_ p: UInt, _ off: Int, _ v: UInt16) {
    let q = UnsafeMutableRawPointer(bitPattern: p + UInt(off))!
    q.storeBytes(of: UInt8(v >> 8), as: UInt8.self); (q + 1).storeBytes(of: UInt8(v & 0xff), as: UInt8.self)
}
func vnW32(_ p: UInt, _ off: Int, _ v: UInt32) {
    let q = UnsafeMutableRawPointer(bitPattern: p + UInt(off))!
    q.storeBytes(of: UInt8((v >> 24) & 0xff), as: UInt8.self); (q + 1).storeBytes(of: UInt8((v >> 16) & 0xff), as: UInt8.self)
    (q + 2).storeBytes(of: UInt8((v >> 8) & 0xff), as: UInt8.self); (q + 3).storeBytes(of: UInt8(v & 0xff), as: UInt8.self)
}
func vnB8(_ p: UInt, _ off: Int) -> UInt8 { UnsafeRawPointer(bitPattern: p + UInt(off))!.load(as: UInt8.self) }
func vnR16(_ p: UInt, _ off: Int) -> UInt16 { (UInt16(vnB8(p, off)) << 8) | UInt16(vnB8(p, off + 1)) }
func vnR32(_ p: UInt, _ off: Int) -> UInt32 {
    (UInt32(vnB8(p, off)) << 24) | (UInt32(vnB8(p, off + 1)) << 16) | (UInt32(vnB8(p, off + 2)) << 8) | UInt32(vnB8(p, off + 3))
}
func vnHex2(_ b: UInt8) {
    let hi = b >> 4, lo = b & 0xf
    swiftos_putc(hi < 10 ? UInt8(ascii: "0") + hi : UInt8(ascii: "a") + (hi - 10))
    swiftos_putc(lo < 10 ? UInt8(ascii: "0") + lo : UInt8(ascii: "a") + (lo - 10))
}

let vnArpMyIP: UInt32 = 0x0a00020f   // 10.0.2.15 (slirp guest)
let vnArpGwIP: UInt32 = 0x0a000202   // 10.0.2.2  (slirp gateway)

// Build an ARP request for the slirp gateway into `out` (42 bytes). Returns length.
func vnBuildArpRequest(_ out: UInt, _ mac: [UInt8]) -> Int {
    for k in 0..<6 { UnsafeMutableRawPointer(bitPattern: out + UInt(k))!.storeBytes(of: UInt8(0xff), as: UInt8.self) }
    for k in 0..<6 { UnsafeMutableRawPointer(bitPattern: out + 6 + UInt(k))!.storeBytes(of: mac[k], as: UInt8.self) }
    vnW16(out, 12, 0x0806)
    vnW16(out, 14, 1); vnW16(out, 16, 0x0800)
    UnsafeMutableRawPointer(bitPattern: out + 18)!.storeBytes(of: UInt8(6), as: UInt8.self)
    UnsafeMutableRawPointer(bitPattern: out + 19)!.storeBytes(of: UInt8(4), as: UInt8.self)
    vnW16(out, 20, 1)
    for k in 0..<6 { UnsafeMutableRawPointer(bitPattern: out + 22 + UInt(k))!.storeBytes(of: mac[k], as: UInt8.self) }
    vnW32(out, 28, vnArpMyIP)
    for k in 0..<6 { UnsafeMutableRawPointer(bitPattern: out + 32 + UInt(k))!.storeBytes(of: UInt8(0), as: UInt8.self) }
    vnW32(out, 38, vnArpGwIP)
    return 42
}

// True if `pkt` (len bytes) is an ARP reply from the slirp gateway (10.0.2.2).
func vnIsGatewayArpReply(_ pkt: UInt, _ len: Int) -> Bool {
    return len >= 42 && vnR16(pkt, 12) == 0x0806 && vnR16(pkt, 20) == 2 && vnR32(pkt, 28) == vnArpGwIP
}
