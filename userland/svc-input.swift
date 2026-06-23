// SPDX-License-Identifier: Apache-2.0
// svc-input.swift — LA1 native Swift driver service, written over the reusable
// UserlandService template (userland_service.swift). The author implements only
// handle(); the ipc_recv → dispatch → ipc_send receive loop comes from the
// template's default run().
//
// It reproduces the drvinputd.c protocol so the existing C5 semantics carry over
// to Swift: announce DRVREADY<gen> on the reply channel, then serve
//   PING  -> DRVEVENT<gen>
//   DEVH  -> validate the transferred device grant (metadata-only) + DEVACK<gen>
//   STOP  -> exit 40+gen
// The device authority arrives ONLY via IPC handle transfer and is validated
// metadata-only (no MMIO/IRQ/DMA), exactly as drvinputd.c does — never ambient.

// Device kind/bus/flag values (mirror swift_user.h / syscall.h). Defined as Swift
// constants rather than relying on imported C macros so the validation is robust
// regardless of how the importer treats shifted/OR-ed macro expressions.
let devKindPseudoInput: UInt32 = 1
let devKindVirtioInput: UInt32 = 2
let devBusPseudo: UInt32 = 1
let devBusVirtioMmio: UInt32 = 2
let devFlagNoMmioGrant: UInt32 = 1 << 0
let devFlagDiscovered: UInt32 = 1 << 1
let devFlagMmioGrant: UInt32 = 1 << 2
let devFlagIrqGrant: UInt32 = 1 << 3
let devFlagDmaGrant: UInt32 = 1 << 4
let devFlagHardwareAuthority: UInt32 = devFlagMmioGrant | devFlagIrqGrant | devFlagDmaGrant

// Write `prefix` followed by a single generation digit into dst; returns the byte
// count (e.g. "DRVEVENT" + '1' = 9). Stack-only, no allocation.
func putGenMsg(_ dst: UnsafeMutablePointer<UInt8>, _ prefix: StaticString, _ gen: Int) -> Int {
    var n = 0
    prefix.withUTF8Buffer { buf in
        for i in 0..<buf.count { dst[i] = buf[i] }
        n = buf.count
    }
    dst[n] = UInt8(ascii: "0") + UInt8(gen)
    return n + 1
}

// Compare a 4-byte command buffer against a 4-char literal.
func cmd4Equals(_ p: UnsafePointer<UInt8>, _ s: StaticString) -> Bool {
    var eq = false
    s.withUTF8Buffer { b in
        if b.count != 4 { return }
        eq = p[0] == b[0] && p[1] == b[1] && p[2] == b[2] && p[3] == b[3]
    }
    return eq
}

// Compare the device-info name (a fixed 24-byte field) against a literal,
// requiring an exact match terminated by NUL.
func deviceNameEquals(_ info: swiftos_device_info, _ expected: StaticString) -> Bool {
    var ok = false
    withUnsafeBytes(of: info.name) { raw in
        expected.withUTF8Buffer { want in
            if want.count >= raw.count { return }
            var i = 0
            while i < want.count {
                if raw[i] != want[i] { return }
                i += 1
            }
            if raw[i] != 0 { return } // require the NUL terminator immediately after
            ok = true
        }
    }
    return ok
}

// C5h: the virtio-input.0 grant now carries real MMIO authority (deviceFlagMmioGrant),
// which this driver uses to map and probe the device. So the MMIO grant is no longer
// withheld — only the IRQ and DMA grants (1<<3, 1<<4), which remain unimplemented,
// must still be absent (along with a bound IRQ number). The pseudo-input fallback,
// which carries deviceFlagNoMmioGrant, also satisfies this.
func irqDmaAuthorityWithheld(_ info: swiftos_device_info) -> Bool {
    return info.irq == 0 &&
           (info.flags & (devFlagIrqGrant | devFlagDmaGrant)) == 0
}

func validDeviceInfo(_ info: swiftos_device_info) -> Bool {
    if info.claimed != 1 { return false }
    if !irqDmaAuthorityWithheld(info) { return false }
    // C5h: a real virtio-input grant must now advertise the mappable MMIO grant.
    let realVirtio = info.kind == devKindVirtioInput &&
                     info.bus == devBusVirtioMmio &&
                     info.mmio_base != 0 && info.mmio_len != 0 &&
                     (info.flags & devFlagDiscovered) != 0 &&
                     (info.flags & devFlagMmioGrant) != 0 &&
                     deviceNameEquals(info, "virtio-input.0")
    if realVirtio { return true }
    // Headless fallback: the metadata-only pseudo device (no MMIO window to map).
    return info.kind == devKindPseudoInput &&
           info.bus == devBusPseudo &&
           info.mmio_base == 0 && info.mmio_len == 0 &&
           (info.flags & devFlagNoMmioGrant) != 0 &&
           deviceNameEquals(info, "pseudo-input.0")
}

// virtio-mmio register offsets, by byte offset from the window base (mirrors the
// in-kernel virtio_input.swift the userland driver replaces).
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
// the event-buffer pool), identical to the kernel driver so the proven offsets
// carry over. Queue size 8; each input event buffer is 8 bytes
// (struct virtio_input_event { __le16 type; __le16 code; __le32 value; }).
let vioQSize = 8
let vioDescBytes = 16
let vioEvBytes = 8
let vioOFF_DESC: UInt  = 0x000
let vioOFF_AVAIL: UInt = 0x080
let vioOFF_USED: UInt  = 0x100
let vioOFF_EVBUF: UInt = 0x200
let vioVIRTQ_DESC_F_WRITE: UInt16 = 2

// Print a UInt as "0x"-prefixed hex (no leading-zero padding), stack-only.
func putHex(_ v: UInt) {
    swiftos_puts("0x")
    if v == 0 { swiftos_putc(UInt8(ascii: "0")); return }
    var started = false
    var shift = 60
    while shift >= 0 {
        let nyb = UInt8((v >> UInt(shift)) & 0xf)
        if nyb != 0 || started {
            started = true
            swiftos_putc(nyb < 10 ? UInt8(ascii: "0") + nyb
                                  : UInt8(ascii: "a") + (nyb - 10))
        }
        shift -= 4
    }
}

// C5h: map the granted MMIO window and verify the virtio identification registers
// through it, proving real hardware authority reached userland over the IPC grant.
// Returns the mapped base VA on success (emitting the C5h OK marker), or 0 on any
// failure.
func probeMmioGrant(_ fd: Int32, _ info: swiftos_device_info) -> UInt {
    let r = swiftos_device_mmap(fd, UInt(info.mmio_len))
    if r < 0 {
        swiftos_puts("svc-input: device_mmap failed\n")
        return 0
    }
    let base = UInt(bitPattern: Int(r))
    let magic = swiftos_mmio_read32(base + vioR_MAGIC)
    let devid = swiftos_mmio_read32(base + vioR_DEVID)
    if magic != vioMagic {
        swiftos_puts("svc-input: MMIO magic mismatch\n")
        return 0
    }
    if devid != vioDevIdInput {
        swiftos_puts("svc-input: MMIO device-id mismatch\n")
        return 0
    }
    // Report the physical window base (deterministic), not the per-run mapped VA.
    swiftos_puts("C5h OK: MMIO ")
    putHex(info.mmio_base)
    swiftos_puts(" mapped from userland, MAGIC verified\n")
    return base
}

// C5i: bring the virtio-input event virtqueue up entirely from userland — the
// driver the kernel no longer runs. `mmio` is the mapped register window;
// `deviceFd` is the mappable grant (needed to resolve the ring's physical address
// via virt_to_phys). On success returns the ring VA + physical base and the
// negotiated queue size; on failure returns ringVA == 0.
struct VirtioQueue {
    var ringVA: UInt = 0
    var ringPA: UInt = 0
    var qn: UInt32 = 0
    var availIdx: UInt16 = 0
    var lastUsed: UInt16 = 0
}

func ringWrite16(_ va: UInt, _ off: UInt, _ v: UInt16) { swiftos_mmio_write16(va + off, v) }
func ringWrite32(_ va: UInt, _ off: UInt, _ v: UInt32) { swiftos_mmio_write32(va + off, v) }
func ringRead16(_ va: UInt, _ off: UInt) -> UInt16 { swiftos_mmio_read16(va + off) }

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
        swiftos_puts("svc-input: FEATURES_OK rejected\n")
        return q
    }

    // 3. Select queue 0, size it.
    swiftos_mmio_write32(mmio + vioR_QSEL, 0)
    let maxq = swiftos_mmio_read32(mmio + vioR_QNUMMAX)
    if maxq == 0 {
        swiftos_puts("svc-input: queue unavailable\n")
        return q
    }
    q.qn = maxq < UInt32(vioQSize) ? maxq : UInt32(vioQSize)
    swiftos_mmio_write32(mmio + vioR_QNUM, q.qn)

    // 4. Allocate one zero-filled page for desc/avail/used + the event-buffer pool
    //    and resolve its physical base (anonymous mmap is eager, so the PA is live).
    let ringVA = swiftos_mmap(4096, Int32(SWIFTOS_PROT_READ | SWIFTOS_PROT_WRITE))
    if ringVA == 0 {
        swiftos_puts("svc-input: ring mmap failed\n")
        return q
    }
    let pa = swiftos_virt_to_phys(ringVA, deviceFd)
    if pa < 0 {
        swiftos_puts("svc-input: virt_to_phys failed\n")
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

// C5i: one bounded drain pass over the used ring. Decodes any pending input events
// and refills their descriptors. Returns the number of EV_KEY press bytes decoded
// (0 in the headless self-test, where no key events are generated). The persistent
// tight poll loop + tty delivery is C5j; here it proves the used-ring read path.
func virtioInputPollOnce(_ mmio: UInt, _ q: inout VirtioQueue) -> Int {
    swiftos_dmb()
    let uidx = ringRead16(q.ringVA, vioOFF_USED + 2)
    var decoded = 0
    while q.lastUsed != uidx {
        let slot = Int(q.lastUsed % UInt16(q.qn))
        let id = swiftos_mmio_read32(q.ringVA + vioOFF_USED + 4 + UInt(slot * 8)) % q.qn
        let ev = q.ringVA + vioOFF_EVBUF + UInt(Int(id) * vioEvBytes)
        let type = ringRead16(q.ringVA, (ev - q.ringVA) + 0)
        let value = swiftos_mmio_read32(ev + 4)
        if type == 1 && (value == 1 || value == 2) { decoded += 1 } // EV_KEY press/repeat
        // Hand the buffer back to the device.
        ringWrite16(q.ringVA, vioOFF_AVAIL + 4 + UInt((Int(q.availIdx) % Int(q.qn)) * 2), UInt16(id))
        q.availIdx &+= 1
        ringWrite16(q.ringVA, vioOFF_AVAIL + 2, q.availIdx)
        q.lastUsed &+= 1
    }
    if decoded > 0 { swiftos_dmb(); swiftos_mmio_write32(mmio + vioR_QNOTIFY, 0) }
    return decoded
}

// The service. Implements only handle(); run() is inherited from UserlandService.
struct InputService: UserlandService {
    let gen: Int
    var deviceFd: Int32 = -1
    var mmio: UInt = 0           // mapped MMIO window base VA (0 = not mapped)
    var queue = VirtioQueue()    // userland-owned event virtqueue (C5i)

    mutating func handle(command: UnsafePointer<UInt8>, count: Int,
                         reply: UnsafeMutablePointer<UInt8>, replyCap: Int,
                         receivedHandle: Int32) -> Int {
        if count == 4 && cmd4Equals(command, "PING") {
            if receivedHandle >= 0 { _ = swiftos_close(receivedHandle) }
            return putGenMsg(reply, "DRVEVENT", gen)
        }
        if count == 4 && cmd4Equals(command, "DEVH") {
            if receivedHandle < 0 {
                swiftos_puts("svc-input: device handle missing\n")
                return -(1 + 1) // stop, exit 1
            }
            if deviceFd >= 0 {
                _ = swiftos_close(receivedHandle)
                swiftos_puts("svc-input: duplicate device grant\n")
                return -(1 + 1)
            }
            var info = swiftos_device_info()
            if swiftos_device_query(receivedHandle, &info) != 0 {
                _ = swiftos_close(receivedHandle)
                swiftos_puts("svc-input: device info failed\n")
                return -(1 + 1)
            }
            if !validDeviceInfo(info) {
                _ = swiftos_close(receivedHandle)
                swiftos_puts("svc-input: device info mismatch\n")
                return -(1 + 1)
            }
            deviceFd = receivedHandle
            swiftos_puts("svc-input: device grant accepted gen ")
            swiftos_putc(UInt8(ascii: "0") + UInt8(gen))
            swiftos_putc(UInt8(ascii: "\n"))
            // C5h: if this is the real mappable virtio-input grant, exercise the
            // hardware authority — map the MMIO window and verify the device's
            // identification registers through the userland mapping.
            if (info.flags & devFlagMmioGrant) != 0 {
                mmio = probeMmioGrant(deviceFd, info)
                if mmio == 0 {
                    _ = swiftos_close(deviceFd)
                    deviceFd = -1
                    return -(1 + 1)
                }
                // C5i: bring the event virtqueue up entirely from userland — the
                // driver the kernel no longer runs (it skipped virtioKbdInit).
                queue = virtioInputInit(mmio, deviceFd)
                if queue.ringVA == 0 {
                    _ = swiftos_close(deviceFd)
                    deviceFd = -1
                    return -(1 + 1)
                }
                swiftos_puts("svc-input: virtio features negotiated gen ")
                swiftos_putc(UInt8(ascii: "0") + UInt8(gen)); swiftos_putc(UInt8(ascii: "\n"))
                // One bounded drain pass proves the used-ring path is live (no key
                // events are generated in the headless self-test).
                _ = virtioInputPollOnce(mmio, &queue)
                swiftos_puts("svc-input: virtio queue ready gen ")
                swiftos_putc(UInt8(ascii: "0") + UInt8(gen)); swiftos_putc(UInt8(ascii: "\n"))
            }
            return putGenMsg(reply, "DEVACK", gen)
        }
        if count == 4 && cmd4Equals(command, "STOP") {
            if receivedHandle >= 0 { _ = swiftos_close(receivedHandle) }
            if deviceFd >= 0 { _ = swiftos_close(deviceFd) }
            return -(40 + gen + 1) // stop, exit 40+gen (the C5a per-generation code)
        }
        if receivedHandle >= 0 { _ = swiftos_close(receivedHandle) }
        swiftos_puts("svc-input: unknown command\n")
        return -(1 + 1)
    }
}

func parseGen(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int {
    guard argc >= 2, let argv = argv, let p = argv[1] else { return -1 }
    var v = 0
    var i = 0
    while i < 9 {
        let c = p[i]
        if c < 48 || c > 57 { break } // '0'..'9'
        v = v * 10 + Int(c - 48)
        i += 1
    }
    return i == 0 ? -1 : v
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp
    let gen = parseGen(argc, argv)
    if gen < 1 || gen > 9 {
        swiftos_puts("svc-input: invalid generation\n")
        return 1
    }

    // By the supervisor's spawn_handles_async layout: fd 3 = command recv end,
    // fd 4 = reply send end (inherited, never argv-encoded fd numbers).
    let commandFD: Int32 = 3
    let replyFD: Int32 = 4

    swiftos_puts("svc-input: LA1 service ready gen ")
    swiftos_putc(UInt8(ascii: "0") + UInt8(gen))
    swiftos_putc(UInt8(ascii: "\n"))

    // Announce readiness over the reply channel (DRVREADY<gen>, 9 bytes).
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 16) { tmp in
        let len = putGenMsg(tmp.baseAddress!, "DRVREADY", gen)
        _ = swiftos_ipc_send(replyFD, tmp.baseAddress!, UInt(len), -1)
    }

    var svc = InputService(gen: gen)
    return svc.run(commandFD: commandFD, replyFD: replyFD)
}
