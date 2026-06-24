// SPDX-License-Identifier: Apache-2.0
// cellcapprobe.swift — C6d cell lifecycle (resource cap + enumerate + teardown).
//
// Runs as a capConsole boot principal. It proves the C6d slice:
//   1. a cell created with a hard resident-page cap refuses a new member once the
//      cell's aggregate resident pages reach the ceiling (cell_spawn -> ENOMEM);
//   2. cell_pids enumerates the cell's live members by tag (the supervisor's "walk
//      the job tree" primitive);
//   3. cell_destroy is refused (EBUSY) while members are still live;
//   4. after the members are released (pipe barrier EOF) and reaped, cell_destroy
//      frees the CellId, the cell's accounting is zero, and the CellId is reusable.
// The boot test (tests/c6_cell_lifecycle_test.sh) asserts on the "C6d OK" marker.

private let rightRead: UInt32 = 1 << 0
private let rightWrite: UInt32 = 1 << 1
private let eNoMem = -12     // ENOMEM — the resident-page cap refused a spawn
private let eBusy  = -16     // EBUSY  — cell_destroy refused while members live
private let pageCap: UInt = 30   // a few cellchild members (~20 res pages each) then refuse
private let maxKids = 8

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

    // 1. Create a capped cell.
    var cell: UInt32 = 0
    let cellFd = swiftos_cell_create(nil, pageCap, 0, &cell)
    if cellFd < 0 || cell < 2 {
        swiftos_puts("C6d FAIL: cell_create with a page cap failed\n")
        return 1
    }
    swiftos_puts("C6d probe: created cell=")
    putUInt(UInt(cell))
    swiftos_puts(" pageCap=")
    putUInt(pageCap)
    swiftos_putc(0x0A)

    // 2. One pipe barrier shared by every member; spawn until the cap refuses.
    var fds = [Int32](repeating: -1, count: 2)
    if fds.withUnsafeMutableBufferPointer({ swiftos_pipe($0.baseAddress) }) != 0 {
        swiftos_puts("C6d FAIL: pipe() failed\n")
        return 1
    }
    let rfd = fds[0]
    let wfd = fds[1]

    var pids = [Int32](repeating: 0, count: maxKids)
    var live = 0
    var capRefused = false
    for _ in 0..<maxKids {
        let pid = spawnChildIntoCell(cellFd: cellFd, rfd: rfd)
        if pid > 0 {
            pids[live] = Int32(pid)
            live += 1
        } else {
            if pid == eNoMem { capRefused = true }
            else {
                swiftos_puts("C6d FAIL: spawn failed for a reason other than the cap\n")
                ok = false
            }
            break
        }
    }
    swiftos_puts("C6d probe: spawned ")
    putUInt(UInt(live))
    swiftos_puts(" members, cap refused further growth=")
    swiftos_puts(capRefused ? "yes\n" : "no\n")
    if live < 1 { swiftos_puts("C6d FAIL: no member spawned under the cap\n"); ok = false }
    if !capRefused { swiftos_puts("C6d FAIL: the page cap never refused a spawn\n"); ok = false }

    // 3. Enumerate the cell's members by tag — the supervisor's job-tree walk.
    var enumerated = 0
    withUnsafeTemporaryAllocation(of: UInt32.self, capacity: maxKids) { pidbuf in
        enumerated = Int(swiftos_cell_pids(cellFd, pidbuf.baseAddress, UInt(maxKids)))
    }
    swiftos_puts("C6d probe: cell_pids enumerated ")
    putUInt(UInt(enumerated))
    swiftos_puts(" members\n")
    if enumerated != live { swiftos_puts("C6d FAIL: cell_pids count != spawned members\n"); ok = false }

    // 4. Destroy must be refused while members are live.
    let busy = swiftos_cell_destroy(cellFd)
    if busy >= 0 {
        swiftos_puts("C6d FAIL: cell_destroy succeeded while members were live\n"); ok = false
    } else if busy == eBusy {
        swiftos_puts("C6d probe: destroy refused while members live (EBUSY)\n")
    } else {
        swiftos_puts("C6d FAIL: cell_destroy returned an unexpected error while live\n"); ok = false
    }

    // 5. Release the barrier so every member hits EOF and exits; reap them.
    _ = swiftos_close(wfd)
    _ = swiftos_close(rfd)
    for i in 0..<live {
        var status: Int32 = 0
        _ = swiftos_waitpid(pids[i], &status)
    }
    if processesIn(cell) != 0 {
        swiftos_puts("C6d FAIL: members remained charged after reap\n"); ok = false
    }

    // 6. Destroy the now-empty cell; its accounting is zero and the CellId frees.
    let destroyed = swiftos_cell_destroy(cellFd)
    if destroyed != 0 {
        swiftos_puts("C6d FAIL: cell_destroy of an empty cell failed\n"); ok = false
    } else {
        swiftos_puts("C6d probe: cell destroyed, accounting reclaimed\n")
    }

    // 7. The CellId is reusable: a fresh cell_create reclaims the freed slot.
    var cell2: UInt32 = 0
    let cellFd2 = swiftos_cell_create(nil, 0, 0, &cell2)
    if cellFd2 < 0 || cell2 < 2 {
        swiftos_puts("C6d FAIL: CellId was not reusable after destroy\n"); ok = false
    } else {
        swiftos_puts("C6d probe: CellId reusable (re-created cell=")
        putUInt(UInt(cell2))
        swiftos_puts(")\n")
    }
    // The stale handle to the destroyed cell must no longer name a cell.
    if swiftos_cell_destroy(cellFd) >= 0 {
        swiftos_puts("C6d FAIL: stale handle to the destroyed cell still resolved\n"); ok = false
    } else {
        swiftos_puts("C6d probe: stale handle to destroyed cell rejected\n")
    }

    if ok {
        swiftos_puts("C6d OK: page cap enforced, members enumerated, cell torn down and CellId reclaimed\n")
        return 0
    }
    return 1
}
