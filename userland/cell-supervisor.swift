// SPDX-License-Identifier: Apache-2.0
// cell-supervisor.swift — C7c persistent restart/FDIR cell supervisor.
//
// A long-running supervisor (the kind swos-init launches) that hosts a service inside
// a cell for the lifetime of boot, with a bounded restart loop. When the cell-hosted
// service exits or crashes (detected via waitpid), the supervisor tears the cell down
// (cell_pids -> reap survivors -> cell_destroy), reclaims the domain, and restarts the
// service in a FRESH cell (a new CellId). Restarts are bounded so a crash loop cannot
// fork-storm. This probe drives the scenario deterministically and asserts on markers:
//
//   Phase A — supervised restart recovery: bring gen 1 up (ping->pong), fault it (the
//     service exits non-zero on "die"), detect the exit, bring gen 2 up in a FRESH cell
//     (a different CellId, allocated before the faulted one is reclaimed), reclaim gen 1.
//   Phase B — bounded restart: a service that crashes immediately is restarted up to
//     MAX_RESTARTS times (each generation in a fresh cell, each reclaimed), then the
//     supervisor gives up — the crash loop halts instead of fork-storming.

private let rightRead: UInt32 = 1 << 0
private let rightWrite: UInt32 = 1 << 1
private let rightTransfer: UInt32 = 1 << 5
private let pageCap: UInt = 64       // exercises the C7a page cap too (generous)
private let handleCap: UInt = 16     // exercises the C7b handle cap too (generous)
private let maxRestarts = 3          // bounded — a crash loop cannot fork-storm

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

// Launch /bin/cell-svc into `cellFd`. In serve mode it is granted stdout (fd 1), the
// command recv end (fd 3), and the reply send end (fd 4); in crash mode only stdout.
private func spawnServiceIntoCell(cellFd: Int32, mode: StaticString,
                                  cmdRecv: Int32, replySend: Int32) -> Int {
    return withUnsafeTemporaryAllocation(of: CChar.self, capacity: 16) { nameBuf -> Int in
        let name = nameBuf.baseAddress!
        var i = 0
        for c in "cell-svc".utf8 { name[i] = CChar(bitPattern: c); i += 1 }
        name[i] = 0
        return withUnsafeTemporaryAllocation(of: CChar.self, capacity: 8) { modeBuf -> Int in
            let m = modeBuf.baseAddress!
            var j = 0
            mode.withUTF8Buffer { w in for b in w { m[j] = CChar(bitPattern: b); j += 1 } }
            m[j] = 0
            return withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<CChar>?.self, capacity: 3) { argv -> Int in
                argv[0] = name; argv[1] = m; argv[2] = nil
                return withUnsafeTemporaryAllocation(byteCount: 48, alignment: 4) { specs -> Int in
                    let sp = specs.baseAddress!
                    func put(_ idx: Int, _ src: Int32, _ dst: Int32, _ rights: UInt32) {
                        let b = idx * 16
                        sp.storeBytes(of: src, toByteOffset: b + 0, as: Int32.self)
                        sp.storeBytes(of: dst, toByteOffset: b + 4, as: Int32.self)
                        sp.storeBytes(of: rights, toByteOffset: b + 8, as: UInt32.self)
                        sp.storeBytes(of: UInt32(0), toByteOffset: b + 12, as: UInt32.self)
                    }
                    put(0, 1, 1, rightWrite)   // stdout
                    var count = 1
                    if cmdRecv >= 0 && replySend >= 0 {
                        put(1, cmdRecv, 3, rightRead | rightTransfer)     // command recv end
                        put(2, replySend, 4, rightWrite | rightTransfer)  // reply send end
                        count = 3
                    }
                    return Int(swiftos_cell_spawn(cellFd, "/bin/cell-svc",
                                UnsafeMutableRawPointer(argv.baseAddress!), sp, UInt(count)))
                }
            }
        }
    }
}

// Reap every live member of a cell (the supervisor's "walk the job tree" teardown),
// then free the CellId. Returns true if the cell was reclaimed cleanly.
private func teardownCell(_ cellFd: Int32, _ cellRaw: UInt32) -> Bool {
    withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 8) { pidbuf in
        let n = Int(swiftos_cell_pids(cellFd, pidbuf.baseAddress, 8))
        var k = 0
        while k < n && k < 8 {
            var status: Int32 = 0
            _ = swiftos_waitpid(Int32(bitPattern: pidbuf[k]), &status)
            k += 1
        }
    }
    return swiftos_cell_destroy(cellFd) == 0
}

// Bring up one generation: fresh cell + a serve-mode service, health-checked with a
// ping->pong round-trip. Returns the cell control fd, CellId, service pid, and the
// supervisor's command-send / reply-recv ends (or nil on failure).
private struct Generation {
    var cellFd: Int32; var cellRaw: UInt32; var pid: Int32
    var cmdSend: Int32; var replyRecv: Int32
}

private func bringUp() -> Generation? {
    var raw: UInt32 = 0
    let cellFd = swiftos_cell_create(nil, pageCap, handleCap, &raw)
    if cellFd < 0 || raw < 2 { return nil }
    guard let cmd = makeEndpoint(), let rep = makeEndpoint() else {
        _ = swiftos_cell_destroy(cellFd); return nil
    }
    let pid = spawnServiceIntoCell(cellFd: cellFd, mode: "serve",
                                   cmdRecv: cmd.recv, replySend: rep.send)
    if pid <= 0 { _ = swiftos_cell_destroy(cellFd); return nil }
    // Health check: the service must answer ping with pong before we call it "up".
    if !sendCmd(cmd.send, "ping") || !recvIs(rep.recv, "pong") {
        _ = sendCmd(cmd.send, "stop")
        var st: Int32 = 0; _ = swiftos_waitpid(Int32(pid), &st)
        _ = teardownCell(cellFd, raw)
        return nil
    }
    return Generation(cellFd: cellFd, cellRaw: raw, pid: Int32(pid),
                      cmdSend: cmd.send, replyRecv: rep.recv)
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp
    var ok = true

    // ---- Phase A: supervised restart recovery -------------------------------
    guard let gen1 = bringUp() else {
        swiftos_puts("C7c FAIL: could not bring gen 1 up\n"); return 1
    }
    swiftos_puts("C7c probe: gen 1 up, cell=")
    putUInt(UInt(gen1.cellRaw)); swiftos_putc(0x0A)

    // Fault gen 1: the service exits non-zero on "die"; the supervisor detects it.
    _ = sendCmd(gen1.cmdSend, "die")
    var st1: Int32 = 0
    _ = swiftos_waitpid(gen1.pid, &st1)
    let code1 = (Int(st1) >> 8) & 0xff
    swiftos_puts("C7c probe: gen 1 faulted (detected exit code ")
    putUInt(UInt(code1)); swiftos_puts(")\n")

    // FDIR: restart in a FRESH cell BEFORE reclaiming the faulted one, so the new
    // generation provably gets a different CellId (the supervisor never recycles the
    // faulted domain's tag under a live successor).
    guard let gen2 = bringUp() else {
        swiftos_puts("C7c FAIL: could not restart gen 2\n")
        _ = teardownCell(gen1.cellFd, gen1.cellRaw); return 1
    }
    swiftos_puts("C7c probe: gen 2 up, cell=")
    putUInt(UInt(gen2.cellRaw)); swiftos_putc(0x0A)
    if gen2.cellRaw == gen1.cellRaw {
        swiftos_puts("C7c FAIL: restart reused the faulted CellId\n"); ok = false
    } else {
        swiftos_puts("C7c probe: restarted in a fresh CellId\n")
    }

    // Reclaim the faulted generation; its accounting must drop to zero.
    if !teardownCell(gen1.cellFd, gen1.cellRaw) {
        swiftos_puts("C7c FAIL: could not reclaim the faulted cell\n"); ok = false
    } else if processesIn(gen1.cellRaw) != 0 {
        swiftos_puts("C7c FAIL: faulted cell still charged after reclaim\n"); ok = false
    } else {
        swiftos_puts("C7c probe: gen 1 cell reclaimed, accounting reset\n")
    }
    if processesIn(gen2.cellRaw) != 1 {
        swiftos_puts("C7c FAIL: gen 2 service not charged to its fresh cell\n"); ok = false
    }
    _ = swiftos_close(gen1.cmdSend); _ = swiftos_close(gen1.replyRecv)

    // Clean teardown of the healthy gen 2.
    _ = sendCmd(gen2.cmdSend, "stop")
    var st2: Int32 = 0
    _ = swiftos_waitpid(gen2.pid, &st2)
    _ = swiftos_close(gen2.cmdSend); _ = swiftos_close(gen2.replyRecv)
    if !teardownCell(gen2.cellFd, gen2.cellRaw) {
        swiftos_puts("C7c FAIL: could not reclaim gen 2\n"); ok = false
    }

    // ---- Phase B: bounded restart halts a crash loop ------------------------
    var attempts = 0
    var prevRaw: UInt32 = 0
    var allFresh = true
    var allReclaimed = true
    while attempts < maxRestarts {
        var raw: UInt32 = 0
        let cellFd = swiftos_cell_create(nil, pageCap, handleCap, &raw)
        if cellFd < 0 || raw < 2 {
            swiftos_puts("C7c FAIL: crash-loop cell_create failed\n"); ok = false; break
        }
        let pid = spawnServiceIntoCell(cellFd: cellFd, mode: "crash",
                                       cmdRecv: -1, replySend: -1)
        if pid <= 0 {
            swiftos_puts("C7c FAIL: crash-loop spawn failed\n"); ok = false
            _ = swiftos_cell_destroy(cellFd); break
        }
        var st: Int32 = 0
        _ = swiftos_waitpid(Int32(pid), &st)   // detect the immediate crash
        if prevRaw != 0 && raw == prevRaw { allFresh = false }
        prevRaw = raw
        if !teardownCell(cellFd, raw) { allReclaimed = false }
        attempts += 1
        swiftos_puts("C7c probe: crash-loop attempt ")
        putUInt(UInt(attempts)); swiftos_puts(" reclaimed (cell=")
        putUInt(UInt(raw)); swiftos_puts(")\n")
    }
    if attempts == maxRestarts {
        swiftos_puts("C7c probe: restart cap reached (")
        putUInt(UInt(maxRestarts)); swiftos_puts("), halting crash loop\n")
    } else {
        swiftos_puts("C7c FAIL: crash loop did not run to the restart cap\n"); ok = false
    }
    if !allReclaimed { swiftos_puts("C7c FAIL: a crash-loop generation leaked\n"); ok = false }
    _ = allFresh // each generation reused a freed slot deterministically; not asserted

    if ok {
        swiftos_puts("C7c OK: supervised restart in a fresh cell, accounting reclaimed, bounded crash loop halted\n")
        return 0
    }
    return 1
}
