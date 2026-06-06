// virtio_net.swift — minimal polled virtio 1.0 (modern, MMIO) network driver.
//
// net-a: gives the kernel raw Ethernet frame TX/RX so the sans-IO protocol core
// (kernel/net/*.swift) can answer ARP and ping the QEMU user-net gateway. It is
// the network counterpart of virtio_blk.c, but written in Swift (the project's
// default; uart.swift is the precedent for Swift MMIO) and with TWO virtqueues
// plus a buffer pool instead of one synchronous request queue.
//
// Zero-copy data path: RX buffers are PMM pages the device DMAs into, and the
// sans-IO core reads the Ethernet frame straight out of the RX buffer (no bounce
// copy in). Replies are written directly into the TX DMA buffer and handed to
// the transmit ring by address (no copy out). Only the virtio_net_hdr is added.
//
// The driver runs after the MMU and heap are up, with IRQs masked: it polls the
// used rings, exactly like virtio_blk.c and the virtio-input keyboard. MMIO and
// cache maintenance go through the io.h C bridge; everything else is Swift.

// virtio-mmio register offsets (same layout as virtio_blk.c).
private let R_MAGIC: UInt      = 0x000
private let R_VERSION: UInt    = 0x004
private let R_DEVID: UInt      = 0x008
private let R_DEVFEAT: UInt    = 0x010
private let R_DEVFEATSEL: UInt = 0x014
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
private let VIRTIO_ID_NET: UInt32 = 1

private let S_ACK: UInt32    = 1
private let S_DRV: UInt32    = 2
private let S_DRVOK: UInt32  = 4
private let S_FEATOK: UInt32 = 8

private let F_VERSION_1_HI_BIT: UInt32 = 1        // feature bit 32 → DEVFEATSEL 1, bit 0
private let NET_F_MAC_LO_BIT: UInt32 = 1 << 5     // feature bit 5 → DEVFEATSEL 0, bit 5

private let VIRTQ_DESC_F_NEXT: UInt16  = 1
private let VIRTQ_DESC_F_WRITE: UInt16 = 2

private let NET_QSZ = 8
private let NET_BUFSZ = 2048
private let VIRTIO_NET_HDR_LEN = 12               // virtio 1.0 header (incl. num_buffers)

// Ring-page layout: descriptor table, available ring, and used ring carved out
// of one 4 KiB page at fixed, naturally-aligned offsets.
private let OFF_DESC: UInt  = 0x000
private let OFF_AVAIL: UInt = 0x080
private let OFF_USED: UInt  = 0x100

private struct NetQueue {
    var ringBase: UInt = 0   // PA of the page holding desc/avail/used
    var bufBase: UInt = 0    // PA of this queue's buffer pool
    var qnum: UInt32 = 0
    var availIdx: UInt16 = 0
    var lastUsed: UInt16 = 0
}

private var netMmio: UInt = 0
private var netMac = MAC()
private var rxq = NetQueue()
private var txq = NetQueue()

// --- cache maintenance ------------------------------------------------------
private func netClean(_ pa: UInt, _ n: Int) {
    var a = pa & ~UInt(63)
    let end = pa + UInt(n)
    while a < end { dc_cvac(a); a += 64 }
    dsb_sy()
}
private func netInvalidate(_ pa: UInt, _ n: Int) {
    dsb_sy()
    var a = pa & ~UInt(63)
    let end = pa + UInt(n)
    while a < end { dc_ivac(a); a += 64 }
    dsb_sy()
}
private func zeroPage(_ pa: UInt) {
    let p = UnsafeMutableRawPointer(bitPattern: pa)!
    var i = 0
    while i < 4096 { p.storeBytes(of: UInt8(0), toByteOffset: i, as: UInt8.self); i += 1 }
}

// --- virtqueue accessors (little-endian native, aligned by layout) ----------
private func descSet(_ q: NetQueue, _ i: Int, addr: UInt64, len: UInt32,
                     flags: UInt16, next: UInt16) {
    let d = UnsafeMutableRawPointer(bitPattern: q.ringBase + OFF_DESC + UInt(i * 16))!
    d.storeBytes(of: addr, toByteOffset: 0, as: UInt64.self)
    d.storeBytes(of: len, toByteOffset: 8, as: UInt32.self)
    d.storeBytes(of: flags, toByteOffset: 12, as: UInt16.self)
    d.storeBytes(of: next, toByteOffset: 14, as: UInt16.self)
}

private func availAdd(_ q: inout NetQueue, descIdx: UInt16) {
    let avail = UnsafeMutableRawPointer(bitPattern: q.ringBase + OFF_AVAIL)!
    let slot = Int(q.availIdx % UInt16(q.qnum))
    avail.storeBytes(of: descIdx, toByteOffset: 4 + slot * 2, as: UInt16.self)  // ring[slot]
    q.availIdx &+= 1
    avail.storeBytes(of: q.availIdx, toByteOffset: 2, as: UInt16.self)          // avail.idx
}

private func usedIdx(_ q: NetQueue) -> UInt16 {
    let u = UnsafeRawPointer(bitPattern: q.ringBase + OFF_USED)!
    return u.load(fromByteOffset: 2, as: UInt16.self)
}
private func usedElem(_ q: NetQueue, _ slot: Int) -> (id: UInt32, len: UInt32) {
    let u = UnsafeRawPointer(bitPattern: q.ringBase + OFF_USED + 4 + UInt(slot * 8))!
    return (u.load(fromByteOffset: 0, as: UInt32.self), u.load(fromByteOffset: 4, as: UInt32.self))
}

private func cleanRing(_ q: NetQueue) {
    netClean(q.ringBase + OFF_DESC, NET_QSZ * 16)
    netClean(q.ringBase + OFF_AVAIL, 32)
}

// --- bring-up ---------------------------------------------------------------
private func setupQueue(_ m: UInt, _ idx: UInt32, _ q: inout NetQueue) -> Bool {
    mmio_write32(m + R_QSEL, idx)
    let maxq = mmio_read32(m + R_QNUMMAX)
    if maxq == 0 { return false }
    q.qnum = maxq < UInt32(NET_QSZ) ? maxq : UInt32(NET_QSZ)
    mmio_write32(m + R_QNUM, q.qnum)
    let d = UInt64(q.ringBase + OFF_DESC)
    let a = UInt64(q.ringBase + OFF_AVAIL)
    let u = UInt64(q.ringBase + OFF_USED)
    mmio_write32(m + R_QDESCL, UInt32(d & 0xFFFF_FFFF)); mmio_write32(m + R_QDESCH, UInt32(d >> 32))
    mmio_write32(m + R_QDRVL,  UInt32(a & 0xFFFF_FFFF)); mmio_write32(m + R_QDRVH,  UInt32(a >> 32))
    mmio_write32(m + R_QDEVL,  UInt32(u & 0xFFFF_FFFF)); mmio_write32(m + R_QDEVH,  UInt32(u >> 32))
    mmio_write32(m + R_QREADY, 1)
    return true
}

private func bringUp(_ m: UInt) -> Bool {
    netMmio = m
    mmio_write32(m + R_STATUS, 0)               // reset
    mmio_write32(m + R_STATUS, S_ACK)
    mmio_write32(m + R_STATUS, S_ACK | S_DRV)

    mmio_write32(m + R_DEVFEATSEL, 0); let devLo = mmio_read32(m + R_DEVFEAT)
    mmio_write32(m + R_DEVFEATSEL, 1); let devHi = mmio_read32(m + R_DEVFEAT)
    if (devHi & F_VERSION_1_HI_BIT) == 0 { netMmio = 0; return false }   // modern required
    let haveMac = (devLo & NET_F_MAC_LO_BIT) != 0
    mmio_write32(m + R_DRVFEATSEL, 1); mmio_write32(m + R_DRVFEAT, F_VERSION_1_HI_BIT)
    mmio_write32(m + R_DRVFEATSEL, 0); mmio_write32(m + R_DRVFEAT, haveMac ? NET_F_MAC_LO_BIT : 0)
    mmio_write32(m + R_STATUS, S_ACK | S_DRV | S_FEATOK)
    if (mmio_read32(m + R_STATUS) & S_FEATOK) == 0 { netMmio = 0; return false }

    let rxRing = pmm_alloc_page()
    let txRing = pmm_alloc_page()
    let rxBufs = pmm_alloc_pages(Int((NET_QSZ * NET_BUFSZ + 4095) / 4096))
    let txBuf  = pmm_alloc_page()
    if rxRing == 0 || txRing == 0 || rxBufs == 0 || txBuf == 0 { netMmio = 0; return false }
    zeroPage(rxRing); zeroPage(txRing)
    rxq = NetQueue(); rxq.ringBase = rxRing; rxq.bufBase = rxBufs
    txq = NetQueue(); txq.ringBase = txRing; txq.bufBase = txBuf

    if !setupQueue(m, 0, &rxq) { netMmio = 0; return false }   // receiveq
    if !setupQueue(m, 1, &txq) { netMmio = 0; return false }   // transmitq

    if haveMac {
        let lo = mmio_read32(m + R_CONFIG + 0)
        let hi = mmio_read32(m + R_CONFIG + 4)
        netMac = MAC(UInt8(lo & 0xFF), UInt8((lo >> 8) & 0xFF),
                     UInt8((lo >> 16) & 0xFF), UInt8((lo >> 24) & 0xFF),
                     UInt8(hi & 0xFF), UInt8((hi >> 8) & 0xFF))
    } else {
        netMac = MAC(0x52, 0x54, 0x00, 0x12, 0x34, 0x56)   // QEMU's default
    }

    mmio_write32(m + R_STATUS, S_ACK | S_DRV | S_FEATOK | S_DRVOK)

    // Pre-fill the RX ring: descriptor i → RX buffer i, device-writable.
    var k = 0
    while k < Int(rxq.qnum) {
        let buf = rxq.bufBase + UInt(k * NET_BUFSZ)
        descSet(rxq, k, addr: UInt64(buf), len: UInt32(NET_BUFSZ),
                flags: VIRTQ_DESC_F_WRITE, next: 0)
        k += 1
    }
    netClean(rxq.ringBase + OFF_DESC, NET_QSZ * 16)
    k = 0
    while k < Int(rxq.qnum) { availAdd(&rxq, descIdx: UInt16(k)); k += 1 }
    netClean(rxq.ringBase + OFF_AVAIL, 32)
    mmio_write32(m + R_QNOTIFY, 0)              // kick the receive queue
    return true
}

/// Scan the HAL virtio-mmio window for a modern virtio-net device (id 1) and
/// bring it up. Returns true if a NIC is ready.
func virtioNetInit() -> Bool {
    netMmio = 0
    let base = platform.virtioMmioBase
    let stride = platform.virtioMmioStride
    let count = platform.virtioMmioCount
    var i: UInt32 = 0
    while i < count {
        let m = base + UInt(i) * stride
        i += 1
        if mmio_read32(m + R_MAGIC) != VIRTIO_MAGIC { continue }
        if mmio_read32(m + R_VERSION) != 2 { continue }       // modern only
        if mmio_read32(m + R_DEVID) != VIRTIO_ID_NET { continue }
        if bringUp(m) { return true }
    }
    netMmio = 0
    return false
}

func virtioNetAvailable() -> Bool { netMmio != 0 }
func virtioNetMac() -> MAC { netMac }

/// The frame area of the single TX buffer — the sans-IO core writes a frame to
/// transmit here (zero-copy), then `virtioNetTxSubmit` sends it.
func virtioNetTxBuffer() -> UnsafeMutableRawPointer {
    UnsafeMutableRawPointer(bitPattern: txq.bufBase + UInt(VIRTIO_NET_HDR_LEN))!
}

/// Transmit the `frameLen` bytes currently in the TX buffer. Prepends a zeroed
/// virtio_net_hdr and blocks on the transmit used ring (synchronous, one frame
/// at a time — fine for net-a's request/reply probe).
func virtioNetTxSubmit(frameLen: Int) {
    guard netMmio != 0, frameLen > 0 else { return }
    let hdr = UnsafeMutableRawPointer(bitPattern: txq.bufBase)!
    var z = 0
    while z < VIRTIO_NET_HDR_LEN { hdr.storeBytes(of: UInt8(0), toByteOffset: z, as: UInt8.self); z += 1 }
    let total = VIRTIO_NET_HDR_LEN + frameLen
    netClean(txq.bufBase, total)
    descSet(txq, 0, addr: UInt64(txq.bufBase), len: UInt32(total), flags: 0, next: 0)
    cleanRing(txq)
    availAdd(&txq, descIdx: 0)
    netClean(txq.ringBase + OFF_AVAIL, 32)

    let target = txq.lastUsed &+ 1
    mmio_write32(netMmio + R_QNOTIFY, 1)
    var spins = 0
    while spins < 5_000_000 {
        netInvalidate(txq.ringBase + OFF_USED, 72)
        if usedIdx(txq) == target { break }
        spins += 1
    }
    txq.lastUsed = target
    let ist = mmio_read32(netMmio + R_ISTATUS)
    if ist != 0 { mmio_write32(netMmio + R_IACK, ist) }
}

/// Drain every RX frame the device has completed, feeding each through `stack`.
/// Any reply the stack produces is transmitted. Returns the OR of the per-frame
/// outcomes (e.g. ARP resolution, echo reply) seen this call.
func virtioNetPoll(_ stack: inout NetStack) -> RxOutcome {
    var agg = RxOutcome()
    guard netMmio != 0 else { return agg }
    netInvalidate(rxq.ringBase + OFF_USED, 72)
    var cur = usedIdx(rxq)
    while rxq.lastUsed != cur {
        let slot = Int(rxq.lastUsed % UInt16(rxq.qnum))
        let (id, ulen) = usedElem(rxq, slot)
        rxq.lastUsed &+= 1
        if Int(id) < Int(rxq.qnum) && ulen >= UInt32(VIRTIO_NET_HDR_LEN) {
            let buf = rxq.bufBase + UInt(Int(id) * NET_BUFSZ)
            netInvalidate(buf, Int(ulen))
            let frame = UnsafeRawPointer(bitPattern: buf + UInt(VIRTIO_NET_HDR_LEN))!
            let frameLen = Int(ulen) - VIRTIO_NET_HDR_LEN
            let r = stack.onFrame(frame, frameLen,
                                  out: virtioNetTxBuffer(),
                                  outCap: NET_BUFSZ - VIRTIO_NET_HDR_LEN)
            if r.arpResolved {
                agg.arpResolved = true; agg.resolvedIP = r.resolvedIP; agg.resolvedMac = r.resolvedMac
            }
            if r.echoReply { agg.echoReply = true; agg.echoSeq = r.echoSeq }
            if r.gotUDP {
                socketDeliverUDP(srcIP: r.udpSrcIP, srcPort: r.udpSrcPort, dstPort: r.udpDstPort,
                                 payload: frame + r.udpPayloadOff, len: r.udpPayloadLen)
            }
            if r.gotTCP {
                socketDeliverTCP(srcIP: r.tcpSrcIP, srcMac: r.tcpSrcMac, srcPort: r.tcpSrcPort,
                                 dstPort: r.tcpDstPort, flags: r.tcpFlags, seq: r.tcpSeqNum,
                                 ack: r.tcpAckNum, window: r.tcpWnd, payload: frame + r.tcpPayloadOff,
                                 payloadLen: r.tcpPayloadLen, now: systemTicks)
            }
            if r.txLen > 0 { virtioNetTxSubmit(frameLen: r.txLen) }

            // Recycle the RX descriptor back onto the available ring.
            descSet(rxq, Int(id), addr: UInt64(buf), len: UInt32(NET_BUFSZ),
                    flags: VIRTQ_DESC_F_WRITE, next: 0)
            netClean(rxq.ringBase + OFF_DESC, NET_QSZ * 16)
            availAdd(&rxq, descIdx: UInt16(id))
            netClean(rxq.ringBase + OFF_AVAIL, 32)
            mmio_write32(netMmio + R_QNOTIFY, 0)
        }
        netInvalidate(rxq.ringBase + OFF_USED, 72)
        cur = usedIdx(rxq)
    }
    let ist = mmio_read32(netMmio + R_ISTATUS)
    if ist != 0 { mmio_write32(netMmio + R_IACK, ist) }
    return agg
}
