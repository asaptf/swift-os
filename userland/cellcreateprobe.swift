// SPDX-License-Identifier: Apache-2.0
// cellcreateprobe.swift — C6b cell-creation + spawn-into-cell supervisor probe.
//
// Acts as a minimal cell supervisor running as a capConsole/capProcessInspect boot
// principal (in globalCell). It proves the C6b authority + accounting model:
//   1. spawning into a fd that is NOT a cell control handle is refused (authority
//      is by handle — you cannot name a cell you were not given);
//   2. cell_create mints a fresh CellId (raw >= 2) + a control handle;
//   3. a child launched via cell_spawn into that cell is charged to the NEW cell's
//      accounting domain and NOT to globalCell (the child blocks on a pipe barrier,
//      so the measurement is race-free);
//   4. releasing the barrier + reaping the child reclaims the new cell's charge.
// The boot test (tests/c6_cell_create_test.sh) asserts on the "C6b OK" marker.

private let globalCellRaw: UInt32 = 1
private let rightRead: UInt32 = 1 << 0
private let rightWrite: UInt32 = 1 << 1

private func putUInt(_ value: UInt) {
    if value == 0 { swiftos_putc(0x30); return }
    var digits = [UInt8](repeating: 0, count: 20)
    var n = value
    var count = 0
    while n > 0 {
        digits[count] = UInt8(0x30 + Int(n % 10))
        n /= 10
        count += 1
    }
    while count > 0 {
        count -= 1
        swiftos_putc(digits[count])
    }
}

private func processesIn(_ cellRaw: UInt32) -> Int {
    var s = swiftos_cell_stat()
    _ = swiftos_cell_query(cellRaw, &s)
    return Int(s.processes)
}

private func reportCell(_ label: StaticString, _ cellRaw: UInt32) {
    var s = swiftos_cell_stat()
    _ = swiftos_cell_query(cellRaw, &s)
    swiftos_puts("C6b probe: ")
    label.withUTF8Buffer { for b in $0 { swiftos_putc(b) } }
    swiftos_puts(" cell=")
    putUInt(UInt(cellRaw))
    swiftos_puts(" processes=")
    putUInt(UInt(s.processes))
    swiftos_puts(" residentPages=")
    putUInt(UInt(s.resident_pages))
    swiftos_puts(" handles=")
    putUInt(UInt(s.handles))
    swiftos_putc(0x0A)
}

// Launch /bin/cellchild into `cellFd`, handing it `rfd` as fd 0 (the pipe-barrier
// read end) and the supervisor's stdout as fd 1. Returns the child pid or <0.
private func spawnChildIntoCell(cellFd: Int32, rfd: Int32) -> Int {
    return withUnsafeTemporaryAllocation(of: CChar.self, capacity: 16) { nameBuf -> Int in
        let name = nameBuf.baseAddress!
        var i = 0
        for c in "cellchild".utf8 { name[i] = CChar(bitPattern: c); i += 1 }
        name[i] = 0
        return withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<CChar>?.self, capacity: 2) { argv -> Int in
            argv[0] = name; argv[1] = nil
            return withUnsafeTemporaryAllocation(byteCount: 32, alignment: 4) { specs -> Int in
                let sp = specs.baseAddress!
                func put(_ i: Int, _ src: Int32, _ dst: Int32, _ rights: UInt32) {
                    let b = i * 16
                    sp.storeBytes(of: src, toByteOffset: b + 0, as: Int32.self)
                    sp.storeBytes(of: dst, toByteOffset: b + 4, as: Int32.self)
                    sp.storeBytes(of: rights, toByteOffset: b + 8, as: UInt32.self)
                    sp.storeBytes(of: UInt32(0), toByteOffset: b + 12, as: UInt32.self)
                }
                put(0, rfd, 0, rightRead)  // pipe read end -> child fd 0 (barrier)
                put(1, 1, 1, rightWrite)   // supervisor stdout -> child fd 1
                return Int(swiftos_cell_spawn(cellFd, "/bin/cellchild",
                            UnsafeMutableRawPointer(argv.baseAddress!), sp, 2))
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

    // 1. Negative test: fd 1 (stdout) is a valid fd but NOT a cell control handle,
    //    so spawning into it must be refused before anything is launched.
    let denied = Int(swiftos_cell_spawn(1, "/bin/cellchild", nil, nil, 0))
    if denied >= 0 {
        swiftos_puts("C6b FAIL: spawn into a non-cell fd was not refused\n"); ok = false
    } else {
        swiftos_puts("C6b probe: spawn into non-cell fd refused (authority by handle)\n")
    }

    // 2. Create a cell.
    var newCell: UInt32 = 0
    let cellFd = swiftos_cell_create(nil, 0, &newCell) // unconfined, no cap (C6c/C6d test those)
    if cellFd < 0 || newCell < 2 {
        swiftos_puts("C6b FAIL: cell_create did not return a fresh cell + handle\n")
        return 1
    }
    swiftos_puts("C6b probe: created cell=")
    putUInt(UInt(newCell))
    swiftos_puts(" handleFd=")
    putUInt(UInt(cellFd))
    swiftos_putc(0x0A)

    let globBaseline = processesIn(globalCellRaw)
    if processesIn(newCell) != 0 {
        swiftos_puts("C6b FAIL: fresh cell was not empty\n"); ok = false
    }
    reportCell("fresh", newCell)

    // 3. Pipe barrier + spawn the child into the new cell.
    var fds = [Int32](repeating: -1, count: 2)
    if fds.withUnsafeMutableBufferPointer({ swiftos_pipe($0.baseAddress) }) != 0 {
        swiftos_puts("C6b FAIL: pipe() failed\n")
        return 1
    }
    let rfd = fds[0]
    let wfd = fds[1]

    let childPid = spawnChildIntoCell(cellFd: cellFd, rfd: rfd)
    if childPid <= 0 {
        swiftos_puts("C6b FAIL: cell_spawn into the held cell failed\n")
        return 1
    }

    // The child is alive and blocked on the barrier: it must be charged to the new
    // cell, and globalCell must be unchanged (the child is NOT in globalCell).
    reportCell("with-child", newCell)
    if processesIn(newCell) != 1 {
        swiftos_puts("C6b FAIL: child not charged to the new cell\n"); ok = false
    }
    if processesIn(globalCellRaw) != globBaseline {
        swiftos_puts("C6b FAIL: child leaked into globalCell accounting\n"); ok = false
    }

    // 4. Release the barrier so the child hits EOF and exits; reap it; the new
    //    cell's accounting must return to empty.
    _ = swiftos_close(wfd)
    _ = swiftos_close(rfd)
    var status: Int32 = 0
    _ = swiftos_waitpid(Int32(childPid), &status)
    reportCell("after-reap", newCell)
    if processesIn(newCell) != 0 {
        swiftos_puts("C6b FAIL: reaped child still charged to the cell\n"); ok = false
    }

    if ok {
        swiftos_puts("C6b OK: cell created, child charged to it (not globalCell), and reclaimed on reap\n")
        return 0
    }
    return 1
}
