// SPDX-License-Identifier: Apache-2.0
// virtio_input.swift — minimal polled virtio-input (keyboard) driver.
//
// Gives the graphical QEMU window (-device virtio-keyboard-device) a keyboard:
// the virt board exposes virtio devices over virtio-mmio (32 slots at
// 0x0A000000). We find the input device, set up its event virtqueue with a few
// receive buffers, and POLL the used ring — no IRQ wiring. virtioKbdGetchar()
// decodes evdev key presses into ASCII; the kernel drains it on each timer tick
// and feeds the tty (kernel/main.swift), so typing reaches the busybox shell.
// Arrow and navigation keys (Left/Right/Up/Down/Home/End/Delete) are emitted as
// the ANSI escape sequences the tty's cooked line editor decodes for cursor
// movement and mid-line editing.
//
// Swift rewrite of the former virtio_input.c, following virtio_net.swift: the
// ring and event buffers are one PMM page, with the small ASCII pending queue
// living (CPU-only, never DMA'd) in the page's spare area. MMIO and cache
// maintenance go through the io.h C bridge; under TCG the clean/invalidate are
// effectively no-ops, under a caching accelerator they are not.

private let KBD_MMIO_BASE: UInt   = 0x0A00_0000
private let KBD_MMIO_STRIDE: UInt = 0x200
private let KBD_MMIO_COUNT = 32
private let VIRTIO_ID_INPUT: UInt32 = 18

// virtio-mmio register offsets.
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

private let VIRTIO_MAGIC: UInt32 = 0x74726976   // "virt"

private let S_ACK: UInt32    = 1
private let S_DRV: UInt32    = 2
private let S_DRVOK: UInt32  = 4
private let S_FEATOK: UInt32 = 8

private let KBD_QSZ = 8
private let VIRTQ_DESC_F_WRITE: UInt16 = 2

// Single-page layout: rings as in virtio_net.swift, plus the 8x8 event-buffer
// pool and a 64-byte CPU-only pending ring in the page's spare area.
private let OFF_DESC: UInt    = 0x000
private let OFF_AVAIL: UInt   = 0x080
private let OFF_USED: UInt    = 0x100
private let OFF_EVBUF: UInt   = 0x200  // KBD_QSZ x 8 bytes, device-write (DMA)
private let OFF_PENDING: UInt = 0x300  // 64-byte ASCII ring, never DMA'd

private var kbdMmio: UInt = 0
private var kbdRingBase: UInt = 0
private var kbdQn: UInt32 = 0
private var kbdAvailIdx: UInt16 = 0
private var kbdLastUsed: UInt16 = 0
private var kbdShift = false
private var kbdPHead = 0
private var kbdPTail = 0
private var kbdDbgVersion: UInt32 = 0

// US-keyboard evdev keycode -> ASCII, filled once at init (mirrors the km /
// km_shift tables in the former virtio_input.c). Index by keycode & 0x7f.
private var kbdKm = [UInt8](repeating: 0, count: 128)
private var kbdKmShift = [UInt8](repeating: 0, count: 128)
private var kbdKmReady = false

private func kbdFillKeymaps() {
    if kbdKmReady { return }
    func put(_ start: Int, _ s: StaticString, shift: Bool) {
        s.withUTF8Buffer { b in
            var k = 0
            while k < b.count {
                if shift { kbdKmShift[start + k] = b[k] } else { kbdKm[start + k] = b[k] }
                k += 1
            }
        }
    }
    // Unshifted.
    put(2, "1234567890-=", shift: false)
    kbdKm[14] = 8; kbdKm[15] = 9                       // backspace, tab
    put(16, "qwertyuiop[]", shift: false)
    kbdKm[28] = 13                                     // enter
    put(30, "asdfghjkl;'`", shift: false)
    kbdKm[43] = UInt8(ascii: "\\")
    put(44, "zxcvbnm,./", shift: false)
    kbdKm[57] = 32                                     // space
    // Shifted.
    put(2, "!@#$%^&*()_+", shift: true)
    kbdKmShift[14] = 8; kbdKmShift[15] = 9
    put(16, "QWERTYUIOP{}", shift: true)
    kbdKmShift[28] = 13
    put(30, "ASDFGHJKL:\"~", shift: true)
    kbdKmShift[43] = UInt8(ascii: "|")
    put(44, "ZXCVBNM<>?", shift: true)
    kbdKmShift[57] = 32
    kbdKmReady = true
}

// --- cache maintenance ------------------------------------------------------
private func kbdClean(_ pa: UInt, _ n: Int) {
    var a = pa & ~UInt(63)
    let end = pa + UInt(n)
    while a < end { dc_cvac(a); a += 64 }
    dsb_sy()
}
private func kbdInvalidate(_ pa: UInt, _ n: Int) {
    dsb_sy()
    var a = pa & ~UInt(63)
    let end = pa + UInt(n)
    while a < end { dc_ivac(a); a += 64 }
    dsb_sy()
}
private func kbdZeroPage(_ pa: UInt) {
    let p = UnsafeMutableRawPointer(bitPattern: pa)!
    var i = 0
    while i < 4096 { p.storeBytes(of: UInt8(0), toByteOffset: i, as: UInt8.self); i += 1 }
}

// --- virtqueue accessors ----------------------------------------------------
private func kbdDescSet(_ i: Int, addr: UInt64, len: UInt32, flags: UInt16, next: UInt16) {
    let d = UnsafeMutableRawPointer(bitPattern: kbdRingBase + OFF_DESC + UInt(i * 16))!
    d.storeBytes(of: addr, toByteOffset: 0, as: UInt64.self)
    d.storeBytes(of: len, toByteOffset: 8, as: UInt32.self)
    d.storeBytes(of: flags, toByteOffset: 12, as: UInt16.self)
    d.storeBytes(of: next, toByteOffset: 14, as: UInt16.self)
}
private func kbdAvailAdd(descIdx: UInt16) {
    let avail = UnsafeMutableRawPointer(bitPattern: kbdRingBase + OFF_AVAIL)!
    let slot = Int(kbdAvailIdx % UInt16(kbdQn))
    avail.storeBytes(of: descIdx, toByteOffset: 4 + slot * 2, as: UInt16.self)
    kbdAvailIdx &+= 1
    avail.storeBytes(of: kbdAvailIdx, toByteOffset: 2, as: UInt16.self)
}
private func kbdUsedIdx() -> UInt16 {
    UnsafeRawPointer(bitPattern: kbdRingBase + OFF_USED)!.load(fromByteOffset: 2, as: UInt16.self)
}
private func kbdUsedElemId(_ slot: Int) -> UInt32 {
    UnsafeRawPointer(bitPattern: kbdRingBase + OFF_USED + 4 + UInt(slot * 8))!.load(fromByteOffset: 0, as: UInt32.self)
}

// --- pending ASCII ring (CPU-only, in the page's spare area) ----------------
private func kbdPushByte(_ c: UInt8) {
    let nt = (kbdPTail + 1) % 64
    if nt != kbdPHead {
        UnsafeMutableRawPointer(bitPattern: kbdRingBase + OFF_PENDING)!
            .storeBytes(of: c, toByteOffset: kbdPTail, as: UInt8.self)
        kbdPTail = nt
    }
}
private func kbdPushSeq(_ s: StaticString) {
    s.withUTF8Buffer { b in for x in b { kbdPushByte(x) } }
}

// Returns a small diagnostic code: 0 = no input device found, otherwise
// version*1000 + queue_size once the queue is up.
func virtioKbdInit() -> Int32 {
    kbdMmio = 0
    var found: UInt = 0
    var i = 0
    while i < KBD_MMIO_COUNT {
        let m = KBD_MMIO_BASE + UInt(i) * KBD_MMIO_STRIDE
        i += 1
        if mmio_read32(m + R_MAGIC) != VIRTIO_MAGIC { continue }
        if mmio_read32(m + R_DEVID) != VIRTIO_ID_INPUT { continue }
        found = m
        break
    }
    if found == 0 { return 0 }
    kbdMmio = found
    kbdDbgVersion = mmio_read32(found + R_VERSION)

    if kbdRingBase == 0 {
        let r = pmm_alloc_page()
        if r == 0 { kbdMmio = 0; return -3 }
        kbdRingBase = r
    }
    kbdZeroPage(kbdRingBase)
    kbdFillKeymaps()
    kbdAvailIdx = 0
    kbdLastUsed = 0
    kbdPHead = 0
    kbdPTail = 0
    kbdShift = false

    mmio_write32(found + R_STATUS, 0)                  // reset
    mmio_write32(found + R_STATUS, S_ACK)
    mmio_write32(found + R_STATUS, S_ACK | S_DRV)
    mmio_write32(found + R_DRVFEATSEL, 1); mmio_write32(found + R_DRVFEAT, 1) // VIRTIO_F_VERSION_1
    mmio_write32(found + R_DRVFEATSEL, 0); mmio_write32(found + R_DRVFEAT, 0)
    mmio_write32(found + R_STATUS, S_ACK | S_DRV | S_FEATOK)
    if (mmio_read32(found + R_STATUS) & S_FEATOK) == 0 { kbdMmio = 0; return -1 }

    mmio_write32(found + R_QSEL, 0)
    let maxq = mmio_read32(found + R_QNUMMAX)
    if maxq == 0 { kbdMmio = 0; return -2 }
    kbdQn = maxq < UInt32(KBD_QSZ) ? maxq : UInt32(KBD_QSZ)
    mmio_write32(found + R_QNUM, kbdQn)

    var j: UInt32 = 0
    while j < kbdQn {
        let buf = kbdRingBase + OFF_EVBUF + UInt(Int(j) * 8)
        kbdDescSet(Int(j), addr: UInt64(buf), len: 8, flags: VIRTQ_DESC_F_WRITE, next: 0) // device writes events
        j += 1
    }
    kbdClean(kbdRingBase + OFF_DESC, KBD_QSZ * 16)
    kbdClean(kbdRingBase + OFF_USED, 72)

    let da = UInt64(kbdRingBase + OFF_DESC)
    let aa = UInt64(kbdRingBase + OFF_AVAIL)
    let ua = UInt64(kbdRingBase + OFF_USED)
    mmio_write32(found + R_QDESCL, UInt32(da & 0xFFFF_FFFF)); mmio_write32(found + R_QDESCH, UInt32(da >> 32))
    mmio_write32(found + R_QDRVL,  UInt32(aa & 0xFFFF_FFFF)); mmio_write32(found + R_QDRVH,  UInt32(aa >> 32))
    mmio_write32(found + R_QDEVL,  UInt32(ua & 0xFFFF_FFFF)); mmio_write32(found + R_QDEVH,  UInt32(ua >> 32))
    mmio_write32(found + R_QREADY, 1)
    mmio_write32(found + R_STATUS, S_ACK | S_DRV | S_FEATOK | S_DRVOK)

    // Offer every buffer to the device.
    let avail = UnsafeMutableRawPointer(bitPattern: kbdRingBase + OFF_AVAIL)!
    j = 0
    while j < kbdQn { avail.storeBytes(of: UInt16(j), toByteOffset: 4 + Int(j) * 2, as: UInt16.self); j += 1 }
    kbdAvailIdx = UInt16(kbdQn)
    avail.storeBytes(of: kbdAvailIdx, toByteOffset: 2, as: UInt16.self)
    kbdClean(kbdRingBase + OFF_AVAIL, 32)
    mmio_write32(found + R_QNOTIFY, 0)
    return Int32(kbdDbgVersion * 1000 + kbdQn)
}

private func kbdPump() {
    if kbdMmio == 0 { return }
    kbdInvalidate(kbdRingBase + OFF_USED, 72)
    let uidx = kbdUsedIdx()
    while kbdLastUsed != uidx {
        let id = kbdUsedElemId(Int(kbdLastUsed % UInt16(kbdQn))) % kbdQn
        let evb = kbdRingBase + OFF_EVBUF + UInt(Int(id) * 8)
        kbdInvalidate(evb, 8)
        let p = UnsafeRawPointer(bitPattern: evb)!
        let type  = UInt16(p.load(fromByteOffset: 0, as: UInt8.self)) | (UInt16(p.load(fromByteOffset: 1, as: UInt8.self)) << 8)
        let code  = UInt16(p.load(fromByteOffset: 2, as: UInt8.self)) | (UInt16(p.load(fromByteOffset: 3, as: UInt8.self)) << 8)
        let value = UInt32(p.load(fromByteOffset: 4, as: UInt8.self)) | (UInt32(p.load(fromByteOffset: 5, as: UInt8.self)) << 8)
                  | (UInt32(p.load(fromByteOffset: 6, as: UInt8.self)) << 16) | (UInt32(p.load(fromByteOffset: 7, as: UInt8.self)) << 24)
        if type == 1 { // EV_KEY
            if code == 42 || code == 54 {            // L/R shift
                kbdShift = (value != 0)
            } else if value == 1 || value == 2 {     // press or auto-repeat
                // Navigation keys become the ANSI escape sequences the tty line
                // editor decodes; everything else is a single ASCII byte.
                switch code {
                case 103: kbdPushSeq("\u{1b}[A")     // Up
                case 108: kbdPushSeq("\u{1b}[B")     // Down
                case 106: kbdPushSeq("\u{1b}[C")     // Right
                case 105: kbdPushSeq("\u{1b}[D")     // Left
                case 102: kbdPushSeq("\u{1b}[H")     // Home
                case 107: kbdPushSeq("\u{1b}[F")     // End
                case 111: kbdPushSeq("\u{1b}[3~")    // Delete (forward)
                default:
                    let c = kbdShift ? kbdKmShift[Int(code & 0x7f)] : kbdKm[Int(code & 0x7f)]
                    if c != 0 { kbdPushByte(c) }
                }
            }
        }
        // Hand the buffer back to the device.
        kbdAvailAdd(descIdx: UInt16(id))
        kbdClean(kbdRingBase + OFF_AVAIL, 32)
        kbdLastUsed &+= 1
    }
    mmio_write32(kbdMmio + R_QNOTIFY, 0)
    let ist = mmio_read32(kbdMmio + R_ISTATUS)
    if ist != 0 { mmio_write32(kbdMmio + R_IACK, ist) } // keep the device quiet even though we poll
}

// Return the next typed ASCII byte, or -1 if nothing is queued.
func virtioKbdGetchar() -> Int32 {
    kbdPump()
    if kbdPHead == kbdPTail { return -1 }
    let pending = UnsafeRawPointer(bitPattern: kbdRingBase + OFF_PENDING)!
    let b = pending.load(fromByteOffset: kbdPHead, as: UInt8.self)
    kbdPHead = (kbdPHead + 1) % 64
    return Int32(b)
}
