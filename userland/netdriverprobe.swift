// SPDX-License-Identifier: Apache-2.0
// netdriverprobe.swift — NS2 userland virtio-net driver probe (/bin/netdriverprobe).
//
// Proves an EL0 driver can do real TX/RX on a NIC without disturbing the primary
// kernel-owned NIC. It claims the SECONDARY virtio-net grant (virtio-net.1, present
// only when a second NIC is attached), brings up the device via the shared userland
// virtio-net driver core (virtio_net_user.swift), then performs an ARP round-trip
// against the slirp gateway — transmits an ARP request for 10.0.2.2 and receives
// slirp's ARP reply. On a single-NIC profile virtio-net.1 does not exist, so the
// claim fails and the probe exits 0; it never touches the live kernel NIC.

let ndpKindVirtioNet: UInt32 = 3
let ndpBusVirtioMmio: UInt32 = 2
let ndpFlagMmioGrant: UInt32 = 1 << 2
let ndpFlagIrqGrant: UInt32 = 1 << 3
let ndpFlagDmaGrant: UInt32 = 1 << 4

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
       info.kind != ndpKindVirtioNet || info.bus != ndpBusVirtioMmio ||
       info.mmio_base == 0 || info.mmio_len == 0 ||
       (info.flags & ndpFlagMmioGrant) == 0 ||
       (info.flags & (ndpFlagIrqGrant | ndpFlagDmaGrant)) != 0 {
        swiftos_puts("netdriverprobe: net grant not usable\n"); _ = swiftos_close(fd); return 1
    }
    let r = swiftos_device_mmap(fd, UInt(info.mmio_len))
    if r < 0 { swiftos_puts("netdriverprobe: device_mmap failed\n"); _ = swiftos_close(fd); return 1 }

    var drv = vnetInit(UInt(bitPattern: Int(r)), fd)
    if !drv.ok { swiftos_puts("netdriverprobe: virtio-net init failed\n"); _ = swiftos_close(fd); return 1 }

    swiftos_puts("NS2: userland virtio-net up on virtio-net.1, MAC ")
    for j in 0..<6 { if j != 0 { swiftos_putc(UInt8(ascii: ":")) }; vnHex2(drv.mac[j]) }
    swiftos_putc(UInt8(ascii: "\n"))

    return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 1600) { scratch -> Int32 in
        let arp = UInt(bitPattern: scratch.baseAddress!)
        let rx = arp + 64
        let arpLen = vnBuildArpRequest(arp, drv.mac)
        var attempt = 0
        while attempt < 20 {
            vnetTx(&drv, arp, arpLen)
            var spin = 0
            while spin < 20 {
                let n = vnetRxNext(&drv, rx, 1536)
                if n > 0 && vnIsGatewayArpReply(rx, n) {
                    swiftos_puts("NS2 OK: userland virtio-net TX/RX — ARP reply, 10.0.2.2 is at ")
                    for k in 0..<6 { if k != 0 { swiftos_putc(UInt8(ascii: ":")) }; vnHex2(vnB8(rx, 22 + k)) }
                    swiftos_putc(UInt8(ascii: "\n"))
                    _ = swiftos_close(fd)
                    return 0
                }
                if n == 0 { swiftos_nanosleep(0, 5_000_000); spin += 1 }
            }
            attempt += 1
        }
        swiftos_puts("netdriverprobe: no ARP reply received\n")
        _ = swiftos_close(fd)
        return 1
    }
}
