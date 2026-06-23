// SPDX-License-Identifier: Apache-2.0
// virtio_gpu.swift — minimal polled virtio-gpu 2D driver that scans out the
// fb.swift text console.
//
// SwiftOS is a serial OS: the boot log goes to the PL011 UART. But some
// hypervisors expose no serial console at all — Hetzner Cloud's only console is
// noVNC, which shows the VM's virtio-gpu framebuffer. Unlike ramfb/GOP (where a
// write to the linear framebuffer is scanned out directly), virtio-gpu requires
// the guest to explicitly TRANSFER_TO_HOST_2D + RESOURCE_FLUSH to push pixels to
// the host scanout — without that the display stays "not active". This driver
// owns a guest framebuffer, points the fb.swift console at it, and flushes it to
// the scanout so the boot log is visible on a virtio-gpu-only console.
//
// Binds over the virtio-pci transport (H2). Polled, no interrupts — it must work
// before the GIC/timer are up so an early panic is still visible. Control queue
// (queue 0) only; the cursor queue is unused.

private let VIRTIO_ID_GPU: UInt32 = 16

// virtio-mmio identity registers (for the discovery scan; QEMU `virt` has no GPU
// on mmio, but keep the same probe shape as the other drivers).
private let R_MAGIC: UInt = 0x000
private let R_DEVID: UInt = 0x008
private let VIRTIO_MAGIC: UInt32 = 0x74726976   // "virt"

// control-queue command / response types (virtio 1.1 §5.7.6.7).
private let CMD_GET_DISPLAY_INFO: UInt32 = 0x0100
private let CMD_RESOURCE_CREATE_2D: UInt32 = 0x0101
private let CMD_SET_SCANOUT: UInt32 = 0x0103
private let CMD_RESOURCE_FLUSH: UInt32 = 0x0104
private let CMD_TRANSFER_TO_HOST_2D: UInt32 = 0x0105
private let CMD_RESOURCE_ATTACH_BACKING: UInt32 = 0x0106
private let RESP_OK_NODATA: UInt32 = 0x1100
private let RESP_OK_DISPLAY_INFO: UInt32 = 0x1101

// 32-bpp; fb.swift only paints black (0x00000000) and white (0xFFFFFFFF), so the
// channel order is immaterial — pick a format every QEMU build accepts.
private let FORMAT_B8G8R8X8_UNORM: UInt32 = 2

private let VIRTQ_DESC_F_NEXT: UInt16 = 1
private let VIRTQ_DESC_F_WRITE: UInt16 = 2

// Split-virtqueue ring layout within one page (desc | avail | used), matching
// virtio_rng so the same cache-maintenance reasoning applies.
private let OFF_DESC: UInt = 0x000
private let OFF_AVAIL: UInt = 0x080
private let OFF_USED: UInt = 0x100

private let GPU_QSZ: UInt32 = 4
private let GPU_SPIN_LIMIT = 8_000_000

private let RESOURCE_ID: UInt32 = 1
private let DEFAULT_W: UInt32 = 1024
private let DEFAULT_H: UInt32 = 768
private let MAX_W: UInt32 = 2560
private let MAX_H: UInt32 = 1600

// QW7: bring-up and the console flush run through a generic VirtioTransportOps
// parameter (monomorphized, no `isPci` branch). The active transport is retained
// for the post-init timer-driven flush: both concrete transports (one stays
// unused) plus the discriminant, never an `any VirtioTransportOps`. QEMU `virt`
// has no GPU on mmio, but the mmio probe shape is kept for symmetry.
private var gpuMmioXport = VirtioMmioTransport(0)
private var gpuPciXport = VirtioPciTransport(VirtioPciDevice())
private var gpuIsPci = false
private var gpuActive = false
private var gpuRing: UInt = 0
private var gpuCmd: UInt = 0
private var gpuResp: UInt = 0
private var gpuFb: UInt = 0
private var gpuFbBytes: UInt = 0
private var gpuW: UInt32 = 0
private var gpuH: UInt32 = 0
private var gpuAvailIdx: UInt16 = 0
private var gpuLastUsed: UInt16 = 0
private var gpuLock: UInt64 = 0

private func gpuClean(_ pa: UInt, _ n: UInt) {
    var a = pa & ~UInt(63)
    let end = pa + n
    while a < end { dc_cvac(a); a += 64 }
    dsb_sy()
}

private func gpuInvalidate(_ pa: UInt, _ n: UInt) {
    dsb_sy()
    var a = pa & ~UInt(63)
    let end = pa + n
    while a < end { dc_ivac(a); a += 64 }
    dsb_sy()
}

private func gpuZeroPage(_ pa: UInt) {
    let p = UnsafeMutableRawPointer(bitPattern: pa)!
    var i = 0
    while i < 4096 {
        p.storeBytes(of: UInt8(0), toByteOffset: i, as: UInt8.self)
        i += 1
    }
}

// --- command-buffer field stores (page-aligned buffer; all offsets natural) ---
private func cmd32(_ off: Int, _ v: UInt32) {
    UnsafeMutableRawPointer(bitPattern: gpuCmd)!.storeBytes(of: v, toByteOffset: off, as: UInt32.self)
}
private func cmd64(_ off: Int, _ v: UInt64) {
    UnsafeMutableRawPointer(bitPattern: gpuCmd)!.storeBytes(of: v, toByteOffset: off, as: UInt64.self)
}
private func respLoad32(_ off: Int) -> UInt32 {
    UnsafeRawPointer(bitPattern: gpuResp)!.load(fromByteOffset: off, as: UInt32.self)
}

// Lay down the 24-byte virtio_gpu_ctrl_hdr at the start of the command buffer.
private func cmdHeader(_ type: UInt32) {
    cmd32(0, type)        // type
    cmd32(4, 0)           // flags
    cmd64(8, 0)           // fence_id
    cmd32(16, 0)          // ctx_id
    cmd32(20, 0)          // padding
}

// --- descriptor ring ---
private func gpuDescSet(_ index: Int, _ addr: UInt64, _ len: UInt32, _ flags: UInt16, _ next: UInt16) {
    let d = UnsafeMutableRawPointer(bitPattern: gpuRing + OFF_DESC + UInt(index) * 16)!
    d.storeBytes(of: addr, toByteOffset: 0, as: UInt64.self)
    d.storeBytes(of: len, toByteOffset: 8, as: UInt32.self)
    d.storeBytes(of: flags, toByteOffset: 12, as: UInt16.self)
    d.storeBytes(of: next, toByteOffset: 14, as: UInt16.self)
}

private func gpuUsedIdx() -> UInt16 {
    UnsafeRawPointer(bitPattern: gpuRing + OFF_USED)!.load(fromByteOffset: 2, as: UInt16.self)
}

// Submit one command (request `cmdLen` bytes, device writes up to `respLen`
// bytes back) as a two-descriptor chain and poll the used ring. Returns the
// response header type, or 0 on timeout. Caller must hold gpuLock / IRQs masked.
// Generic over the transport so the doorbell/ack monomorphize for the bound kind.
private func gpuSubmit<T: VirtioTransportOps>(_ xport: T, _ cmdLen: UInt32,
                                              _ respLen: UInt32) -> UInt32 {
    gpuDescSet(0, UInt64(gpuCmd), cmdLen, VIRTQ_DESC_F_NEXT, 1)
    gpuDescSet(1, UInt64(gpuResp), respLen, VIRTQ_DESC_F_WRITE, 0)
    gpuClean(gpuRing + OFF_DESC, 32)
    gpuClean(gpuCmd, UInt(cmdLen))

    let avail = UnsafeMutableRawPointer(bitPattern: gpuRing + OFF_AVAIL)!
    avail.storeBytes(of: UInt16(0), toByteOffset: 4, as: UInt16.self)   // ring[0] = head desc 0
    gpuAvailIdx &+= 1
    avail.storeBytes(of: gpuAvailIdx, toByteOffset: 2, as: UInt16.self)
    gpuClean(gpuRing + OFF_AVAIL, 16)

    xport.notify(queue: 0)

    var spins = 0
    while true {
        gpuInvalidate(gpuRing + OFF_USED, 16)
        if gpuUsedIdx() != gpuLastUsed { break }
        spins += 1
        if spins >= GPU_SPIN_LIMIT { return 0 }
    }
    gpuLastUsed &+= 1
    xport.ackInterrupt()
    gpuInvalidate(gpuResp, UInt(respLen))
    return respLoad32(0)
}

// Generic bring-up: negotiate VERSION_1, set up the control queue, query the
// preferred resolution, and create+attach+scan out the guest framebuffer. Generic
// over the transport so the whole control plane monomorphizes for the discovered
// kind. Returns false on any failure (the caller leaves the GOP framebuffer in
// place); on success gpuW/gpuH/gpuFb are set and the scanout is live.
private func gpuBringUp<T: VirtioTransportOps>(_ xport: inout T) -> Bool {
    xport.reset()
    xport.setStatus(VIRTIO_STATUS_ACK)
    xport.setStatus(VIRTIO_STATUS_ACK | VIRTIO_STATUS_DRIVER)
    if !xport.negotiateVersion1() { return false }
    let da = UInt64(gpuRing + OFF_DESC), aa = UInt64(gpuRing + OFF_AVAIL), ua = UInt64(gpuRing + OFF_USED)
    if xport.setupQueue(0, requested: GPU_QSZ, desc: da, avail: aa, used: ua) == 0 { return false }
    xport.setStatus(VIRTIO_STATUS_ACK | VIRTIO_STATUS_DRIVER |
                    VIRTIO_STATUS_FEATURES_OK | VIRTIO_STATUS_DRIVER_OK)

    // Preferred resolution from the host, with a sane default and clamp.
    var w = DEFAULT_W, h = DEFAULT_H
    cmdHeader(CMD_GET_DISPLAY_INFO)
    if gpuSubmit(xport, 24, 408) == RESP_OK_DISPLAY_INFO {
        let pw = respLoad32(32), ph = respLoad32(36), enabled = respLoad32(40)
        if enabled != 0 && pw >= 64 && ph >= 64 && pw <= MAX_W && ph <= MAX_H { w = pw; h = ph }
    }
    gpuW = w; gpuH = h

    let bytes = UInt(w) * UInt(h) * 4
    let pages = Int((bytes + 4095) / 4096)
    gpuFb = pmm_alloc_pages(pages)
    if gpuFb == 0 { return false }
    gpuFbBytes = UInt(pages) * 4096

    // CREATE_2D
    cmdHeader(CMD_RESOURCE_CREATE_2D)
    cmd32(24, RESOURCE_ID); cmd32(28, FORMAT_B8G8R8X8_UNORM); cmd32(32, w); cmd32(36, h)
    if gpuSubmit(xport, 40, 24) != RESP_OK_NODATA { return false }

    // ATTACH_BACKING (one contiguous entry)
    cmdHeader(CMD_RESOURCE_ATTACH_BACKING)
    cmd32(24, RESOURCE_ID); cmd32(28, 1)
    cmd64(32, UInt64(gpuFb)); cmd32(40, UInt32(truncatingIfNeeded: bytes)); cmd32(44, 0)
    if gpuSubmit(xport, 48, 24) != RESP_OK_NODATA { return false }

    // SET_SCANOUT (display 0 → our resource, full rect)
    cmdHeader(CMD_SET_SCANOUT)
    cmd32(24, 0); cmd32(28, 0); cmd32(32, w); cmd32(36, h)
    cmd32(40, 0); cmd32(44, RESOURCE_ID)
    if gpuSubmit(xport, 48, 24) != RESP_OK_NODATA { return false }
    return true
}

// Bring up virtio-gpu and repoint the fb.swift console at a scanned-out guest
// framebuffer. Prefers virtio-mmio then virtio-pci (matching the other drivers).
// Returns false (leaving any existing GOP framebuffer in place) if there is no
// virtio-gpu device or any step fails.
func virtioGpuInit() -> Bool {
    gpuActive = false
    if gpuRing == 0 { gpuRing = pmm_alloc_page(); if gpuRing == 0 { return false } }
    if gpuCmd == 0 { gpuCmd = pmm_alloc_page(); if gpuCmd == 0 { return false } }
    if gpuResp == 0 { gpuResp = pmm_alloc_page(); if gpuResp == 0 { return false } }
    gpuZeroPage(gpuRing); gpuZeroPage(gpuCmd); gpuZeroPage(gpuResp)
    gpuAvailIdx = 0; gpuLastUsed = 0

    var brought = false
    var i: UInt32 = 0
    while i < platform.virtioMmioCount {
        let m = platform.virtioMmioBase + UInt(i) * platform.virtioMmioStride
        if mmio_read32(m + R_MAGIC) == VIRTIO_MAGIC && mmio_read32(m + R_DEVID) == VIRTIO_ID_GPU {
            var t = VirtioMmioTransport(m)
            if gpuBringUp(&t) { gpuMmioXport = t; gpuIsPci = false; brought = true }
            break
        }
        i += 1
    }
    if !brought, let dev = virtioPciFindDevice(deviceType: VIRTIO_ID_GPU) {
        var t = VirtioPciTransport(dev)
        if gpuBringUp(&t) { gpuPciXport = t; gpuIsPci = true; brought = true }
    }
    if !brought { return false }

    gpuActive = true
    // Repoint the text console at our backing (clears it), then push it once.
    fb_init(UInt64(gpuFb), gpuW, gpuH, gpuW)
    gpuConsoleFlush()
    klog(.info, "gpu", "virtio-gpu console scanout ready", UInt64(gpuW) << 16 | UInt64(gpuH))
    return true
}

func virtioGpuActive() -> Bool { gpuActive }

// Push the whole framebuffer to the host scanout. fb.swift already cleans each
// pixel write to PoC, so no extra clean is needed here — only the GPU transfer +
// flush that a virtio-gpu scanout requires. Guarded so the timer-driven blink
// path and a normal-context console write never drive the ring concurrently.
func gpuConsoleFlush() {
    if !gpuActive { return }
    // One branch to pick the bound transport, then a fully monomorphized flush.
    if gpuIsPci { gpuConsoleFlushOn(gpuPciXport) } else { gpuConsoleFlushOn(gpuMmioXport) }
}

private func gpuConsoleFlushOn<T: VirtioTransportOps>(_ xport: T) {
    var expected: UInt64 = 0
    if !smpAtomicCompareExchange(&gpuLock, expected: &expected, desired: 1) { return }
    let daif = irq_save()

    cmdHeader(CMD_TRANSFER_TO_HOST_2D)
    cmd32(24, 0); cmd32(28, 0); cmd32(32, gpuW); cmd32(36, gpuH)
    cmd64(40, 0); cmd32(48, RESOURCE_ID); cmd32(52, 0)
    _ = gpuSubmit(xport, 56, 24)

    cmdHeader(CMD_RESOURCE_FLUSH)
    cmd32(24, 0); cmd32(28, 0); cmd32(32, gpuW); cmd32(36, gpuH)
    cmd32(40, RESOURCE_ID); cmd32(44, 0)
    _ = gpuSubmit(xport, 48, 24)

    irq_restore(daif)
    smpAtomicStore(&gpuLock, 0)
}
