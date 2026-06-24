// SPDX-License-Identifier: Apache-2.0
// netsvc.swift — NS3 restartable userland net service (/bin/netsvc).
//
// Third step of network serviceization: a supervised, restartable userland service
// that OWNS a NIC (the secondary virtio-net.1) and relays frames over a shared-memory
// (shmring) data plane — the restartable-service shape for networking, the network
// analog of the C5 driver service. It maps a full-duplex shmring channel (id passed
// in argv by its supervisor), brings the NIC up via the shared userland virtio-net
// core, then loops:
//   * consume frames from ring0 (client -> service) and TRANSMIT them on the NIC;
//   * poll the NIC RX queue and PRODUCE received frames into ring1 (service ->
//     client) — zero kernel net stack involved.
// Control records (tag 0) carry "RDY" (announced once on startup) and "STP" (the
// supervisor's stop signal). Frame records (tag 1) carry a raw Ethernet frame.
//
// On a single-NIC profile virtio-net.1 does not exist, so the claim fails and the
// service exits 0 without touching the live kernel NIC.

let nsTagControl: UInt8 = 0
let nsTagFrame: UInt8 = 1
let nsRingHalf: UInt = 4096   // shmring_create(2) -> two 4 KiB ring regions

func nsParseInt(_ p: UnsafeMutablePointer<CChar>?) -> Int {
    guard let p = p else { return -1 }
    var v = 0, i = 0, any = false
    while true {
        let c = p[i]
        if c < 48 || c > 57 { break }
        v = v * 10 + Int(c - 48); i += 1; any = true
        if i > 9 { break }
    }
    return any ? v : -1
}

// Reserve a record on `ring` and write [tag][payload(len bytes from src)]; src==0
// for a control record whose payload is the literal bytes in `ctrl`.
func nsSendFrame(_ ring: UnsafeMutableRawPointer, _ tag: UInt8, _ src: UInt, _ len: Int) -> Bool {
    guard let dst = shmRingReserve(ring, UInt32(1 + len)) else { return false }
    dst.storeBytes(of: tag, as: UInt8.self)
    var k = 0
    while k < len {
        let b = UnsafeRawPointer(bitPattern: src + UInt(k))!.load(as: UInt8.self)
        (dst + 1 + k).storeBytes(of: b, as: UInt8.self); k += 1
    }
    shmRingCommit(ring, UInt32(1 + len))
    return true
}

func nsSendControl3(_ ring: UnsafeMutableRawPointer, _ a: UInt8, _ b: UInt8, _ c: UInt8) {
    if let dst = shmRingReserve(ring, 4) {
        dst.storeBytes(of: nsTagControl, as: UInt8.self)
        (dst + 1).storeBytes(of: a, as: UInt8.self); (dst + 2).storeBytes(of: b, as: UInt8.self); (dst + 3).storeBytes(of: c, as: UInt8.self)
        shmRingCommit(ring, 4)
    }
}

@_cdecl("main")
func main(_ argc: Int32,
         _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
         _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp
    guard argc >= 3, let argv = argv else { swiftos_puts("netsvc: missing args\n"); return 1 }
    let id = nsParseInt(argv[1])
    let gen = nsParseInt(argv[2])
    if id < 0 || gen < 1 || gen > 9 { swiftos_puts("netsvc: bad args\n"); return 1 }

    var info = swiftos_device_info()
    let fd = swiftos_device_claim("virtio-net.1", &info)
    if fd < 0 { swiftos_puts("netsvc: no secondary virtio-net device; exiting\n"); return 0 }
    let r = swiftos_device_mmap(fd, UInt(info.mmio_len))
    if r < 0 { swiftos_puts("netsvc: device_mmap failed\n"); _ = swiftos_close(fd); return 1 }
    var drv = vnetInit(UInt(bitPattern: Int(r)), fd)
    if !drv.ok { swiftos_puts("netsvc: virtio-net init failed\n"); _ = swiftos_close(fd); return 1 }

    let baseRaw = swiftos_shmring_map(Int32(id))
    if baseRaw <= 0 {
        swiftos_puts("netsvc: shmring map failed\n"); _ = swiftos_close(fd); return 1
    }
    let base = UInt(bitPattern: baseRaw)
    let ring0 = UnsafeMutableRawPointer(bitPattern: base)!              // client -> service
    let ring1 = UnsafeMutableRawPointer(bitPattern: base + nsRingHalf)! // service -> client

    swiftos_puts("netsvc: ready gen ")
    swiftos_putc(UInt8(ascii: "0") + UInt8(gen)); swiftos_putc(UInt8(ascii: "\n"))
    nsSendControl3(ring1, UInt8(ascii: "R"), UInt8(ascii: "D"), UInt8(ascii: "Y")) // announce readiness

    return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 2048) { scratch -> Int32 in
        let buf = UInt(bitPattern: scratch.baseAddress!)
        while true {
            // Drain one client request from ring0.
            var len: UInt32 = 0
            if let src = shmRingPeek(ring0, &len), len >= 1 {
                let tag = src.load(as: UInt8.self)
                if tag == nsTagControl {
                    shmRingRelease(ring0)
                    _ = swiftos_close(fd)
                    return Int32(40 + gen) // STP: stop, exit 40+gen
                }
                // tag == frame: copy payload out, release, then transmit.
                let n = Int(len) - 1
                var k = 0
                while k < n && k < 2048 {
                    (UnsafeMutableRawPointer(bitPattern: buf + UInt(k))!).storeBytes(
                        of: (src + 1 + k).load(as: UInt8.self), as: UInt8.self); k += 1
                }
                shmRingRelease(ring0)
                vnetTx(&drv, buf, n)
            }
            // Forward one received frame to the client over ring1.
            let rn = vnetRxNext(&drv, buf, 1536)
            if rn > 0 { _ = nsSendFrame(ring1, nsTagFrame, buf, rn) }
            swiftos_nanosleep(0, 2_000_000) // 2 ms
        }
    }
}
