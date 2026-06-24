// SPDX-License-Identifier: Apache-2.0
// netsvc-demo.swift — NS3 supervisor + client for the restartable userland net
// service (/bin/netsvc-demo). It is the boot self-test that drives /bin/netsvc the
// way svc-supervisor drives svc-input, but over an shmring data plane:
//   * it owns a full-duplex shmring channel (SYS_shmring_create, capNet);
//   * for two generations it spawns netsvc (passing the channel id), waits for the
//     service's RDY, then hands it an ARP request FRAME over ring0; the service
//     transmits it on the secondary NIC and forwards slirp's reply FRAME back over
//     ring1, which the client verifies; then it stops the service and reaps it;
//   * gen 2 proves a kill+restart recovers the service over the same data plane.
// The frame never touches the kernel net stack — it crosses the shmring zero-copy
// and the NIC is driven entirely from EL0.
//
// On a single-NIC profile virtio-net.1 does not exist; the demo detects that up
// front (the existence probe fails) and exits 0 without spawning anything.

let dTagControl: UInt8 = 0
let dTagFrame: UInt8 = 1
let dRingHalf: UInt = 4096

let dRightWrite: UInt32 = 1 << 1

func dPutInt(_ v: Int, _ dst: UnsafeMutablePointer<CChar>) -> Int {
    if v == 0 { dst[0] = CChar(bitPattern: UInt8(ascii: "0")); dst[1] = 0; return 1 }
    var tmp = [UInt8](repeating: 0, count: 12); var n = 0; var x = v
    while x > 0 && n < 11 { tmp[n] = UInt8(ascii: "0") + UInt8(x % 10); x /= 10; n += 1 }
    for i in 0..<n { dst[i] = CChar(bitPattern: tmp[n - 1 - i]) }
    dst[n] = 0; return n
}

// Read the secondary NIC's MAC (read-only) so the ARP request carries the correct
// sender hardware address; also confirms the device exists. Returns false if there
// is no secondary NIC. Leaves the device released for netsvc to claim.
func dProbeMac(_ mac: inout [UInt8]) -> Bool {
    var info = swiftos_device_info()
    let fd = swiftos_device_claim("virtio-net.1", &info)
    if fd < 0 { return false }
    let r = swiftos_device_mmap(fd, UInt(info.mmio_len))
    if r < 0 { _ = swiftos_close(fd); return false }
    let base = UInt(bitPattern: Int(r))
    let ok = swiftos_mmio_read32(base + 0x00) == 0x74726976 && swiftos_mmio_read32(base + 0x08) == 1
    if ok {
        let lo = swiftos_mmio_read32(base + 0x100), hi = swiftos_mmio_read32(base + 0x104)
        mac[0] = UInt8(lo & 0xff); mac[1] = UInt8((lo >> 8) & 0xff)
        mac[2] = UInt8((lo >> 16) & 0xff); mac[3] = UInt8((lo >> 24) & 0xff)
        mac[4] = UInt8(hi & 0xff); mac[5] = UInt8((hi >> 8) & 0xff)
    }
    let page = base & ~UInt(0xfff)
    _ = swiftos_munmap(page, (base & 0xfff) + info.mmio_len)
    _ = swiftos_close(fd)
    return ok
}

func dSpawnNetsvc(_ id: Int, _ gen: Int) -> Int {
    return withUnsafeTemporaryAllocation(of: CChar.self, capacity: 48) { strs -> Int in
        let prog = strs.baseAddress!
        let p: StaticString = "netsvc"
        var o = 0
        p.withUTF8Buffer { b in for i in 0..<b.count { prog[i] = CChar(bitPattern: b[i]) }; o = b.count }
        prog[o] = 0
        let idStr = prog + (o + 1)
        let idLen = dPutInt(id, idStr)
        let genStr = idStr + (idLen + 1)
        _ = dPutInt(gen, genStr)
        return withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<CChar>?.self, capacity: 4) { argv -> Int in
            argv[0] = prog; argv[1] = idStr; argv[2] = genStr; argv[3] = nil
            return withUnsafeTemporaryAllocation(byteCount: 32, alignment: 4) { specs -> Int in
                let sp = specs.baseAddress!
                func put(_ i: Int, _ src: Int32, _ dst: Int32, _ rights: UInt32) {
                    let b = i * 16
                    sp.storeBytes(of: src, toByteOffset: b + 0, as: Int32.self)
                    sp.storeBytes(of: dst, toByteOffset: b + 4, as: Int32.self)
                    sp.storeBytes(of: rights, toByteOffset: b + 8, as: UInt32.self)
                    sp.storeBytes(of: UInt32(0), toByteOffset: b + 12, as: UInt32.self)
                }
                put(0, 1, 1, dRightWrite)  // stdout
                put(1, 2, 2, dRightWrite)  // stderr
                return Int(swiftos_spawn_handles_async("/bin/netsvc",
                            UnsafeMutableRawPointer(argv.baseAddress!), sp, 2))
            }
        }
    }
}

// Wait (bounded) for a control record (tag 0) on `ring`. Returns true if seen.
func dWaitControl(_ ring: UnsafeMutableRawPointer) -> Bool {
    var spin = 0
    while spin < 400 { // ~2 s
        var len: UInt32 = 0
        if let src = shmRingPeek(ring, &len), len >= 1, src.load(as: UInt8.self) == dTagControl {
            shmRingRelease(ring); return true
        } else if len >= 1 { shmRingRelease(ring) }
        swiftos_nanosleep(0, 5_000_000); spin += 1
    }
    return false
}

// Wait (bounded) for a frame record (tag 1) that is the gateway ARP reply.
func dWaitArpReply(_ ring: UnsafeMutableRawPointer, _ outMac: inout [UInt8]) -> Bool {
    var spin = 0
    while spin < 400 {
        var len: UInt32 = 0
        if let src = shmRingPeek(ring, &len), len >= 1 {
            let p = UInt(bitPattern: src)
            if src.load(as: UInt8.self) == dTagFrame && vnIsGatewayArpReply(p + 1, Int(len) - 1) {
                for k in 0..<6 { outMac[k] = vnB8(p + 1, 22 + k) }
                shmRingRelease(ring); return true
            }
            shmRingRelease(ring)
        }
        swiftos_nanosleep(0, 5_000_000); spin += 1
    }
    return false
}

func dSendArp(_ ring: UnsafeMutableRawPointer, _ mac: [UInt8]) -> Bool {
    guard let dst = shmRingReserve(ring, 1 + 42) else { return false }
    dst.storeBytes(of: dTagFrame, as: UInt8.self)
    _ = vnBuildArpRequest(UInt(bitPattern: dst) + 1, mac)
    shmRingCommit(ring, 1 + 42)
    return true
}

func dSendStop(_ ring: UnsafeMutableRawPointer) {
    if let dst = shmRingReserve(ring, 4) {
        dst.storeBytes(of: dTagControl, as: UInt8.self)
        (dst + 1).storeBytes(of: UInt8(ascii: "S"), as: UInt8.self)
        (dst + 2).storeBytes(of: UInt8(ascii: "T"), as: UInt8.self)
        (dst + 3).storeBytes(of: UInt8(ascii: "P"), as: UInt8.self)
        shmRingCommit(ring, 4)
    }
}

func dWaitExit(_ pid: Int32) -> Int32 {
    var status: Int32 = 0
    let w = withUnsafeMutablePointer(to: &status) { swiftos_waitpid(pid, $0) }
    if w != pid { return -1 }
    return (status >> 8) & 0xff
}

func dRunGeneration(_ id: Int, _ gen: Int, _ ring0: UnsafeMutableRawPointer,
                    _ ring1: UnsafeMutableRawPointer, _ mac: [UInt8]) -> Bool {
    let pid = dSpawnNetsvc(id, gen)
    if pid < 0 { swiftos_puts("netsvc-demo: spawn failed\n"); return false }
    if !dWaitControl(ring1) { swiftos_puts("netsvc-demo: service not ready\n"); return false }
    if !dSendArp(ring0, mac) { swiftos_puts("netsvc-demo: arp send failed\n"); return false }
    var replyMac = [UInt8](repeating: 0, count: 6)
    if !dWaitArpReply(ring1, &replyMac) { swiftos_puts("netsvc-demo: no arp reply over shmring\n"); return false }
    swiftos_puts("netsvc-demo: gen ")
    swiftos_putc(UInt8(ascii: "0") + UInt8(gen))
    swiftos_puts(" relayed ARP reply, 10.0.2.2 is at ")
    for k in 0..<6 { if k != 0 { swiftos_putc(UInt8(ascii: ":")) }; vnHex2(replyMac[k]) }
    swiftos_putc(UInt8(ascii: "\n"))
    dSendStop(ring0)
    let code = dWaitExit(Int32(pid))
    if code != Int32(40 + gen) { swiftos_puts("netsvc-demo: service exit mismatch\n"); return false }
    return true
}

@_cdecl("main")
func main(_ argc: Int32,
         _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
         _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp

    var mac = [UInt8](repeating: 0, count: 6)
    if !dProbeMac(&mac) {
        swiftos_puts("netsvc-demo: no secondary virtio-net device; skipping\n")
        return 0
    }

    let id = Int(swiftos_shmring_create(2))   // two 4 KiB ring regions
    if id < 0 { swiftos_puts("netsvc-demo: shmring create failed\n"); return 1 }
    let baseRaw = swiftos_shmring_map(Int32(id))
    if baseRaw <= 0 { swiftos_puts("netsvc-demo: shmring map failed\n"); return 1 }
    let base = UInt(bitPattern: baseRaw)
    let ring0 = UnsafeMutableRawPointer(bitPattern: base)!
    let ring1 = UnsafeMutableRawPointer(bitPattern: base + dRingHalf)!

    var gen = 1
    while gen <= 2 {
        if !dRunGeneration(id, gen, ring0, ring1, mac) {
            _ = swiftos_shmring_close(Int32(id))
            return 1
        }
        if gen == 1 { swiftos_puts("netsvc-demo: service stopped; restarting next generation\n") }
        gen += 1
    }

    _ = swiftos_shmring_close(Int32(id))
    swiftos_puts("NS3 OK: restartable userland net service relayed frames over shmring\n")
    return 0
}
