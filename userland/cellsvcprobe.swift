// SPDX-License-Identifier: Apache-2.0
// cellsvcprobe.swift — C6e end-to-end "one service per cell" supervisor probe.
//
// The payoff of the C6 arc: a small cell supervisor (capConsole boot principal)
// assembles a cell = { a namespace root view + a restricted handle set + a resource
// cap }, launches a real request/reply service (/bin/cellhello) inside it, drives a
// live round-trip over the granted endpoints, confirms the service is isolated
// (confined namespace + only the granted handles, proved by the service itself) and
// accounted (cell_stat charges it to the cell), then tears it down cleanly and
// reclaims the domain. This is the "one model server per cell" shape from
// CAPABILITIES.md, exercised end to end.

private let rightRead: UInt32 = 1 << 0
private let rightWrite: UInt32 = 1 << 1
private let rightTransfer: UInt32 = 1 << 5

private func putUInt(_ value: UInt) {
    if value == 0 { swiftos_putc(0x30); return }
    var digits = [UInt8](repeating: 0, count: 20)
    var n = value
    var count = 0
    while n > 0 { digits[count] = UInt8(0x30 + Int(n % 10)); n /= 10; count += 1 }
    while count > 0 { count -= 1; swiftos_putc(digits[count]) }
}

private func processesIn(_ cellRaw: UInt32) -> Int {
    var s = swiftos_cell_stat()
    _ = swiftos_cell_query(cellRaw, &s)
    return Int(s.processes)
}

private func makeEndpoint() -> (send: Int32, recv: Int32)? {
    var ends = (Int32(0), Int32(0))
    let rc = withUnsafeMutablePointer(to: &ends) { p -> Int32 in
        Int32(swiftos_endpoint_create(UnsafeMutableRawPointer(p).assumingMemoryBound(to: Int32.self)))
    }
    if rc != 0 { return nil }
    return (ends.0, ends.1) // kernel writes ends[0]=send, ends[1]=recv
}

private func sendCmd(_ fd: Int32, _ cmd: StaticString) -> Bool {
    var ok = false
    cmd.withUTF8Buffer { c in ok = swiftos_ipc_send(fd, c.baseAddress!, UInt(c.count), -1) == 0 }
    return ok
}

private func recvIs(_ fd: Int32, _ want: StaticString) -> Bool {
    return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { buf -> Bool in
        var handle: Int32 = -1
        let n = swiftos_ipc_recv(fd, buf.baseAddress!, 32, &handle)
        if handle >= 0 { _ = swiftos_close(handle) }
        if n < 0 { return false }
        var ok = true
        want.withUTF8Buffer { w in
            if Int(n) != w.count { ok = false; return }
            var i = 0
            while i < w.count { if buf[i] != w[i] { ok = false; return }; i += 1 }
        }
        return ok
    }
}

// Launch /bin/cellhello into `cellFd` with exactly the granted handles: stdout
// (fd 1), the command recv end (fd 3), and the reply send end (fd 4).
private func spawnServiceIntoCell(cellFd: Int32, cmdRecv: Int32, replySend: Int32) -> Int {
    return withUnsafeTemporaryAllocation(of: CChar.self, capacity: 16) { nameBuf -> Int in
        let name = nameBuf.baseAddress!
        var i = 0
        for c in "cellhello".utf8 { name[i] = CChar(bitPattern: c); i += 1 }
        name[i] = 0
        return withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<CChar>?.self, capacity: 2) { argv -> Int in
            argv[0] = name; argv[1] = nil
            return withUnsafeTemporaryAllocation(byteCount: 48, alignment: 4) { specs -> Int in
                let sp = specs.baseAddress!
                func put(_ i: Int, _ src: Int32, _ dst: Int32, _ rights: UInt32) {
                    let b = i * 16
                    sp.storeBytes(of: src, toByteOffset: b + 0, as: Int32.self)
                    sp.storeBytes(of: dst, toByteOffset: b + 4, as: Int32.self)
                    sp.storeBytes(of: rights, toByteOffset: b + 8, as: UInt32.self)
                    sp.storeBytes(of: UInt32(0), toByteOffset: b + 12, as: UInt32.self)
                }
                put(0, 1, 1, rightWrite)                          // stdout
                put(1, cmdRecv, 3, rightRead | rightTransfer)     // command recv end
                put(2, replySend, 4, rightWrite | rightTransfer)  // reply send end
                return Int(swiftos_cell_spawn(cellFd, "/bin/cellhello",
                            UnsafeMutableRawPointer(argv.baseAddress!), sp, 3))
            }
        }
    }
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp
    var ok = true

    // The two endpoints that make up the service's RPC channel.
    guard let cmd = makeEndpoint(), let rep = makeEndpoint() else {
        swiftos_puts("C6e FAIL: endpoint_create failed\n")
        return 1
    }

    // Assemble the cell: a /www root view + a resident-page cap. The handle set is
    // restricted at spawn time (only the three granted fds below).
    var cellRaw: UInt32 = 0
    let cellFd = swiftos_cell_create("/www", 80, &cellRaw)
    if cellFd < 0 || cellRaw < 2 {
        swiftos_puts("C6e FAIL: cell_create failed\n")
        return 1
    }
    swiftos_puts("C6e probe: assembled cell=")
    putUInt(UInt(cellRaw))
    swiftos_puts(" root=/www cap=80\n")

    // Launch the service inside the cell with only its granted handles.
    let pid = spawnServiceIntoCell(cellFd: cellFd, cmdRecv: cmd.recv, replySend: rep.send)
    if pid <= 0 {
        swiftos_puts("C6e FAIL: cell_spawn of the service failed\n")
        return 1
    }

    // Drive a live round-trip: the isolated service must answer "ping" with "pong".
    if !sendCmd(cmd.send, "ping") {
        swiftos_puts("C6e FAIL: could not send the request\n"); ok = false
    } else if !recvIs(rep.recv, "pong") {
        swiftos_puts("C6e FAIL: service did not reply pong\n"); ok = false
    } else {
        swiftos_puts("C6e probe: service replied pong from inside the cell\n")
    }

    // Accounting: the service is charged to its cell.
    let charged = processesIn(cellRaw)
    swiftos_puts("C6e probe: cell_stat processes=")
    putUInt(UInt(charged))
    swiftos_putc(0x0A)
    if charged != 1 {
        swiftos_puts("C6e FAIL: service not charged to its cell\n"); ok = false
    }

    // Tear down cleanly: stop the service, reap it, free the cell.
    _ = sendCmd(cmd.send, "stop")
    var status: Int32 = 0
    _ = swiftos_waitpid(Int32(pid), &status)
    if processesIn(cellRaw) != 0 {
        swiftos_puts("C6e FAIL: service still charged after stop\n"); ok = false
    }
    if swiftos_cell_destroy(cellFd) != 0 {
        swiftos_puts("C6e FAIL: cell_destroy failed\n"); ok = false
    } else {
        swiftos_puts("C6e probe: cell torn down, accounting reclaimed\n")
    }

    if ok {
        swiftos_puts("C6e OK: a real service ran isolated in a cell (namespace + handles + cap) and tore down cleanly\n")
        return 0
    }
    return 1
}
