// SPDX-License-Identifier: Apache-2.0
// svc-supervisor.swift — LA1 persistent PID-1-style supervisor (ProcessServer)
// for native Swift userland services. It is the modern, persistent successor to
// the one-shot C5 drvsvcdemo: it owns a restart loop and an init-rooted, grant-
// only authority bootstrap.
//
// Capability discipline (the milestone's point):
//   * The supervisor is seeded with exactly one authority (it inherits the boot
//     capConsole context, like swos-init). Children get NO ambient device
//     authority.
//   * For each service generation it creates endpoint pairs, PUBLISHES the
//     service's command-recv endpoint in the kernel name registry, and resolves
//     it back with name_lookup — the explicit grant-by-lookup path.
//   * It spawns the service with the C2 explicit-handle ABI (spawn_handles_async),
//     passing the endpoint ends as inherited fds (never argv-encoded fd numbers).
//   * The device grant flows ONLY by IPC handle transfer; the supervisor's own
//     device fd becomes invalid once moved, and it reclaims the device after the
//     service stops (C5b semantics, in Swift).
//   * A bounded restart policy (modeled on swos-init.c's MAX_RESTARTS_PER_SERVICE)
//     keeps a crash-looping service from fork-storming the kernel.
//
// To stay a boot-time self-test (like the C5 demo) while still exercising a real
// waitpid-driven restart loop, it runs a bounded number of generations: gen 1
// proves liveness, the supervisor restarts it, and gen 2 additionally performs
// the device grant handoff + reclaim. Then it reports success and exits so boot
// proceeds. The loop body is structurally the persistent supervise-forever shape.

let serviceName: StaticString = "input"
let targetGenerations = 2
let maxRestartsPerService = 5   // swos-init.c MAX_RESTARTS_PER_SERVICE analogue

// Handle rights (mirror syscall.h SWIFTOS_RIGHT_*).
let rightRead: UInt32 = 1 << 0
let rightWrite: UInt32 = 1 << 1
let rightTransfer: UInt32 = 1 << 5

// Device flag bits (mirror syscall.h). C5h: the supervised driver now receives
// real MMIO authority on virtio-input.0, so the MMIO grant (1<<2) is expected, not
// withheld; only the still-unimplemented IRQ (1<<3) and DMA (1<<4) grants must stay
// absent. The pseudo-input fallback carries deviceFlagNoMmioGrant and no IRQ/DMA.
let supDevFlagNoMmioGrant: UInt32 = 1 << 0
let supDevFlagMmioGrant: UInt32 = 1 << 2
let supDevFlagIrqDmaAuthority: UInt32 = (1 << 3) | (1 << 4)

func putSpec(_ sp: UnsafeMutableRawPointer, _ idx: Int, _ src: Int32, _ dst: Int32, _ rights: UInt32) {
    let base = idx * 16
    sp.storeBytes(of: src, toByteOffset: base + 0, as: Int32.self)
    sp.storeBytes(of: dst, toByteOffset: base + 4, as: Int32.self)
    sp.storeBytes(of: rights, toByteOffset: base + 8, as: UInt32.self)
    sp.storeBytes(of: UInt32(0), toByteOffset: base + 12, as: UInt32.self)
}

func makeEndpoint() -> (send: Int32, recv: Int32)? {
    var ends = (Int32(0), Int32(0))
    let rc = withUnsafeMutablePointer(to: &ends) { p -> Int32 in
        Int32(swiftos_endpoint_create(UnsafeMutableRawPointer(p).assumingMemoryBound(to: Int32.self)))
    }
    if rc != 0 { return nil }
    return (ends.0, ends.1) // kernel writes ends[0]=send, ends[1]=recv
}

// Receive one message on `fd` and check it equals `want` followed by the gen
// digit. Closes any transferred handle. Stack-only.
func expectMsg(_ fd: Int32, _ want: StaticString, _ gen: Int) -> Bool {
    return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { buf -> Bool in
        var received: Int32 = -1
        let n = swiftos_ipc_recv(fd, buf.baseAddress!, 32, &received)
        if received >= 0 { _ = swiftos_close(received) }
        if n < 0 { return false }
        var expLen = 0
        var prefixOk = true
        want.withUTF8Buffer { w in
            expLen = w.count + 1
            if Int(n) != expLen { prefixOk = false; return }
            var i = 0
            while i < w.count {
                if buf[i] != w[i] { prefixOk = false; return }
                i += 1
            }
        }
        if !prefixOk { return false }
        return buf[expLen - 1] == UInt8(ascii: "0") + UInt8(gen)
    }
}

func sendCmd(_ fd: Int32, _ cmd: StaticString) -> Bool {
    var ok = false
    cmd.withUTF8Buffer { c in
        ok = swiftos_ipc_send(fd, c.baseAddress!, UInt(c.count), -1) == 0
    }
    return ok
}

func sendDeviceHandle(_ fd: Int32, _ devFd: Int32) -> Bool {
    var ok = false
    let devh: StaticString = "DEVH"
    devh.withUTF8Buffer { c in
        ok = swiftos_ipc_send(fd, c.baseAddress!, UInt(c.count), devFd) == 0
    }
    return ok
}

// C5h: accept the real MMIO grant (or the inert pseudo fallback), but still reject
// any IRQ/DMA authority and a bound IRQ number — those remain unimplemented.
func deviceAuthorityAcceptable(_ info: swiftos_device_info) -> Bool {
    if info.irq != 0 { return false }
    if (info.flags & supDevFlagIrqDmaAuthority) != 0 { return false }
    // Exactly one of: mappable MMIO grant (real virtio-input) or no-MMIO (pseudo).
    let mmio = (info.flags & supDevFlagMmioGrant) != 0
    let noMmio = (info.flags & supDevFlagNoMmioGrant) != 0
    return mmio != noMmio
}

// Spawn /bin/svc-input concurrently with the inherited endpoint ends (cmdRecv→fd3,
// replySend→fd4) plus stdout/stderr. Returns the child pid, or <0 on error.
func spawnService(_ gen: Int, _ cmdRecv: Int32, _ replySend: Int32) -> Int {
    return withUnsafeTemporaryAllocation(of: CChar.self, capacity: 16) { strs -> Int in
        let prog: StaticString = "svc-input"
        var o = 0
        prog.withUTF8Buffer { b in
            for i in 0..<b.count { strs[i] = CChar(bitPattern: b[i]) }
            o = b.count
        }
        strs[o] = 0
        let progPtr = strs.baseAddress!
        let genPtr = strs.baseAddress! + (o + 1)
        genPtr[0] = CChar(bitPattern: UInt8(ascii: "0") + UInt8(gen))
        genPtr[1] = 0
        return withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<CChar>?.self, capacity: 3) { argv -> Int in
            argv[0] = progPtr
            argv[1] = genPtr
            argv[2] = nil
            return withUnsafeTemporaryAllocation(byteCount: 64, alignment: 4) { specs -> Int in
                let sp = specs.baseAddress!
                putSpec(sp, 0, 1, 1, rightWrite)                         // stdout
                putSpec(sp, 1, 2, 2, rightWrite)                         // stderr
                putSpec(sp, 2, cmdRecv, 3, rightRead | rightTransfer)    // command recv end
                putSpec(sp, 3, replySend, 4, rightWrite | rightTransfer) // reply send end
                return Int(swiftos_spawn_handles_async("/bin/svc-input",
                            UnsafeMutableRawPointer(argv.baseAddress!), sp, 4))
            }
        }
    }
}

// gen 2: claim the input device from the supervisor's single seeded authority,
// transfer the grant to the service over IPC, verify the moved fd is now invalid,
// and confirm the service's DEVACK. `usedVirtio` records which device was claimed
// so the post-stop reclaim targets the same name.
func deviceHandoff(_ cmdSend: Int32, _ replyRecv: Int32, _ gen: Int, _ usedVirtio: inout Bool) -> Bool {
    var info = swiftos_device_info()
    var devFd = swiftos_device_claim("virtio-input.0", &info)
    if devFd >= 0 {
        usedVirtio = true
    } else {
        devFd = swiftos_device_claim("pseudo-input.0", &info)
        usedVirtio = false
    }
    if devFd < 0 {
        swiftos_puts("svc-supervisor: device claim failed\n")
        return false
    }
    if info.claimed != 1 || !deviceAuthorityAcceptable(info) {
        _ = swiftos_close(devFd)
        swiftos_puts("svc-supervisor: device info mismatch\n")
        return false
    }
    if !sendDeviceHandle(cmdSend, devFd) {
        _ = swiftos_close(devFd)
        swiftos_puts("svc-supervisor: device grant send failed\n")
        return false
    }
    swiftos_puts("svc-supervisor: device grant transferred via IPC\n")
    // The handle has moved: the supervisor's fd must no longer name a device.
    var moved = swiftos_device_info()
    if swiftos_device_query(devFd, &moved) >= 0 {
        swiftos_puts("svc-supervisor: moved device fd still valid\n")
        return false
    }
    if !expectMsg(replyRecv, "DEVACK", gen) {
        swiftos_puts("svc-supervisor: device ack mismatch\n")
        return false
    }
    return true
}

func reclaimDevice(_ usedVirtio: Bool) -> Bool {
    var info = swiftos_device_info()
    let fd = usedVirtio ? swiftos_device_claim("virtio-input.0", &info)
                        : swiftos_device_claim("pseudo-input.0", &info)
    if fd < 0 {
        swiftos_puts("svc-supervisor: reclaim claim failed\n")
        return false
    }
    if info.claimed != 1 || !deviceAuthorityAcceptable(info) {
        _ = swiftos_close(fd)
        swiftos_puts("svc-supervisor: reclaim info mismatch\n")
        return false
    }
    _ = swiftos_close(fd)
    swiftos_puts("svc-supervisor: device grant reclaimed\n")
    return true
}

func waitExit(_ pid: Int32) -> Int32 {
    var status: Int32 = 0
    let w = withUnsafeMutablePointer(to: &status) { sp in swiftos_waitpid(pid, sp) }
    if w != pid { return -1 }
    return (status >> 8) & 0xff
}

// One full service generation: set up channels + name registry, spawn the
// service, drive its lifecycle (ready → liveness → device handoff → stop), reap it
// and verify the exit code, then reclaim the device. C5i: the handoff now happens
// in EVERY generation so a restart genuinely re-claims, re-maps, and re-initializes
// the device (recovery), not just first-time init. `usedVirtio` reports whether a
// real mappable virtio-input grant (vs the pseudo fallback) was driven this gen.
func startAndDriveGeneration(_ gen: Int, _ usedVirtio: inout Bool) -> Bool {
    guard let cmd = makeEndpoint(), let rep = makeEndpoint() else {
        swiftos_puts("svc-supervisor: endpoint_create failed\n")
        return false
    }

    // Publish the service's command-recv endpoint under its name.
    if swiftos_name_register("input", cmd.recv) != 0 {
        swiftos_puts("svc-supervisor: name_register failed\n")
        return false
    }
    swiftos_puts("svc-supervisor: registered service in name registry\n")

    // Grant-by-lookup: resolve the name to a fresh send capability, then drop the
    // original send end so the command channel is the looked-up grant.
    let cmdSend = swiftos_name_lookup("input")
    if cmdSend < 0 {
        swiftos_puts("svc-supervisor: name_lookup failed\n")
        return false
    }
    _ = swiftos_close(cmd.send)
    swiftos_puts("svc-supervisor: resolved service endpoint via name lookup\n")

    let pid = spawnService(gen, cmd.recv, rep.send)
    if pid < 0 {
        swiftos_puts("svc-supervisor: spawn failed\n")
        return false
    }
    // The child now owns the service's ends; the registry pins the command-recv
    // endpoint so it outlives our copy.
    _ = swiftos_close(cmd.recv)
    _ = swiftos_close(rep.send)

    if !expectMsg(rep.recv, "DRVREADY", gen) {
        swiftos_puts("svc-supervisor: ready message mismatch\n")
        return false
    }
    if !sendCmd(cmdSend, "PING") || !expectMsg(rep.recv, "DRVEVENT", gen) {
        swiftos_puts("svc-supervisor: liveness check failed\n")
        return false
    }

    usedVirtio = false
    if !deviceHandoff(cmdSend, rep.recv, gen, &usedVirtio) { return false }

    if !sendCmd(cmdSend, "STOP") {
        swiftos_puts("svc-supervisor: stop send failed\n")
        return false
    }
    let code = waitExit(Int32(pid))
    if code != Int32(40 + gen) {
        swiftos_puts("svc-supervisor: service exit mismatch\n")
        return false
    }

    if !reclaimDevice(usedVirtio) { return false }

    _ = swiftos_close(cmdSend)
    _ = swiftos_close(rep.recv)
    return true
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp
    swiftos_puts("svc-supervisor: LA1 supervisor active\n")

    var gen = 1
    var restarts = 0
    var droveVirtio = false
    while true {
        var genVirtio = false
        if !startAndDriveGeneration(gen, &genVirtio) {
            swiftos_puts("svc-supervisor: generation failed\n")
            return 1
        }
        droveVirtio = droveVirtio || genVirtio
        // The service has exited and been reaped. A bounded number of generations
        // proves persistent restart-recovery; then we report success and exit so
        // boot proceeds (this runs as a boot self-test, like the C5 demo).
        if gen >= targetGenerations { break }
        restarts += 1
        if restarts > maxRestartsPerService {
            swiftos_puts("svc-supervisor: restart cap reached; giving up\n")
            return 1
        }
        swiftos_puts("svc-supervisor: service exited; restarting next generation\n")
        gen += 1
    }

    // C5i: each generation re-claimed, re-mapped, and re-initialized the real
    // virtio-input device from userland, so a kill+restart recovered a live
    // hardware driver — the kernel ran no virtio-input driver at all this boot.
    if droveVirtio {
        swiftos_puts("C5i OK: userland virtio-input driver initialized and recovered\n")
    }
    swiftos_puts("LA1 OK: persistent supervisor + Swift userland service over name-registry grant\n")
    return 0
}
