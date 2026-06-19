// SPDX-License-Identifier: Apache-2.0
// virtio_transport.swift — the two concrete virtio 1.0 transports (H2 / QW7).
//
// A virtio device's *virtqueue memory* (descriptor/avail/used rings) is laid out
// identically regardless of how the device is attached; only the control plane
// — status, feature negotiation, telling the device where the rings live, and
// the notify doorbell — differs between the legacy/MMIO transport (QEMU `virt`)
// and the modern PCI transport (QEMU `-cpu max` / the Hetzner ARM VM). Each
// transport is its own value-type struct conforming to `VirtioTransportOps`
// (defined in virtio_transport_ops.swift). A device driver works on either
// through a generic parameter, so the optimizer monomorphizes the control plane
// down to direct `mmio_*` calls with no `isPci` branch — see the file header
// there for why this is never `any VirtioTransportOps`.

// virtio-mmio register offsets (a subset; full set documented in virtio_rng).
private let M_DEVFEAT: UInt = 0x010
private let M_DEVFEATSEL: UInt = 0x014
private let M_DRVFEAT: UInt = 0x020
private let M_DRVFEATSEL: UInt = 0x024
private let M_QSEL: UInt = 0x030
private let M_QNUMMAX: UInt = 0x034
private let M_QNUM: UInt = 0x038
private let M_QREADY: UInt = 0x044
private let M_QNOTIFY: UInt = 0x050
private let M_ISTATUS: UInt = 0x060
private let M_IACK: UInt = 0x064
private let M_STATUS: UInt = 0x070
private let M_QDESCL: UInt = 0x080
private let M_QDESCH: UInt = 0x084
private let M_QDRVL: UInt = 0x090
private let M_QDRVH: UInt = 0x094
private let M_QDEVL: UInt = 0x0a0
private let M_QDEVH: UInt = 0x0a4
private let M_CONFIG: UInt = 0x100        // device-specific config (e.g. the MAC)

private let maxVirtqueues = 4             // rng uses 1; net uses 2 (rx, tx)

// virtio_pci_common_cfg field offsets (virtio 1.0 §4.1.4.3).
private let C_DEVFEATSEL: UInt = 0x00
private let C_DEVFEAT: UInt = 0x04
private let C_DRVFEATSEL: UInt = 0x08
private let C_DRVFEAT: UInt = 0x0C
private let C_STATUS: UInt = 0x14            // device_status (u8)
private let C_QSEL: UInt = 0x16              // queue_select (u16)
private let C_QSIZE: UInt = 0x18             // queue_size (u16)
private let C_QENABLE: UInt = 0x1C           // queue_enable (u16)
private let C_QNOTIFYOFF: UInt = 0x1E        // queue_notify_off (u16)
private let C_QDESC: UInt = 0x20             // queue_desc (u64)
private let C_QDRIVER: UInt = 0x28           // queue_driver / avail (u64)
private let C_QDEVICE: UInt = 0x30           // queue_device / used (u64)

// --- legacy / virtio-mmio transport (QEMU `virt`) ---------------------------
struct VirtioMmioTransport: VirtioTransportOps {
    let mmio: UInt                           // virtio-mmio register base
    var isPci: Bool { false }

    init(_ base: UInt) { mmio = base }

    func setStatus(_ value: UInt32) { mmio_write32(mmio + M_STATUS, value) }
    func getStatus() -> UInt32 { mmio_read32(mmio + M_STATUS) }

    func deviceFeatures() -> UInt64 {
        mmio_write32(mmio + M_DEVFEATSEL, 0)
        let lo = mmio_read32(mmio + M_DEVFEAT)
        mmio_write32(mmio + M_DEVFEATSEL, 1)
        let hi = mmio_read32(mmio + M_DEVFEAT)
        return UInt64(lo) | (UInt64(hi) << 32)
    }

    func setDriverFeatures(_ features: UInt64) {
        let lo = UInt32(truncatingIfNeeded: features)
        let hi = UInt32(truncatingIfNeeded: features >> 32)
        mmio_write32(mmio + M_DRVFEATSEL, 0)
        mmio_write32(mmio + M_DRVFEAT, lo)
        mmio_write32(mmio + M_DRVFEATSEL, 1)
        mmio_write32(mmio + M_DRVFEAT, hi)
    }

    func configRead32(_ offset: UInt) -> UInt32 { mmio_read32(mmio + M_CONFIG + offset) }

    // Select queue `q`, clamp `requested` to the device maximum, publish the ring
    // physical addresses, and enable it. Returns the queue size actually used, or
    // 0 if the queue is absent. Non-mutating (no per-queue notify address to
    // record) — it still satisfies the `mutating` protocol requirement.
    func setupQueue(_ q: UInt16, requested: UInt32,
                    desc: UInt64, avail: UInt64, used: UInt64) -> UInt32 {
        mmio_write32(mmio + M_QSEL, UInt32(q))
        let maxq = mmio_read32(mmio + M_QNUMMAX)
        if maxq == 0 { return 0 }
        let size = requested < maxq ? requested : maxq
        mmio_write32(mmio + M_QNUM, size)
        mmio_write32(mmio + M_QDESCL, UInt32(desc & 0xFFFF_FFFF))
        mmio_write32(mmio + M_QDESCH, UInt32(desc >> 32))
        mmio_write32(mmio + M_QDRVL, UInt32(avail & 0xFFFF_FFFF))
        mmio_write32(mmio + M_QDRVH, UInt32(avail >> 32))
        mmio_write32(mmio + M_QDEVL, UInt32(used & 0xFFFF_FFFF))
        mmio_write32(mmio + M_QDEVH, UInt32(used >> 32))
        mmio_write32(mmio + M_QREADY, 1)
        return size
    }

    func notify(queue q: UInt16) { mmio_write32(mmio + M_QNOTIFY, UInt32(q)) }

    func ackInterrupt() {
        let s = mmio_read32(mmio + M_ISTATUS)
        if s != 0 { mmio_write32(mmio + M_IACK, s) }
    }
}

// --- modern / virtio-pci transport (`-cpu max`, Hetzner) --------------------
struct VirtioPciTransport: VirtioTransportOps {
    let pci: VirtioPciDevice                 // resolved modern virtio-pci device
    // Per-queue notify doorbell address. Each queue can have a distinct
    // notify_off; recorded in setupQueue (hence this transport's setupQueue is
    // genuinely `mutating`). MMIO has no equivalent — it notifies by index.
    private(set) var notifyAddrs: InlineArray<4, UInt> = .init(repeating: 0)
    var isPci: Bool { true }

    init(_ device: VirtioPciDevice) { pci = device }

    func setStatus(_ value: UInt32) {
        mmio_write8(pci.common + C_STATUS, UInt8(truncatingIfNeeded: value))
    }
    func getStatus() -> UInt32 { UInt32(mmio_read8(pci.common + C_STATUS)) }

    func deviceFeatures() -> UInt64 {
        mmio_write32(pci.common + C_DEVFEATSEL, 0)
        let lo = mmio_read32(pci.common + C_DEVFEAT)
        mmio_write32(pci.common + C_DEVFEATSEL, 1)
        let hi = mmio_read32(pci.common + C_DEVFEAT)
        return UInt64(lo) | (UInt64(hi) << 32)
    }

    func setDriverFeatures(_ features: UInt64) {
        let lo = UInt32(truncatingIfNeeded: features)
        let hi = UInt32(truncatingIfNeeded: features >> 32)
        mmio_write32(pci.common + C_DRVFEATSEL, 0)
        mmio_write32(pci.common + C_DRVFEAT, lo)
        mmio_write32(pci.common + C_DRVFEATSEL, 1)
        mmio_write32(pci.common + C_DRVFEAT, hi)
    }

    func configRead32(_ offset: UInt) -> UInt32 { mmio_read32(pci.device + offset) }

    mutating func setupQueue(_ q: UInt16, requested: UInt32,
                             desc: UInt64, avail: UInt64, used: UInt64) -> UInt32 {
        mmio_write16(pci.common + C_QSEL, q)
        let maxq = UInt32(mmio_read16(pci.common + C_QSIZE))
        if maxq == 0 { return 0 }
        let size = requested < maxq ? requested : maxq
        mmio_write16(pci.common + C_QSIZE, UInt16(truncatingIfNeeded: size))
        mmio_write64(pci.common + C_QDESC, desc)
        mmio_write64(pci.common + C_QDRIVER, avail)
        mmio_write64(pci.common + C_QDEVICE, used)
        let notifyOff = UInt(mmio_read16(pci.common + C_QNOTIFYOFF))
        if Int(q) < maxVirtqueues {
            notifyAddrs[Int(q)] = pci.notify + notifyOff * UInt(pci.notifyMultiplier)
        }
        mmio_write16(pci.common + C_QENABLE, 1)
        return size
    }

    func notify(queue q: UInt16) {
        // The modern notify register expects the queue index (16-bit). Each queue
        // has its own doorbell address (resolved in setupQueue).
        if Int(q) < maxVirtqueues { mmio_write16(notifyAddrs[Int(q)], q) }
    }

    func ackInterrupt() {
        _ = mmio_read8(pci.isr)   // reading ISR acks it on the PCI transport
    }
}
