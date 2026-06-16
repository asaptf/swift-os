// SPDX-License-Identifier: Apache-2.0
// virtio_transport.swift — transport abstraction for virtio 1.0 devices (H2).
//
// A virtio device's *virtqueue memory* (descriptor/avail/used rings) is laid out
// identically regardless of how the device is attached; only the control plane
// — status, feature negotiation, telling the device where the rings live, and
// the notify doorbell — differs between the legacy/MMIO transport (QEMU `virt`)
// and the modern PCI transport (QEMU `-cpu max` / the Hetzner ARM VM). This
// `VirtioTransport` captures that control plane behind one surface so a device
// driver (virtio-rng first) works on either without caring which it is.

// Device status bits (virtio 1.0 §2.1).
let VIRTIO_STATUS_ACK: UInt32 = 1
let VIRTIO_STATUS_DRIVER: UInt32 = 2
let VIRTIO_STATUS_DRIVER_OK: UInt32 = 4
let VIRTIO_STATUS_FEATURES_OK: UInt32 = 8

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

// VIRTIO_F_VERSION_1 is feature bit 32 → select word 1, bit 0.
private let VIRTIO_F_VERSION_1_SELECT: UInt32 = 1
private let VIRTIO_F_VERSION_1_BIT: UInt32 = 1

struct VirtioTransport {
    var isPci: Bool = false
    var mmio: UInt = 0                       // virtio-mmio register base
    var pci = VirtioPciDevice()              // resolved modern virtio-pci device
    // Per-queue notify doorbell address (PCI). Each queue can have a distinct
    // notify_off; on the mmio transport notify uses M_QNOTIFY with the index.
    private(set) var notifyAddrs: InlineArray<4, UInt> = .init(repeating: 0)

    init(mmio base: UInt) { isPci = false; mmio = base }
    init(pci device: VirtioPciDevice) { isPci = true; pci = device }

    // --- status ---
    func reset() { setStatus(0) }

    func setStatus(_ value: UInt32) {
        if isPci {
            mmio_write8(pci.common + C_STATUS, UInt8(truncatingIfNeeded: value))
        } else {
            mmio_write32(mmio + M_STATUS, value)
        }
    }

    func getStatus() -> UInt32 {
        if isPci { return UInt32(mmio_read8(pci.common + C_STATUS)) }
        return mmio_read32(mmio + M_STATUS)
    }

    // --- feature negotiation ---
    /// The 64-bit device feature bits the device offers.
    func deviceFeatures() -> UInt64 {
        if isPci {
            mmio_write32(pci.common + C_DEVFEATSEL, 0)
            let lo = mmio_read32(pci.common + C_DEVFEAT)
            mmio_write32(pci.common + C_DEVFEATSEL, 1)
            let hi = mmio_read32(pci.common + C_DEVFEAT)
            return UInt64(lo) | (UInt64(hi) << 32)
        }
        mmio_write32(mmio + M_DEVFEATSEL, 0)
        let lo = mmio_read32(mmio + M_DEVFEAT)
        mmio_write32(mmio + M_DEVFEATSEL, 1)
        let hi = mmio_read32(mmio + M_DEVFEAT)
        return UInt64(lo) | (UInt64(hi) << 32)
    }

    /// Publish the 64-bit driver feature bits we accept.
    func setDriverFeatures(_ features: UInt64) {
        let lo = UInt32(truncatingIfNeeded: features)
        let hi = UInt32(truncatingIfNeeded: features >> 32)
        if isPci {
            mmio_write32(pci.common + C_DRVFEATSEL, 0)
            mmio_write32(pci.common + C_DRVFEAT, lo)
            mmio_write32(pci.common + C_DRVFEATSEL, 1)
            mmio_write32(pci.common + C_DRVFEAT, hi)
        } else {
            mmio_write32(mmio + M_DRVFEATSEL, 0)
            mmio_write32(mmio + M_DRVFEAT, lo)
            mmio_write32(mmio + M_DRVFEATSEL, 1)
            mmio_write32(mmio + M_DRVFEAT, hi)
        }
    }

    /// Set FEATURES_OK and confirm the device accepted the negotiated set.
    func setFeaturesOk() -> Bool {
        setStatus(VIRTIO_STATUS_ACK | VIRTIO_STATUS_DRIVER | VIRTIO_STATUS_FEATURES_OK)
        return (getStatus() & VIRTIO_STATUS_FEATURES_OK) != 0
    }

    /// Convenience for single-feature devices: accept only VIRTIO_F_VERSION_1.
    func negotiateVersion1() -> Bool {
        setDriverFeatures(UInt64(1) << 32)   // bit 32 = VIRTIO_F_VERSION_1
        return setFeaturesOk()
    }

    // --- device-specific config (e.g. the virtio-net MAC) ---
    func configRead32(_ offset: UInt) -> UInt32 {
        if isPci { return mmio_read32(pci.device + offset) }
        return mmio_read32(mmio + M_CONFIG + offset)
    }

    // --- queue setup ---
    // Select queue `q`, clamp `requested` to the device maximum, publish the ring
    // physical addresses, resolve the notify doorbell, and enable it. Returns the
    // queue size actually used, or 0 if the queue is absent.
    mutating func setupQueue(_ q: UInt16, requested: UInt32,
                             desc: UInt64, avail: UInt64, used: UInt64) -> UInt32 {
        if isPci {
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

    // --- doorbell + interrupt ack ---
    func notify(queue q: UInt16) {
        if isPci {
            // The modern notify register expects the queue index (16-bit). Each
            // queue has its own doorbell address (resolved in setupQueue).
            if Int(q) < maxVirtqueues { mmio_write16(notifyAddrs[Int(q)], q) }
        } else {
            mmio_write32(mmio + M_QNOTIFY, UInt32(q))
        }
    }

    func ackInterrupt() {
        if isPci {
            _ = mmio_read8(pci.isr)   // reading ISR acks it on the PCI transport
        } else {
            let s = mmio_read32(mmio + M_ISTATUS)
            if s != 0 { mmio_write32(mmio + M_IACK, s) }
        }
    }
}
