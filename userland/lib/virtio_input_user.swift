// SPDX-License-Identifier: Apache-2.0
// virtio_input_user.swift — userland virtio-input (keyboard) driver core, shared by
// the C5i self-test service (/bin/svc-input) and the C5j persistent driver
// (/bin/inputd). It owns the device entirely from EL0: map the MMIO window
// (sys_device_mmap), resolve the virtqueue's physical address (SYS_virt_to_phys),
// run the legacy split-virtqueue handshake, and decode evdev key events to ASCII.
//
// All register and ring access goes through the volatile swiftos_mmio_* / swiftos_dmb
// bridges — the low-level MMIO/DMA ordering Embedded Swift cannot express directly.
// The single-page ring layout mirrors the in-kernel driver this replaces, so the
// proven offsets carry over.

// virtio-mmio register offsets, by byte offset from the window base.
let vioR_MAGIC: UInt      = 0x00
let vioR_DEVID: UInt      = 0x08
let vioR_DEVFEAT: UInt    = 0x10
let vioR_DEVFEATSEL: UInt = 0x14
let vioR_DRVFEAT: UInt    = 0x20
let vioR_DRVFEATSEL: UInt = 0x24
let vioR_QSEL: UInt       = 0x30
let vioR_QNUMMAX: UInt    = 0x34
let vioR_QNUM: UInt       = 0x38
let vioR_QREADY: UInt     = 0x44
let vioR_QNOTIFY: UInt    = 0x50
let vioR_STATUS: UInt     = 0x70
let vioR_QDESCL: UInt     = 0x80
let vioR_QDESCH: UInt     = 0x84
let vioR_QDRVL: UInt      = 0x90
let vioR_QDRVH: UInt      = 0x94
let vioR_QDEVL: UInt      = 0xa0
let vioR_QDEVH: UInt      = 0xa4

let vioMagic: UInt32 = 0x74726976   // "virt"
let vioDevIdInput: UInt32 = 18

let vioS_ACK: UInt32    = 1
let vioS_DRV: UInt32    = 2
let vioS_DRVOK: UInt32  = 4
let vioS_FEATOK: UInt32 = 8

// Single-page split-virtqueue layout (one mmap page covers all three rings plus
// the event-buffer pool). Queue size 8; each input event buffer is 8 bytes
// (struct virtio_input_event { __le16 type; __le16 code; __le32 value; }).
let vioQSize = 8
let vioDescBytes = 16
let vioEvBytes = 8
let vioOFF_DESC: UInt  = 0x000
let vioOFF_AVAIL: UInt = 0x080
let vioOFF_USED: UInt  = 0x100
let vioOFF_EVBUF: UInt = 0x200
let vioVIRTQ_DESC_F_WRITE: UInt16 = 2

struct VirtioQueue {
    var ringVA: UInt = 0
    var ringPA: UInt = 0
    var qn: UInt32 = 0
    var availIdx: UInt16 = 0
    var lastUsed: UInt16 = 0
}

func ringWrite16(_ va: UInt, _ off: UInt, _ v: UInt16) { swiftos_mmio_write16(va + off, v) }
func ringRead16(_ va: UInt, _ off: UInt) -> UInt16 { swiftos_mmio_read16(va + off) }

// Bring the virtio-input event virtqueue up entirely from userland. `mmio` is the
// mapped register window; `deviceFd` is the mappable grant (needed to resolve the
// ring's physical address via virt_to_phys). On success returns the ring VA + PA
// and the negotiated queue size; on failure returns ringVA == 0.
func virtioInputInit(_ mmio: UInt, _ deviceFd: Int32) -> VirtioQueue {
    var q = VirtioQueue()

    // 1. Reset and acknowledge.
    swiftos_mmio_write32(mmio + vioR_STATUS, 0)
    swiftos_mmio_write32(mmio + vioR_STATUS, vioS_ACK)
    swiftos_mmio_write32(mmio + vioR_STATUS, vioS_ACK | vioS_DRV)

    // 2. Negotiate features: accept only VIRTIO_F_VERSION_1 (feature bit 32 ==
    //    word 1, bit 0). Read DEVICE_FEATURES word 1 for completeness, then offer
    //    just VERSION_1 back and clear word 0.
    swiftos_mmio_write32(mmio + vioR_DEVFEATSEL, 1)
    _ = swiftos_mmio_read32(mmio + vioR_DEVFEAT)
    swiftos_mmio_write32(mmio + vioR_DRVFEATSEL, 1); swiftos_mmio_write32(mmio + vioR_DRVFEAT, 1)
    swiftos_mmio_write32(mmio + vioR_DRVFEATSEL, 0); swiftos_mmio_write32(mmio + vioR_DRVFEAT, 0)
    swiftos_mmio_write32(mmio + vioR_STATUS, vioS_ACK | vioS_DRV | vioS_FEATOK)
    if (swiftos_mmio_read32(mmio + vioR_STATUS) & vioS_FEATOK) == 0 {
        swiftos_puts("virtio-input: FEATURES_OK rejected\n")
        return q
    }

    // 3. Select queue 0, size it.
    swiftos_mmio_write32(mmio + vioR_QSEL, 0)
    let maxq = swiftos_mmio_read32(mmio + vioR_QNUMMAX)
    if maxq == 0 {
        swiftos_puts("virtio-input: queue unavailable\n")
        return q
    }
    q.qn = maxq < UInt32(vioQSize) ? maxq : UInt32(vioQSize)
    swiftos_mmio_write32(mmio + vioR_QNUM, q.qn)

    // 4. Allocate one zero-filled page for desc/avail/used + the event-buffer pool
    //    and resolve its physical base (anonymous mmap is eager, so the PA is live).
    let ringVA = swiftos_mmap(4096, Int32(SWIFTOS_PROT_READ | SWIFTOS_PROT_WRITE))
    if ringVA == 0 {
        swiftos_puts("virtio-input: ring mmap failed\n")
        return q
    }
    let pa = swiftos_virt_to_phys(ringVA, deviceFd)
    if pa < 0 {
        swiftos_puts("virtio-input: virt_to_phys failed\n")
        _ = swiftos_munmap(ringVA, 4096)
        return q
    }
    q.ringVA = ringVA
    q.ringPA = UInt(bitPattern: Int(pa))

    // 5. Descriptors: each receive buffer is device-writable (the device fills in
    //    input events). addr is a PHYSICAL address into the same ring page.
    var i: UInt32 = 0
    while i < q.qn {
        let d = ringVA + vioOFF_DESC + UInt(Int(i) * vioDescBytes)
        let bufPA = q.ringPA + vioOFF_EVBUF + UInt(Int(i) * vioEvBytes)
        swiftos_mmio_write64(d + 0, UInt(bufPA))
        swiftos_mmio_write32(d + 8, UInt32(vioEvBytes))
        swiftos_mmio_write16(d + 12, vioVIRTQ_DESC_F_WRITE)
        swiftos_mmio_write16(d + 14, 0)
        i += 1
    }

    // 6. Program the queue's physical ring addresses and mark it ready.
    let descPA = q.ringPA + vioOFF_DESC
    let availPA = q.ringPA + vioOFF_AVAIL
    let usedPA = q.ringPA + vioOFF_USED
    swiftos_mmio_write32(mmio + vioR_QDESCL, UInt32(descPA & 0xFFFF_FFFF)); swiftos_mmio_write32(mmio + vioR_QDESCH, UInt32(descPA >> 32))
    swiftos_mmio_write32(mmio + vioR_QDRVL,  UInt32(availPA & 0xFFFF_FFFF)); swiftos_mmio_write32(mmio + vioR_QDRVH,  UInt32(availPA >> 32))
    swiftos_mmio_write32(mmio + vioR_QDEVL,  UInt32(usedPA & 0xFFFF_FFFF)); swiftos_mmio_write32(mmio + vioR_QDEVH,  UInt32(usedPA >> 32))
    swiftos_mmio_write32(mmio + vioR_QREADY, 1)

    // 7. Offer every buffer to the device, then go live and kick.
    i = 0
    while i < q.qn { ringWrite16(ringVA, vioOFF_AVAIL + 4 + UInt(Int(i) * 2), UInt16(i)); i += 1 }
    q.availIdx = UInt16(q.qn)
    ringWrite16(ringVA, vioOFF_AVAIL + 2, q.availIdx)
    swiftos_dmb()
    swiftos_mmio_write32(mmio + vioR_STATUS, vioS_ACK | vioS_DRV | vioS_FEATOK | vioS_DRVOK)
    swiftos_mmio_write32(mmio + vioR_QNOTIFY, 0)
    return q
}

// --- used-ring helpers ------------------------------------------------------
// Current device-published used index.
func virtioUsedIndex(_ q: VirtioQueue) -> UInt16 {
    swiftos_dmb()
    return ringRead16(q.ringVA, vioOFF_USED + 2)
}
// Descriptor id of the used element at `slot`.
func virtioUsedElemId(_ q: VirtioQueue, _ slot: Int) -> UInt32 {
    swiftos_mmio_read32(q.ringVA + vioOFF_USED + 4 + UInt(slot * 8)) % q.qn
}
// Hand descriptor `id`'s buffer back to the device.
func virtioRefill(_ q: inout VirtioQueue, _ id: UInt32) {
    ringWrite16(q.ringVA, vioOFF_AVAIL + 4 + UInt((Int(q.availIdx) % Int(q.qn)) * 2), UInt16(id))
    q.availIdx &+= 1
    ringWrite16(q.ringVA, vioOFF_AVAIL + 2, q.availIdx)
}

// --- evdev event accessors --------------------------------------------------
func virtioEventType(_ q: VirtioQueue, _ id: UInt32) -> UInt16 {
    ringRead16(q.ringVA, vioOFF_EVBUF + UInt(Int(id) * vioEvBytes) + 0)
}
func virtioEventCode(_ q: VirtioQueue, _ id: UInt32) -> UInt16 {
    ringRead16(q.ringVA, vioOFF_EVBUF + UInt(Int(id) * vioEvBytes) + 2)
}
func virtioEventValue(_ q: VirtioQueue, _ id: UInt32) -> UInt32 {
    swiftos_mmio_read32(q.ringVA + vioOFF_EVBUF + UInt(Int(id) * vioEvBytes) + 4)
}

// --- evdev keycode -> ASCII decoder (US layout) -----------------------------
// Mirrors the in-kernel virtio_input.swift km / km_shift tables. Tracks Shift so a
// persistent driver produces the same bytes the kernel polled driver used to.
let evKEY: UInt16 = 1   // EV_KEY

struct VirtioInputDecoder {
    var km = [UInt8](repeating: 0, count: 128)
    var kmShift = [UInt8](repeating: 0, count: 128)
    var shift = false

    init() {
        func put(_ start: Int, _ s: StaticString, _ shifted: Bool) {
            s.withUTF8Buffer { b in
                var k = 0
                while k < b.count {
                    if shifted { kmShift[start + k] = b[k] } else { km[start + k] = b[k] }
                    k += 1
                }
            }
        }
        put(2, "1234567890-=", false)
        km[14] = 8; km[15] = 9                 // backspace, tab
        put(16, "qwertyuiop[]", false)
        km[28] = 13                            // enter
        put(30, "asdfghjkl;'`", false)
        km[43] = UInt8(ascii: "\\")
        put(44, "zxcvbnm,./", false)
        km[57] = 32                            // space
        put(2, "!@#$%^&*()_+", true)
        kmShift[14] = 8; kmShift[15] = 9
        put(16, "QWERTYUIOP{}", true)
        kmShift[28] = 13
        put(30, "ASDFGHJKL:\"~", true)
        kmShift[43] = UInt8(ascii: "|")
        put(44, "ZXCVBNM<>?", true)
        kmShift[57] = 32
    }

    // Decode one event; returns an ASCII byte to inject, or 0 for modifiers /
    // releases / unmapped keys (the caller tracks Shift state via this call).
    mutating func decode(type: UInt16, code: UInt16, value: UInt32) -> UInt8 {
        if type != evKEY { return 0 }
        if code == 42 || code == 54 {            // L/R Shift
            shift = (value != 0)
            return 0
        }
        if value == 1 || value == 2 {            // press or auto-repeat
            let c = shift ? kmShift[Int(code & 0x7f)] : km[Int(code & 0x7f)]
            return c
        }
        return 0
    }
}
