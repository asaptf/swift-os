// SPDX-License-Identifier: Apache-2.0
// cellhandleprobe.swift — C7b: per-cell handle cap enforcement.
//
// Runs as a capConsole boot principal. C7a hardened the resident-page cap; C7b adds a
// per-cell HANDLE cap, folded into cell_create (symmetric with the page cap). This
// supervisor proves:
//   1. it creates a cell with a hard handle cap and launches one /bin/cellopener into
//      it (granted only barrier-read + stdout + a signal pipe = 3 handles);
//   2. the opener open()s files until the kernel refuses with EMFILE (the cap bites
//      mid-member, at the handle constructor, not just at spawn);
//   3. while the opener sits capped-out and alive, cell_stat's handles is <= cap (the
//      aggregate NEVER exceeds the cap);
//   4. an UNCAPPED (global) member — the supervisor itself — opens well past `cap`
//      handles unaffected, so the guard is a no-op for the common case.
// Then it releases the opener, reaps it, and destroys the cell. The boot test
// (tests/c7_cell_handlecap_test.sh) asserts on the "C7b OK" marker.

private let rightRead: UInt32 = 1 << 0
private let rightWrite: UInt32 = 1 << 1
private let oRdOnly: Int32 = 0
private let handleCap: UInt = 12   // opener base (3 granted) + room to open, then refuse

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

private func handlesIn(_ cellRaw: UInt32) -> UInt {
    var s = swiftos_cell_stat()
    _ = swiftos_cell_query(cellRaw, &s)
    return UInt(s.handles)
}

private func processesIn(_ cellRaw: UInt32) -> Int {
    var s = swiftos_cell_stat()
    _ = swiftos_cell_query(cellRaw, &s)
    return Int(s.processes)
}

// Launch /bin/cellopener into the cell with exactly three handles:
//   barrier-read -> fd 0, supervisor stdout -> fd 1, signal-write -> fd 2.
private func spawnOpener(cellFd: Int32, barrierRfd: Int32, signalWfd: Int32) -> Int {
    return withUnsafeTemporaryAllocation(of: CChar.self, capacity: 16) { nameBuf -> Int in
        let name = nameBuf.baseAddress!
        var i = 0
        for c in "cellopener".utf8 { name[i] = CChar(bitPattern: c); i += 1 }
        name[i] = 0
        return withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<CChar>?.self, capacity: 2) { argv -> Int in
            argv[0] = name; argv[1] = nil
            return withUnsafeTemporaryAllocation(byteCount: 48, alignment: 4) { specs -> Int in
                let sp = specs.baseAddress!
                func put(_ idx: Int, _ src: Int32, _ dst: Int32, _ rights: UInt32) {
                    let b = idx * 16
                    sp.storeBytes(of: src, toByteOffset: b + 0, as: Int32.self)
                    sp.storeBytes(of: dst, toByteOffset: b + 4, as: Int32.self)
                    sp.storeBytes(of: rights, toByteOffset: b + 8, as: UInt32.self)
                    sp.storeBytes(of: UInt32(0), toByteOffset: b + 12, as: UInt32.self)
                }
                put(0, barrierRfd, 0, rightRead)   // barrier read end -> child fd 0
                put(1, 1, 1, rightWrite)           // supervisor stdout  -> child fd 1
                put(2, signalWfd, 2, rightWrite)   // signal write end   -> child fd 2
                return Int(swiftos_cell_spawn(cellFd, "/bin/cellopener",
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

    // 1. Create a cell with a hard handle cap (unconfined, no page cap — C7a covers
    //    that; here the member opens /etc/motd, so it must reach the global namespace).
    var cell: UInt32 = 0
    let cellFd = swiftos_cell_create(nil, 0, handleCap, &cell)
    if cellFd < 0 || cell < 2 {
        swiftos_puts("C7b FAIL: cell_create with a handle cap failed\n")
        return 1
    }
    swiftos_puts("C7b probe: created cell=")
    putUInt(UInt(cell))
    swiftos_puts(" handleCap=")
    putUInt(handleCap)
    swiftos_putc(0x0A)

    // Two pipes: a barrier (supervisor releases the opener) and a signal (the opener
    // tells the supervisor it is capped-out and alive).
    var bar = [Int32](repeating: -1, count: 2)
    if bar.withUnsafeMutableBufferPointer({ swiftos_pipe($0.baseAddress) }) != 0 {
        swiftos_puts("C7b FAIL: pipe (barrier) failed\n"); return 1
    }
    let barR = bar[0], barW = bar[1]
    var sigp = [Int32](repeating: -1, count: 2)
    if sigp.withUnsafeMutableBufferPointer({ swiftos_pipe($0.baseAddress) }) != 0 {
        swiftos_puts("C7b FAIL: pipe (signal) failed\n"); return 1
    }
    let sigR = sigp[0], sigW = sigp[1]

    // 2. Launch the opener into the capped cell.
    let pid = spawnOpener(cellFd: cellFd, barrierRfd: barR, signalWfd: sigW)
    if pid <= 0 {
        swiftos_puts("C7b FAIL: cell_spawn of the opener failed\n")
        return 1
    }
    _ = swiftos_close(barR)
    _ = swiftos_close(sigW)

    // 3. Block until the opener signals it has opened to the ceiling and is capped-out.
    var s1: UInt8 = 0
    _ = swiftos_read(sigR, &s1, 1)

    // 4. Sample the cell aggregate: handles must NEVER exceed the cap.
    let held = handlesIn(cell)
    swiftos_puts("C7b probe: capped member handles=")
    putUInt(held)
    swiftos_puts(" cap=")
    putUInt(handleCap)
    swiftos_putc(0x0A)
    if held > handleCap {
        swiftos_puts("C7b FAIL: cell handles exceeded the cap\n"); ok = false
    } else if held < 4 {
        swiftos_puts("C7b FAIL: the opener never grew its handle table\n"); ok = false
    } else {
        swiftos_puts("C7b probe: cell handles within cap (intra-member cap enforced)\n")
    }
    if processesIn(cell) != 1 {
        swiftos_puts("C7b FAIL: unexpected live member count in the capped cell\n"); ok = false
    }

    // 5. Release the opener (close the barrier write end -> EOF) and reap it.
    _ = swiftos_close(barW)
    var status: Int32 = 0
    _ = swiftos_waitpid(Int32(pid), &status)
    _ = swiftos_close(sigR)
    if processesIn(cell) != 0 {
        swiftos_puts("C7b FAIL: the opener remained charged after reap\n"); ok = false
    }

    // 6. An uncapped (global) member is unaffected: the supervisor itself opens well
    //    past `cap` handles — the guard short-circuits for globalCell.
    let target = Int(handleCap) + 8
    var globalOpened = 0
    while globalOpened < target {
        if swiftos_open("/etc/motd", oRdOnly) < 0 { break }
        globalOpened += 1
    }
    swiftos_puts("C7b probe: uncapped global opens=")
    putUInt(UInt(globalOpened))
    swiftos_putc(0x0A)
    if globalOpened >= target {
        swiftos_puts("C7b probe: uncapped global member unaffected by the cell cap\n")
    } else {
        swiftos_puts("C7b FAIL: uncapped global open was refused\n"); ok = false
    }

    // 7. Tear the now-empty cell down.
    if swiftos_cell_destroy(cellFd) != 0 {
        swiftos_puts("C7b FAIL: cell_destroy of the empty cell failed\n"); ok = false
    }

    if ok {
        swiftos_puts("C7b OK: per-cell handle cap enforced, uncapped growth unaffected\n")
        return 0
    }
    return 1
}
