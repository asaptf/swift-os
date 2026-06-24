// SPDX-License-Identifier: Apache-2.0
// netmmapprobe.swift — NS1 network-serviceization probe (/bin/netmmapprobe).
//
// First step of moving the network stack toward a restartable userland service:
// prove the NIC's MMIO authority can reach userland the same way the virtio-input
// grant did (C5h), WITHOUT disturbing the in-kernel net driver that keeps owning
// the NIC (sshd/nginx/DHCP depend on it). Run at boot as a capConsole principal, it
// claims the mappable `virtio-net.0` grant, sys_device_mmap's the transport window,
// and reads the read-only identity registers (MagicValue/DeviceID) plus the
// device-config MAC address through the mapping. Reading these registers does not
// change device state, so it is safe alongside the live kernel NIC.
//
// On a board with no virtio-net window the claim fails and the probe exits 0 (a
// no-op), so it is harmless on headless/test profiles without a NIC.

// Device kind/bus/flag bits (mirror swift_user.h).
let nsDevKindVirtioNet: UInt32 = 3
let nsDevBusVirtioMmio: UInt32 = 2
let nsDevFlagMmioGrant: UInt32 = 1 << 2
let nsDevFlagIrqGrant: UInt32 = 1 << 3
let nsDevFlagDmaGrant: UInt32 = 1 << 4

// virtio-mmio registers + config space (config-space base is 0x100 on v2; the
// virtio_net_config.mac[6] field is at config offset 0).
let nsR_MAGIC: UInt  = 0x000
let nsR_DEVID: UInt  = 0x008
let nsR_CONFIG: UInt = 0x100
let nsMagic: UInt32 = 0x74726976   // "virt"
let nsDevIdNet: UInt32 = 1

func nsValidNetGrant(_ info: swiftos_device_info) -> Bool {
    // NS1: the NIC grant is mappable but claimed by name (not discoverable), so we
    // require the MMIO grant and absence of IRQ/DMA authority, not the discovered bit.
    return info.claimed == 1 &&
           info.irq == 0 &&
           info.kind == nsDevKindVirtioNet &&
           info.bus == nsDevBusVirtioMmio &&
           info.mmio_base != 0 && info.mmio_len != 0 &&
           (info.flags & nsDevFlagMmioGrant) != 0 &&
           (info.flags & (nsDevFlagIrqGrant | nsDevFlagDmaGrant)) == 0
}

// Print a byte as two lowercase hex digits.
func nsPutHex2(_ b: UInt8) {
    let hi = b >> 4, lo = b & 0xf
    swiftos_putc(hi < 10 ? UInt8(ascii: "0") + hi : UInt8(ascii: "a") + (hi - 10))
    swiftos_putc(lo < 10 ? UInt8(ascii: "0") + lo : UInt8(ascii: "a") + (lo - 10))
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp

    var info = swiftos_device_info()
    let fd = swiftos_device_claim("virtio-net.0", &info)
    if fd < 0 {
        swiftos_puts("netmmapprobe: no virtio-net device; nothing to probe\n")
        return 0
    }
    if !nsValidNetGrant(info) {
        swiftos_puts("netmmapprobe: net grant not usable\n")
        _ = swiftos_close(fd)
        return 1
    }

    let r = swiftos_device_mmap(fd, UInt(info.mmio_len))
    if r < 0 {
        swiftos_puts("netmmapprobe: device_mmap failed\n")
        _ = swiftos_close(fd)
        return 1
    }
    let base = UInt(bitPattern: Int(r))
    let magic = swiftos_mmio_read32(base + nsR_MAGIC)
    let devid = swiftos_mmio_read32(base + nsR_DEVID)
    if magic != nsMagic {
        swiftos_puts("netmmapprobe: MMIO magic mismatch\n")
        _ = swiftos_close(fd)
        return 1
    }
    if devid != nsDevIdNet {
        swiftos_puts("netmmapprobe: MMIO device-id mismatch\n")
        _ = swiftos_close(fd)
        return 1
    }

    // Read the 6-byte MAC from device config space (proves device-specific config
    // registers are reachable from userland, not just the generic identity words).
    let lo = swiftos_mmio_read32(base + nsR_CONFIG + 0)
    let hi = swiftos_mmio_read32(base + nsR_CONFIG + 4)
    var mac = [UInt8](repeating: 0, count: 6)
    mac[0] = UInt8(lo & 0xff); mac[1] = UInt8((lo >> 8) & 0xff)
    mac[2] = UInt8((lo >> 16) & 0xff); mac[3] = UInt8((lo >> 24) & 0xff)
    mac[4] = UInt8(hi & 0xff); mac[5] = UInt8((hi >> 8) & 0xff)

    swiftos_puts("NS1 OK: virtio-net MMIO mapped from userland, MAC ")
    for i in 0..<6 {
        if i != 0 { swiftos_putc(UInt8(ascii: ":")) }
        nsPutHex2(mac[i])
    }
    swiftos_puts(", DEVID verified\n")

    // Tear down: munmap reclaims the device VA (no PMM free), closing releases the
    // grant — the kernel NIC is untouched throughout.
    let pageBase = base & ~UInt(0xfff)
    let span = (base & 0xfff) + info.mmio_len
    _ = swiftos_munmap(pageBase, span)
    _ = swiftos_close(fd)
    return 0
}
