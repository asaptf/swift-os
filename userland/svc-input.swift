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

// Authority must be withheld: no IRQ, the no-MMIO-grant flag set, and none of the
// hardware-authority (MMIO/IRQ/DMA) grant bits present. Mirrors drvinputd.c.
func hardwareAuthorityWithheld(_ info: swiftos_device_info) -> Bool {
    return info.irq == 0 &&
           (info.flags & devFlagNoMmioGrant) != 0 &&
           (info.flags & devFlagHardwareAuthority) == 0
}

func validDeviceInfo(_ info: swiftos_device_info) -> Bool {
    if info.claimed != 1 { return false }
    if !hardwareAuthorityWithheld(info) { return false }
    let realVirtio = info.kind == devKindVirtioInput &&
                     info.bus == devBusVirtioMmio &&
                     info.mmio_base != 0 && info.mmio_len != 0 &&
                     (info.flags & devFlagDiscovered) != 0 &&
                     deviceNameEquals(info, "virtio-input.0")
    if realVirtio { return true }
    return info.kind == devKindPseudoInput &&
           info.bus == devBusPseudo &&
           info.mmio_base == 0 && info.mmio_len == 0 &&
           deviceNameEquals(info, "pseudo-input.0")
}

// The service. Implements only handle(); run() is inherited from UserlandService.
struct InputService: UserlandService {
    let gen: Int
    var deviceFd: Int32 = -1

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
