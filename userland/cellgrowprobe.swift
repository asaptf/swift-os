// SPDX-License-Identifier: Apache-2.0
// cellgrowprobe.swift — C7a: intra-member resident-page cap enforcement.
//
// Runs as a capConsole boot principal. C6d enforces a cell's page cap only at
// spawn-into-cell time (refuse a NEW member past the ceiling); C7a tightens it so a
// single member cannot grow its OWN heap past the cap either. This supervisor proves:
//   1. it creates a cell with a hard resident-page cap and launches one /bin/cellgrower
//      into it (granted only barrier-read + stdout + a signal pipe);
//   2. the grower sbrk()s until the kernel refuses the grow (the cap bites mid-member),
//      then confirms a fresh anon mmap is ALSO refused (cross-path, same cap guard);
//   3. while the grower sits capped-out and alive, cell_stat's residentPages is <= cap
//      (the aggregate NEVER exceeds the cap);
//   4. an UNCAPPED (global) member — the supervisor itself — grows well past `cap`
//      pages unaffected, so the guard is a no-op for the common case.
// Then it releases the grower, reaps it, and destroys the cell. The boot test
// (tests/c7_cell_pagecap_test.sh) asserts on the "C7a OK" marker.

private let rightRead: UInt32 = 1 << 0
private let rightWrite: UInt32 = 1 << 1
private let pageBytes = 4096
private let sbrkFail = UInt(bitPattern: -1)
private let pageCap: UInt = 48   // grower base (~20 res pages) + room to grow, then refuse

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

private func residentPagesIn(_ cellRaw: UInt32) -> UInt {
    var s = swiftos_cell_stat()
    _ = swiftos_cell_query(cellRaw, &s)
    return UInt(s.resident_pages)
}

private func processesIn(_ cellRaw: UInt32) -> Int {
    var s = swiftos_cell_stat()
    _ = swiftos_cell_query(cellRaw, &s)
    return Int(s.processes)
}

// Launch /bin/cellgrower into the cell with exactly three handles:
//   barrier-read -> fd 0, supervisor stdout -> fd 1, signal-write -> fd 2.
private func spawnGrower(cellFd: Int32, barrierRfd: Int32, signalWfd: Int32) -> Int {
    return withUnsafeTemporaryAllocation(of: CChar.self, capacity: 16) { nameBuf -> Int in
        let name = nameBuf.baseAddress!
        var i = 0
        for c in "cellgrower".utf8 { name[i] = CChar(bitPattern: c); i += 1 }
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
                return Int(swiftos_cell_spawn(cellFd, "/bin/cellgrower",
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

    // 1. Create a capped cell.
    var cell: UInt32 = 0
    let cellFd = swiftos_cell_create(nil, pageCap, &cell)
    if cellFd < 0 || cell < 2 {
        swiftos_puts("C7a FAIL: cell_create with a page cap failed\n")
        return 1
    }
    swiftos_puts("C7a probe: created cell=")
    putUInt(UInt(cell))
    swiftos_puts(" pageCap=")
    putUInt(pageCap)
    swiftos_putc(0x0A)

    // Two pipes: a barrier (supervisor releases the grower) and a signal (the grower
    // tells the supervisor it is capped-out and alive).
    var bar = [Int32](repeating: -1, count: 2)
    if bar.withUnsafeMutableBufferPointer({ swiftos_pipe($0.baseAddress) }) != 0 {
        swiftos_puts("C7a FAIL: pipe (barrier) failed\n"); return 1
    }
    let barR = bar[0], barW = bar[1]
    var sigp = [Int32](repeating: -1, count: 2)
    if sigp.withUnsafeMutableBufferPointer({ swiftos_pipe($0.baseAddress) }) != 0 {
        swiftos_puts("C7a FAIL: pipe (signal) failed\n"); return 1
    }
    let sigR = sigp[0], sigW = sigp[1]

    // 2. Launch the grower into the capped cell.
    let pid = spawnGrower(cellFd: cellFd, barrierRfd: barR, signalWfd: sigW)
    if pid <= 0 {
        swiftos_puts("C7a FAIL: cell_spawn of the grower failed\n")
        return 1
    }
    // The grower owns its own copies now; drop the ends the supervisor won't use.
    _ = swiftos_close(barR)
    _ = swiftos_close(sigW)

    // 3. Block until the grower signals it has grown to the ceiling and is capped-out.
    var s1: UInt8 = 0
    _ = swiftos_read(sigR, &s1, 1)

    // 4. Sample the cell aggregate: it must NEVER exceed the cap.
    let resident = residentPagesIn(cell)
    swiftos_puts("C7a probe: capped member residentPages=")
    putUInt(resident)
    swiftos_puts(" cap=")
    putUInt(pageCap)
    swiftos_putc(0x0A)
    if resident > pageCap {
        swiftos_puts("C7a FAIL: cell residentPages exceeded the cap\n"); ok = false
    } else if resident == 0 {
        swiftos_puts("C7a FAIL: the grower never grew its resident set\n"); ok = false
    } else {
        swiftos_puts("C7a probe: cell residentPages within cap (intra-member cap enforced)\n")
    }
    if processesIn(cell) != 1 {
        swiftos_puts("C7a FAIL: unexpected live member count in the capped cell\n"); ok = false
    }

    // 5. Release the grower (close the barrier write end -> EOF) and reap it.
    _ = swiftos_close(barW)
    var status: Int32 = 0
    _ = swiftos_waitpid(Int32(pid), &status)
    _ = swiftos_close(sigR)
    if processesIn(cell) != 0 {
        swiftos_puts("C7a FAIL: the grower remained charged after reap\n"); ok = false
    }

    // 6. An uncapped (global) member is unaffected: the supervisor itself grows its
    //    own heap well past `cap` pages — the guard short-circuits for globalCell.
    let target = Int(pageCap) + 16
    var globalGrew = 0
    while globalGrew < target {
        if swiftos_sbrk(Int(pageBytes)) == sbrkFail { break }
        globalGrew += 1
    }
    swiftos_puts("C7a probe: uncapped global growth pages=")
    putUInt(UInt(globalGrew))
    swiftos_putc(0x0A)
    if globalGrew >= target {
        swiftos_puts("C7a probe: uncapped global member unaffected by the cell cap\n")
    } else {
        swiftos_puts("C7a FAIL: uncapped global growth was refused\n"); ok = false
    }

    // 7. Tear the now-empty cell down.
    if swiftos_cell_destroy(cellFd) != 0 {
        swiftos_puts("C7a FAIL: cell_destroy of the empty cell failed\n"); ok = false
    }

    if ok {
        swiftos_puts("C7a OK: intra-member resident-page cap enforced, uncapped growth unaffected\n")
        return 0
    }
    return 1
}
