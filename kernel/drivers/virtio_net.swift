// SPDX-License-Identifier: Apache-2.0
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

private let NET_QSZ = 16
private let NET_BUFSZ = 2048
private let VIRTIO_NET_HDR_LEN = 12               // virtio 1.0 header (incl. num_buffers)

// Ring-page layout: descriptor table, available ring, and used ring carved out
// of one 4 KiB page at fixed, naturally-aligned offsets.
private let OFF_DESC: UInt  = 0x000
private let OFF_AVAIL: UInt = 0x200
private let OFF_USED: UInt  = 0x400

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
private var txStaged = -1
private var txInFlight = 0

// RX state: false in rxInDevice means the descriptor is currently owned by the
// driver/socket layer; rxHeld means a socket queued it by reference and will
// release it after recvfrom consumes the datagram.
private var rxInDevice = [Bool](repeating: false, count: NET_QSZ)
private var rxHeld = [Bool](repeating: false, count: NET_QSZ)

// TX state: 0 free, 1 reserved by virtioNetTxBuffer(), 2 submitted to device.
private var txState = [UInt8](repeating: 0, count: NET_QSZ)

private var netRxBatchMax = 0
private var netTxDrainBatchMax = 0
private var netRxRefDeliveredTotal: UInt64 = 0
private var netRxHeldTotal: UInt64 = 0
private var netTxSubmittedTotal: UInt64 = 0
private var netTxCompletedTotal: UInt64 = 0
private var netZeroCopyReported: UInt64 = 0

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

private func descBytes(_ q: NetQueue) -> Int { Int(q.qnum) * 16 }
private func availBytes(_ q: NetQueue) -> Int { 4 + Int(q.qnum) * 2 + 2 }
private func usedBytes(_ q: NetQueue) -> Int { 4 + Int(q.qnum) * 8 }

private func cleanRing(_ q: NetQueue) {
    netClean(q.ringBase + OFF_DESC, descBytes(q))
    netClean(q.ringBase + OFF_AVAIL, availBytes(q))
}

private func invalidateUsedRing(_ q: NetQueue) {
    netInvalidate(q.ringBase + OFF_USED, usedBytes(q))
}

private func txBufferPA(_ i: Int) -> UInt {
    txq.bufBase + UInt(i * NET_BUFSZ)
}

private func rxBufferPA(_ i: Int) -> UInt {
    rxq.bufBase + UInt(i * NET_BUFSZ)
}

private func recycleRxDescriptor(_ id: Int) {
    if id < 0 || id >= Int(rxq.qnum) || rxInDevice[id] || rxHeld[id] { return }
    let buf = rxBufferPA(id)
    descSet(rxq, id, addr: UInt64(buf), len: UInt32(NET_BUFSZ),
            flags: VIRTQ_DESC_F_WRITE, next: 0)
    availAdd(&rxq, descIdx: UInt16(id))
    rxInDevice[id] = true
}

func virtioNetRetainRxBuffer(_ id: Int) -> Bool {
    if netMmio == 0 || id < 0 || id >= Int(rxq.qnum) || rxInDevice[id] || rxHeld[id] {
        return false
    }
    rxHeld[id] = true
    netRxHeldTotal += 1
    return true
}

func virtioNetReleaseRxBuffer(_ id: Int) {
    if netMmio == 0 || id < 0 || id >= Int(rxq.qnum) || !rxHeld[id] { return }
    rxHeld[id] = false
    recycleRxDescriptor(id)
    cleanRing(rxq)
    mmio_write32(netMmio + R_QNOTIFY, 0)
}

func virtioNetRxFramePointer(ref id: Int, offset: Int) -> UnsafeRawPointer {
    UnsafeRawPointer(bitPattern: rxBufferPA(id) + UInt(VIRTIO_NET_HDR_LEN + offset))!
}

@discardableResult
func virtioNetTxDrain() -> Int {
    guard netMmio != 0 else { return 0 }
    invalidateUsedRing(txq)
    let cur = usedIdx(txq)
    var done = 0
    while txq.lastUsed != cur {
        let slot = Int(txq.lastUsed % UInt16(txq.qnum))
        let (id, _) = usedElem(txq, slot)
        txq.lastUsed &+= 1
        let idx = Int(id)
        if idx >= 0 && idx < Int(txq.qnum) && txState[idx] == 2 {
            txState[idx] = 0
            if txInFlight > 0 { txInFlight -= 1 }
            done += 1
        }
    }
    if done > netTxDrainBatchMax { netTxDrainBatchMax = done }
    netTxCompletedTotal += UInt64(done)
    let ist = mmio_read32(netMmio + R_ISTATUS)
    if ist != 0 { mmio_write32(netMmio + R_IACK, ist) }
    return done
}

private func reserveTxIndex() -> Int {
    _ = virtioNetTxDrain()
    var i = 0
    while i < Int(txq.qnum) {
        if txState[i] == 0 {
            txState[i] = 1
            return i
        }
        i += 1
    }

    while true {
        if virtioNetTxDrain() > 0 {
            i = 0
            while i < Int(txq.qnum) {
                if txState[i] == 0 {
                    txState[i] = 1
                    return i
                }
                i += 1
            }
        }
    }
}

func virtioNetMaybeReportZeroCopy() {
    if netZeroCopyReported != 0 || netMmio == 0 { return }
    if netRxRefDeliveredTotal < 16 || netTxSubmittedTotal < 16 { return }
    if netRxBatchMax < 2 && netTxDrainBatchMax < 2 { return }
    netZeroCopyReported = 1
    uartPuts("net-zc OK: rx_batch=")
    uartPutUInt(UInt64(netRxBatchMax))
    uartPuts(" tx_batch=")
    uartPutUInt(UInt64(netTxDrainBatchMax))
    uartPuts(" rx_refs=")
    uartPutUInt(netRxRefDeliveredTotal)
    uartPuts(" rx_held=")
    uartPutUInt(netRxHeldTotal)
    uartPuts(" tx_submitted=")
    uartPutUInt(netTxSubmittedTotal)
    uartPuts(" tx_completed=")
    uartPutUInt(netTxCompletedTotal)
    uartPuts("\n")
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
    let txBufs = pmm_alloc_pages(Int((NET_QSZ * NET_BUFSZ + 4095) / 4096))
    if rxRing == 0 || txRing == 0 || rxBufs == 0 || txBufs == 0 { netMmio = 0; return false }
    zeroPage(rxRing); zeroPage(txRing)
    rxq = NetQueue(); rxq.ringBase = rxRing; rxq.bufBase = rxBufs
    txq = NetQueue(); txq.ringBase = txRing; txq.bufBase = txBufs
    txStaged = -1
    txInFlight = 0
    netRxBatchMax = 0
    netTxDrainBatchMax = 0
    netRxRefDeliveredTotal = 0
    netRxHeldTotal = 0
    netTxSubmittedTotal = 0
    netTxCompletedTotal = 0
    netZeroCopyReported = 0

    if !setupQueue(m, 0, &rxq) { netMmio = 0; return false }   // receiveq
    if !setupQueue(m, 1, &txq) { netMmio = 0; return false }   // transmitq

    var k = 0
    while k < NET_QSZ {
        rxInDevice[k] = false
        rxHeld[k] = false
        txState[k] = 0
        k += 1
    }

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
    k = 0
    while k < Int(rxq.qnum) {
        let buf = rxBufferPA(k)
        descSet(rxq, k, addr: UInt64(buf), len: UInt32(NET_BUFSZ),
                flags: VIRTQ_DESC_F_WRITE, next: 0)
        rxInDevice[k] = true
        k += 1
    }
    netClean(rxq.ringBase + OFF_DESC, descBytes(rxq))
    k = 0
    while k < Int(rxq.qnum) { availAdd(&rxq, descIdx: UInt16(k)); k += 1 }
    netClean(rxq.ringBase + OFF_AVAIL, availBytes(rxq))
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

/// The frame area of a reserved TX buffer — the sans-IO core writes a frame to
/// transmit here (zero-copy), then `virtioNetTxSubmit` sends it. Each call
/// reserves one buffer from the fixed TX pool; completion is drained in batches.
func virtioNetTxBuffer() -> UnsafeMutableRawPointer {
    if txStaged >= 0 {
        return UnsafeMutableRawPointer(bitPattern: txBufferPA(txStaged) + UInt(VIRTIO_NET_HDR_LEN))!
    }
    let idx = reserveTxIndex()
    if idx < 0 { return UnsafeMutableRawPointer(bitPattern: txBufferPA(0) + UInt(VIRTIO_NET_HDR_LEN))! }
    txStaged = idx
    return UnsafeMutableRawPointer(bitPattern: txBufferPA(idx) + UInt(VIRTIO_NET_HDR_LEN))!
}

/// Transmit the `frameLen` bytes currently in the TX buffer. Prepends a zeroed
/// virtio_net_hdr and queues the descriptor. Completion is intentionally not
/// waited for here; `virtioNetTxDrain` reclaims any completed descriptors in
/// bulk during the next pump/reservation.
func virtioNetTxSubmit(frameLen: Int) {
    guard netMmio != 0 else { return }
    let idx = txStaged
    if idx < 0 || idx >= Int(txq.qnum) { return }
    txStaged = -1
    if frameLen <= 0 || frameLen > NET_BUFSZ - VIRTIO_NET_HDR_LEN {
        txState[idx] = 0
        return
    }

    let buf = txBufferPA(idx)
    let hdr = UnsafeMutableRawPointer(bitPattern: buf)!
    var z = 0
    while z < VIRTIO_NET_HDR_LEN { hdr.storeBytes(of: UInt8(0), toByteOffset: z, as: UInt8.self); z += 1 }
    let total = VIRTIO_NET_HDR_LEN + frameLen
    netClean(buf, total)
    descSet(txq, idx, addr: UInt64(buf), len: UInt32(total), flags: 0, next: 0)
    netClean(txq.ringBase + OFF_DESC + UInt(idx * 16), 16)
    availAdd(&txq, descIdx: UInt16(idx))
    netClean(txq.ringBase + OFF_AVAIL, availBytes(txq))
    txState[idx] = 2
    txInFlight += 1
    netTxSubmittedTotal += 1
    mmio_write32(netMmio + R_QNOTIFY, 1)
}

/// Drain every RX frame the device has completed, feeding each through `stack`.
/// Any reply the stack produces is transmitted. Returns the OR of the per-frame
/// outcomes (e.g. ARP resolution, echo reply) seen this call.
func virtioNetPoll(_ stack: inout NetStack) -> RxOutcome {
    var agg = RxOutcome()
    guard netMmio != 0 else { return agg }
    _ = virtioNetTxDrain()
    invalidateUsedRing(rxq)
    let cur = usedIdx(rxq)
    var batch = 0
    var recycled = 0
    while rxq.lastUsed != cur {
        let slot = Int(rxq.lastUsed % UInt16(rxq.qnum))
        let (id, ulen) = usedElem(rxq, slot)
        rxq.lastUsed &+= 1
        batch += 1
        let rxid = Int(id)
        if rxid < Int(rxq.qnum) {
            rxInDevice[rxid] = false
            if ulen < UInt32(VIRTIO_NET_HDR_LEN) {
                recycleRxDescriptor(rxid)
                recycled += 1
                continue
            }
            let buf = rxBufferPA(rxid)
            netInvalidate(buf, Int(ulen))
            let frame = UnsafeRawPointer(bitPattern: buf + UInt(VIRTIO_NET_HDR_LEN))!
            let frameLen = Int(ulen) - VIRTIO_NET_HDR_LEN
            let r = stack.onFrame(frame, frameLen,
                                  out: virtioNetTxBuffer(),
                                  outCap: NET_BUFSZ - VIRTIO_NET_HDR_LEN)
            var retained = false
            if r.arpResolved {
                agg.arpResolved = true; agg.resolvedIP = r.resolvedIP; agg.resolvedMac = r.resolvedMac
            }
            if r.echoReply { agg.echoReply = true; agg.echoSeq = r.echoSeq }
            if r.gotUDP {
                netRxRefDeliveredTotal += 1
                retained = socketDeliverUDP(srcIP: r.udpSrcIP, srcPort: r.udpSrcPort,
                                            dstPort: r.udpDstPort, rxRef: rxid,
                                            payloadOffset: r.udpPayloadOff, len: r.udpPayloadLen)
            }
            if r.gotTCP {
                netRxRefDeliveredTotal += 1
                socketDeliverTCP(srcIP: r.tcpSrcIP, srcMac: r.tcpSrcMac, srcPort: r.tcpSrcPort,
                                 dstPort: r.tcpDstPort, flags: r.tcpFlags, seq: r.tcpSeqNum,
                                 ack: r.tcpAckNum, window: r.tcpWnd, payload: frame + r.tcpPayloadOff,
                                 payloadLen: r.tcpPayloadLen, now: systemTicks)
            }
            if r.gotUDPv6 {
                netRxRefDeliveredTotal += 1
                retained = socketDeliverUDPv6(srcIPv6: r.udpSrcIPv6, srcPort: r.udpSrcPortv6,
                                              dstPort: r.udpDstPortv6, rxRef: rxid,
                                              payloadOffset: r.udpPayloadOffv6, len: r.udpPayloadLenv6)
            }
            if r.gotTCPv6 {
                netRxRefDeliveredTotal += 1
                socketDeliverTCPv6(srcIPv6: r.tcpSrcIPv6, srcMac: r.tcpSrcMacv6, srcPort: r.tcpSrcPortv6,
                                   dstPort: r.tcpDstPortv6, flags: r.tcpFlagsv6, seq: r.tcpSeqNumv6,
                                   ack: r.tcpAckNumv6, window: r.tcpWndv6,
                                   payload: frame + r.tcpPayloadOffv6, payloadLen: r.tcpPayloadLenv6,
                                   now: systemTicks)
            }
            if r.txLen > 0 { virtioNetTxSubmit(frameLen: r.txLen) }

            if !retained {
                recycleRxDescriptor(rxid)
                recycled += 1
            }
        }
    }
    if batch > netRxBatchMax { netRxBatchMax = batch }
    if recycled > 0 {
        cleanRing(rxq)
        mmio_write32(netMmio + R_QNOTIFY, 0)
    }
    _ = virtioNetTxDrain()
    let ist = mmio_read32(netMmio + R_ISTATUS)
    if ist != 0 { mmio_write32(netMmio + R_IACK, ist) }
    return agg
}
