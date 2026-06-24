// SPDX-License-Identifier: Apache-2.0
// netdriverprobe.swift — NS2 userland virtio-net driver (/bin/netdriverprobe).
//
// Second step of network serviceization: prove an EL0 driver can do real TX/RX on a
// NIC, without disturbing the primary kernel-owned NIC. It claims the SECONDARY
// virtio-net grant (virtio-net.1, present only when a second NIC is attached; the
// in-kernel net driver always binds the first), maps the window, brings up the RX
// and TX virtqueues entirely from userland (resolving every ring/buffer physical
// address via SYS_virt_to_phys), then performs an ARP round-trip against the slirp
// gateway: it transmits an ARP request for 10.0.2.2 and receives slirp's ARP reply,
// proving both directions work from EL0.
//
// On a single-NIC profile (production) virtio-net.1 does not exist, so the claim
// fails and the probe exits 0 — it never touches the live kernel NIC.

// ---- device grant bits (mirror swift_user.h) ------------------------------
let ndKindVirtioNet: UInt32 = 3
let ndBusVirtioMmio: UInt32 = 2
let ndFlagMmioGrant: UInt32 = 1 << 2
let ndFlagIrqGrant: UInt32 = 1 << 3
let ndFlagDmaGrant: UInt32 = 1 << 4

// ---- virtio-mmio registers + status ---------------------------------------
let ndR_MAGIC: UInt = 0x00, ndR_DEVID: UInt = 0x08
let ndR_DEVFEAT: UInt = 0x10, ndR_DEVFEATSEL: UInt = 0x14
let ndR_DRVFEAT: UInt = 0x20, ndR_DRVFEATSEL: UInt = 0x24
let ndR_QSEL: UInt = 0x30, ndR_QNUMMAX: UInt = 0x34, ndR_QNUM: UInt = 0x38
let ndR_QREADY: UInt = 0x44, ndR_QNOTIFY: UInt = 0x50, ndR_STATUS: UInt = 0x70
let ndR_QDESCL: UInt = 0x80, ndR_QDESCH: UInt = 0x84
let ndR_QDRVL: UInt = 0x90, ndR_QDRVH: UInt = 0x94
let ndR_QDEVL: UInt = 0xa0, ndR_QDEVH: UInt = 0xa4
let ndR_CONFIG: UInt = 0x100
let ndMagic: UInt32 = 0x74726976, ndDevIdNet: UInt32 = 1
let ndS_ACK: UInt32 = 1, ndS_DRV: UInt32 = 2, ndS_DRVOK: UInt32 = 4, ndS_FEATOK: UInt32 = 8

let ndQSZ = 8
let ndBUFSZ: UInt = 2048
let ndHDR = 12               // virtio_net_hdr length (virtio 1.0)
let ndOFF_DESC: UInt = 0x000, ndOFF_AVAIL: UInt = 0x200, ndOFF_USED: UInt = 0x400
let ndDESC_F_WRITE: UInt16 = 2

// A split-virtqueue laid out in one mmap page (desc/avail/used), with its buffer
// pool in a separate allocation. Every physical address is resolved per-page via
// virt_to_phys, so no allocation needs to be physically contiguous.
struct NdQueue {
    var ringVA: UInt = 0, ringPA: UInt = 0
    var bufVA: UInt = 0
    var qn: UInt32 = 0
    var availIdx: UInt16 = 0
    var lastUsed: UInt16 = 0
}

func ndW16(_ a: UInt, _ v: UInt16) { swiftos_mmio_write16(a, v) }
func ndW32(_ a: UInt, _ v: UInt32) { swiftos_mmio_write32(a, v) }
func ndR16(_ a: UInt) -> UInt16 { swiftos_mmio_read16(a) }

// Big-endian frame writers (network byte order) into normal RAM.
func beW16(_ p: UInt, _ off: Int, _ v: UInt16) {
    let q = UnsafeMutableRawPointer(bitPattern: p + UInt(off))!
    q.storeBytes(of: UInt8(v >> 8), as: UInt8.self)
    (q + 1).storeBytes(of: UInt8(v & 0xff), as: UInt8.self)
}
func beW32(_ p: UInt, _ off: Int, _ v: UInt32) {
    let q = UnsafeMutableRawPointer(bitPattern: p + UInt(off))!
    q.storeBytes(of: UInt8((v >> 24) & 0xff), as: UInt8.self)
    (q + 1).storeBytes(of: UInt8((v >> 16) & 0xff), as: UInt8.self)
    (q + 2).storeBytes(of: UInt8((v >> 8) & 0xff), as: UInt8.self)
    (q + 3).storeBytes(of: UInt8(v & 0xff), as: UInt8.self)
}
func b8(_ p: UInt, _ off: Int) -> UInt8 {
    UnsafeRawPointer(bitPattern: p + UInt(off))!.load(as: UInt8.self)
}
func beR16(_ p: UInt, _ off: Int) -> UInt16 {
    (UInt16(b8(p, off)) << 8) | UInt16(b8(p, off + 1))
}
func beR32(_ p: UInt, _ off: Int) -> UInt32 {
    (UInt32(b8(p, off)) << 24) | (UInt32(b8(p, off + 1)) << 16)
        | (UInt32(b8(p, off + 2)) << 8) | UInt32(b8(p, off + 3))
}

func ndPutHex2(_ b: UInt8) {
    let hi = b >> 4, lo = b & 0xf
    swiftos_putc(hi < 10 ? UInt8(ascii: "0") + hi : UInt8(ascii: "a") + (hi - 10))
    swiftos_putc(lo < 10 ? UInt8(ascii: "0") + lo : UInt8(ascii: "a") + (lo - 10))
}

// Set up queue `q` (0=RX, 1=TX): size it, allocate its ring page, resolve the ring
// PA, and program the device's queue registers. Buffers are posted by the caller.
func ndSetupQueue(_ mmio: UInt, _ fd: Int32, _ q: UInt32, _ out: inout NdQueue) -> Bool {
    swiftos_mmio_write32(mmio + ndR_QSEL, q)
    let maxq = swiftos_mmio_read32(mmio + ndR_QNUMMAX)
    if maxq == 0 { return false }
    out.qn = maxq < UInt32(ndQSZ) ? maxq : UInt32(ndQSZ)
    swiftos_mmio_write32(mmio + ndR_QNUM, out.qn)
    let ringVA = swiftos_mmap(4096, Int32(SWIFTOS_PROT_READ | SWIFTOS_PROT_WRITE))
    if ringVA == 0 { return false }
    let pa = swiftos_virt_to_phys(ringVA, fd)
    if pa < 0 { return false }
    out.ringVA = ringVA
    out.ringPA = UInt(bitPattern: Int(pa))
    let d = out.ringPA + ndOFF_DESC, a = out.ringPA + ndOFF_AVAIL, u = out.ringPA + ndOFF_USED
    swiftos_mmio_write32(mmio + ndR_QDESCL, UInt32(d & 0xFFFF_FFFF)); swiftos_mmio_write32(mmio + ndR_QDESCH, UInt32(d >> 32))
    swiftos_mmio_write32(mmio + ndR_QDRVL, UInt32(a & 0xFFFF_FFFF)); swiftos_mmio_write32(mmio + ndR_QDRVH, UInt32(a >> 32))
    swiftos_mmio_write32(mmio + ndR_QDEVL, UInt32(u & 0xFFFF_FFFF)); swiftos_mmio_write32(mmio + ndR_QDEVH, UInt32(u >> 32))
    swiftos_mmio_write32(mmio + ndR_QREADY, 1)
    return true
}

// Write descriptor `i` of queue `q` (addr is a physical buffer address).
func ndDesc(_ q: NdQueue, _ i: Int, _ pa: UInt, _ len: UInt32, _ flags: UInt16) {
    let base = q.ringVA + ndOFF_DESC + UInt(i * 16)
    swiftos_mmio_write64(base + 0, pa)
    swiftos_mmio_write32(base + 8, len)
    swiftos_mmio_write16(base + 12, flags)
    swiftos_mmio_write16(base + 14, 0)
}

@_cdecl("main")
func main(_ argc: Int32,
         _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
         _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp

    var info = swiftos_device_info()
    let fd = swiftos_device_claim("virtio-net.1", &info)
    if fd < 0 {
        swiftos_puts("netdriverprobe: no secondary virtio-net device; exiting\n")
        return 0
    }
    if info.claimed != 1 || info.irq != 0 ||
       info.kind != ndKindVirtioNet || info.bus != ndBusVirtioMmio ||
       info.mmio_base == 0 || info.mmio_len == 0 ||
       (info.flags & ndFlagMmioGrant) == 0 ||
       (info.flags & (ndFlagIrqGrant | ndFlagDmaGrant)) != 0 {
        swiftos_puts("netdriverprobe: net grant not usable\n")
        _ = swiftos_close(fd); return 1
    }

    let r = swiftos_device_mmap(fd, UInt(info.mmio_len))
    if r < 0 { swiftos_puts("netdriverprobe: device_mmap failed\n"); _ = swiftos_close(fd); return 1 }
    let mmio = UInt(bitPattern: Int(r))
    if swiftos_mmio_read32(mmio + ndR_MAGIC) != ndMagic ||
       swiftos_mmio_read32(mmio + ndR_DEVID) != ndDevIdNet {
        swiftos_puts("netdriverprobe: not a virtio-net device\n"); _ = swiftos_close(fd); return 1
    }

    // Reset + feature negotiation (VIRTIO_F_VERSION_1 required; VIRTIO_NET_F_MAC if
    // offered, so we read the device-assigned MAC).
    swiftos_mmio_write32(mmio + ndR_STATUS, 0)
    swiftos_mmio_write32(mmio + ndR_STATUS, ndS_ACK)
    swiftos_mmio_write32(mmio + ndR_STATUS, ndS_ACK | ndS_DRV)
    swiftos_mmio_write32(mmio + ndR_DEVFEATSEL, 0)
    let feat0 = swiftos_mmio_read32(mmio + ndR_DEVFEAT)
    let haveMac = (feat0 & (UInt32(1) << 5)) != 0
    swiftos_mmio_write32(mmio + ndR_DRVFEATSEL, 1); swiftos_mmio_write32(mmio + ndR_DRVFEAT, 1) // VERSION_1
    swiftos_mmio_write32(mmio + ndR_DRVFEATSEL, 0); swiftos_mmio_write32(mmio + ndR_DRVFEAT, haveMac ? (UInt32(1) << 5) : 0)
    swiftos_mmio_write32(mmio + ndR_STATUS, ndS_ACK | ndS_DRV | ndS_FEATOK)
    if (swiftos_mmio_read32(mmio + ndR_STATUS) & ndS_FEATOK) == 0 {
        swiftos_puts("netdriverprobe: FEATURES_OK rejected\n"); _ = swiftos_close(fd); return 1
    }

    var mac = [UInt8](repeating: 0, count: 6)
    if haveMac {
        let lo = swiftos_mmio_read32(mmio + ndR_CONFIG + 0), hi = swiftos_mmio_read32(mmio + ndR_CONFIG + 4)
        mac[0] = UInt8(lo & 0xff); mac[1] = UInt8((lo >> 8) & 0xff)
        mac[2] = UInt8((lo >> 16) & 0xff); mac[3] = UInt8((lo >> 24) & 0xff)
        mac[4] = UInt8(hi & 0xff); mac[5] = UInt8((hi >> 8) & 0xff)
    } else {
        mac = [0x52, 0x54, 0x00, 0x12, 0x34, 0x56]
    }

    // Bring up RX (queue 0) and TX (queue 1).
    var rxq = NdQueue(), txq = NdQueue()
    if !ndSetupQueue(mmio, fd, 0, &rxq) || !ndSetupQueue(mmio, fd, 1, &txq) {
        swiftos_puts("netdriverprobe: queue setup failed\n"); _ = swiftos_close(fd); return 1
    }
    // RX buffer pool: ndQSZ buffers of ndBUFSZ. Each 2048-byte buffer fits within a
    // single page (4096 % 2048 == 0), so its PA from virt_to_phys is contiguous.
    let rxPages = UInt((ndQSZ * Int(ndBUFSZ) + 4095) / 4096)
    rxq.bufVA = swiftos_mmap(rxPages * 4096, Int32(SWIFTOS_PROT_READ | SWIFTOS_PROT_WRITE))
    let txBufVA = swiftos_mmap(4096, Int32(SWIFTOS_PROT_READ | SWIFTOS_PROT_WRITE))
    if rxq.bufVA == 0 || txBufVA == 0 {
        swiftos_puts("netdriverprobe: buffer mmap failed\n"); _ = swiftos_close(fd); return 1
    }
    // Post all RX descriptors (device-writable), then publish them.
    var i = 0
    while i < Int(rxq.qn) {
        let bva = rxq.bufVA + UInt(i) * ndBUFSZ
        let bpa = swiftos_virt_to_phys(bva, fd)
        if bpa < 0 { swiftos_puts("netdriverprobe: rx virt_to_phys failed\n"); _ = swiftos_close(fd); return 1 }
        ndDesc(rxq, i, UInt(bitPattern: Int(bpa)), UInt32(ndBUFSZ), ndDESC_F_WRITE)
        ndW16(rxq.ringVA + ndOFF_AVAIL + 4 + UInt(i * 2), UInt16(i))
        i += 1
    }
    rxq.availIdx = UInt16(rxq.qn)
    ndW16(rxq.ringVA + ndOFF_AVAIL + 2, rxq.availIdx)
    swiftos_dmb()
    swiftos_mmio_write32(mmio + ndR_STATUS, ndS_ACK | ndS_DRV | ndS_FEATOK | ndS_DRVOK)
    swiftos_mmio_write32(mmio + ndR_QNOTIFY, 0) // kick RX

    swiftos_puts("NS2: userland virtio-net up on virtio-net.1, MAC ")
    for j in 0..<6 { if j != 0 { swiftos_putc(UInt8(ascii: ":")) }; ndPutHex2(mac[j]) }
    swiftos_putc(UInt8(ascii: "\n"))

    // Build an ARP request for 10.0.2.2 (slirp gateway) in the TX buffer, after the
    // 12-byte virtio_net_hdr (left zeroed). Ethernet(14) + ARP(28) = 42 bytes.
    let f = txBufVA + UInt(ndHDR)
    let bcast: [UInt8] = [0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
    let myIP: UInt32 = 0x0a00020f   // 10.0.2.15 (slirp guest)
    let gwIP: UInt32 = 0x0a000202   // 10.0.2.2  (slirp gateway)
    for k in 0..<6 { UnsafeMutableRawPointer(bitPattern: f + UInt(k))!.storeBytes(of: bcast[k], as: UInt8.self) }      // eth dst
    for k in 0..<6 { UnsafeMutableRawPointer(bitPattern: f + 6 + UInt(k))!.storeBytes(of: mac[k], as: UInt8.self) }     // eth src
    beW16(f, 12, 0x0806)            // ethertype ARP
    beW16(f, 14, 1); beW16(f, 16, 0x0800); UnsafeMutableRawPointer(bitPattern: f + 18)!.storeBytes(of: UInt8(6), as: UInt8.self)
    UnsafeMutableRawPointer(bitPattern: f + 19)!.storeBytes(of: UInt8(4), as: UInt8.self)
    beW16(f, 20, 1)                 // op = request
    for k in 0..<6 { UnsafeMutableRawPointer(bitPattern: f + 22 + UInt(k))!.storeBytes(of: mac[k], as: UInt8.self) }    // sha
    beW32(f, 28, myIP)              // spa
    for k in 0..<6 { UnsafeMutableRawPointer(bitPattern: f + 32 + UInt(k))!.storeBytes(of: UInt8(0), as: UInt8.self) }  // tha
    beW32(f, 38, gwIP)              // tpa
    let frameLen = UInt32(ndHDR + 42)
    let txPA = swiftos_virt_to_phys(txBufVA, fd)
    if txPA < 0 { swiftos_puts("netdriverprobe: tx virt_to_phys failed\n"); _ = swiftos_close(fd); return 1 }

    // TX + poll RX for the ARP reply. Re-transmit a few times in case the first
    // request races slirp's readiness; bounded so the probe always terminates.
    var attempt = 0
    while attempt < 20 {
        ndDesc(txq, 0, UInt(bitPattern: Int(txPA)), frameLen, 0) // device reads
        ndW16(txq.ringVA + ndOFF_AVAIL + 4, 0)
        txq.availIdx &+= 1
        ndW16(txq.ringVA + ndOFF_AVAIL + 2, txq.availIdx)
        swiftos_dmb()
        swiftos_mmio_write32(mmio + ndR_QNOTIFY, 1) // kick TX

        var spin = 0
        while spin < 20 {
            swiftos_dmb()
            let uidx = ndR16(rxq.ringVA + ndOFF_USED + 2)
            while rxq.lastUsed != uidx {
                let slot = Int(rxq.lastUsed % UInt16(rxq.qn))
                let id = swiftos_mmio_read32(rxq.ringVA + ndOFF_USED + 4 + UInt(slot * 8)) % rxq.qn
                let pkt = rxq.bufVA + UInt(id) * ndBUFSZ + UInt(ndHDR) // skip virtio_net_hdr
                // Ethernet type @12, ARP op @ 14+6=20, sender IP (spa) @ 14+14=28.
                if beR16(pkt, 12) == 0x0806 && beR16(pkt, 20) == 2 && beR32(pkt, 28) == gwIP {
                    swiftos_puts("NS2 OK: userland virtio-net TX/RX — ARP reply, 10.0.2.2 is at ")
                    for k in 0..<6 { if k != 0 { swiftos_putc(UInt8(ascii: ":")) }; ndPutHex2(b8(pkt, 22 + k)) }
                    swiftos_putc(UInt8(ascii: "\n"))
                    _ = swiftos_close(fd)
                    return 0
                }
                // Refill this RX buffer.
                let bpa = swiftos_virt_to_phys(rxq.bufVA + UInt(id) * ndBUFSZ, fd)
                if bpa >= 0 { ndDesc(rxq, Int(id), UInt(bitPattern: Int(bpa)), UInt32(ndBUFSZ), ndDESC_F_WRITE) }
                ndW16(rxq.ringVA + ndOFF_AVAIL + 4 + UInt((Int(rxq.availIdx) % Int(rxq.qn)) * 2), UInt16(id))
                rxq.availIdx &+= 1
                ndW16(rxq.ringVA + ndOFF_AVAIL + 2, rxq.availIdx)
                rxq.lastUsed &+= 1
            }
            swiftos_dmb(); swiftos_mmio_write32(mmio + ndR_QNOTIFY, 0) // re-kick RX
            swiftos_nanosleep(0, 5_000_000) // 5 ms
            spin += 1
        }
        attempt += 1
    }

    swiftos_puts("netdriverprobe: no ARP reply received\n")
    _ = swiftos_close(fd)
    return 1
}
