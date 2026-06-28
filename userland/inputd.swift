// SPDX-License-Identifier: Apache-2.0
// inputd.swift — C5j persistent userland virtio-input driver (/bin/inputd).
//
// Launched by swos-init as a long-running service. It owns the virtio-input device
// entirely from EL0 (the kernel skipped its in-kernel polled driver at C5i), and
// closes the C5i architecture gap: a forever poll loop drains the event virtqueue,
// decodes evdev key presses to ASCII, and injects each byte into the kernel tty
// (SYS_tty_inject, capConsole-gated) — so a keyboard on the graphical window once
// again reaches console-login and the foreground shell, now via userland.
//
// On a board with no virtio-input window the device claim fails and inputd exits 0
// cleanly (a no-op service), so it is harmless to list unconditionally in
// /etc/swos/services.

// Device flag/kind bits (mirror syscall.h / swift_user.h).
let inDevKindVirtioInput: UInt32 = 2
let inDevBusVirtioMmio: UInt32 = 2
let inDevFlagDiscovered: UInt32 = 1 << 1
let inDevFlagMmioGrant: UInt32 = 1 << 2
let inDevFlagIrqGrant: UInt32 = 1 << 3
let inDevFlagDmaGrant: UInt32 = 1 << 4

// The mappable virtio-input grant: discovered, MMIO-granted, and with no IRQ/DMA
// authority or bound IRQ (those remain unimplemented).
func inputDeviceUsable(_ info: swiftos_device_info) -> Bool {
    return info.claimed == 1 &&
           info.irq == 0 &&
           info.kind == inDevKindVirtioInput &&
           info.bus == inDevBusVirtioMmio &&
           info.mmio_base != 0 && info.mmio_len != 0 &&
           (info.flags & inDevFlagDiscovered) != 0 &&
           (info.flags & inDevFlagMmioGrant) != 0 &&
           (info.flags & (inDevFlagIrqGrant | inDevFlagDmaGrant)) == 0
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp

    // 1. Claim the device (capConsole, inherited from the boot principal). No
    //    virtio-input window -> nothing to drive -> exit cleanly.
    var info = swiftos_device_info()
    let fd = swiftos_device_claim("virtio-input.0", &info)
    if fd < 0 {
        swiftos_puts("inputd: no virtio-input device; exiting\n")
        return 0
    }
    if !inputDeviceUsable(info) {
        swiftos_puts("inputd: device grant not usable\n")
        _ = swiftos_close(fd)
        return 1
    }

    // 2. Map the MMIO window and bring the event virtqueue up from userland.
    let r = swiftos_device_mmap(fd, UInt(info.mmio_len))
    if r < 0 {
        swiftos_puts("inputd: device_mmap failed\n")
        _ = swiftos_close(fd)
        return 1
    }
    let mmio = UInt(bitPattern: Int(r))
    var q = virtioInputInit(mmio, fd)
    if q.ringVA == 0 {
        swiftos_puts("inputd: virtio init failed\n")
        _ = swiftos_close(fd)
        return 1
    }
    swiftos_puts("inputd: virtio-input driver ready; injecting to tty\n")

    // 3. Forever poll loop: drain the used ring, decode key presses, inject each
    //    byte into the kernel tty. Yield (1 ms) between polls so we never starve
    //    other processes — no IRQ delivery to userland yet (C5i poll strategy).
    var decoder = VirtioInputDecoder()
    var announced = false
    while true {
        let uidx = virtioUsedIndex(q)
        while q.lastUsed != uidx {
            let id = virtioUsedElemId(q, Int(q.lastUsed % UInt16(q.qn)))
            let type = virtioEventType(q, id)
            let code = virtioEventCode(q, id)
            let value = virtioEventValue(q, id)
            let bytes = decoder.decodeSeq(type: type, code: code, value: value)
            // Announce BEFORE injecting, never between bytes — printing mid-escape
            // would split a multi-byte key sequence (ESC then a delayed tail), so
            // the foreground program would see a bare ESC + literal junk.
            if !bytes.isEmpty && !announced {
                announced = true
                swiftos_puts("C5j OK: TTY bytes injected from userland driver\n")
            }
            for byte in bytes {
                _ = swiftos_tty_inject(byte)
            }
            virtioRefill(&q, id)
            q.lastUsed &+= 1
        }
        swiftos_dmb()
        swiftos_mmio_write32(mmio + vioR_QNOTIFY, 0)
        swiftos_nanosleep(0, 1_000_000) // 1 ms
    }
}
