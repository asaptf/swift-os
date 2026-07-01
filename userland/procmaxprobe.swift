// SPDX-License-Identifier: Apache-2.0
// procmaxprobe.swift — process-table growth probe.
//
// Proves the EL0 process-slot table crosses both historical fixed caps: the
// original 16-slot bring-up table and the later 64-slot PT1 table. The probe runs
// in the single globalCell (raw 1), so cell_stat(globalCell).processes is the
// total live process count. It:
//   1. reads the baseline live process count;
//   2. forks children in a loop, each parked on a pipe read (a deterministic
//      liveness barrier — no sleep/timing race), until more than 64 children are
//      live simultaneously;
//   3. asserts the live total grew by exactly the number forked (no lost slot);
//   4. releases the barrier, reaps every child, and asserts the live count is
//      back to baseline (no slot leak across saturation).
// The boot test (tests/procmax_test.sh) asserts on the "PROCMAX OK" marker.

private let globalCellRaw: UInt32 = 1   // matches kernel globalCell = CellId(raw: 1)
private let oldBringupCap = 16
private let oldPT1Cap = 64
private let targetKids = oldPT1Cap + 8

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

private func liveProcesses() -> UInt32 {
    var s = swiftos_cell_stat()
    _ = swiftos_cell_query(globalCellRaw, &s)
    return s.processes
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp

    let base = liveProcesses()
    swiftos_puts("procmax probe: baseline live processes=")
    putUInt(UInt(base))
    swiftos_putc(0x0A)

    // A pipe used purely as a liveness barrier: children block reading the read
    // end until every write end is closed, then they hit EOF and exit.
    var fds = [Int32](repeating: -1, count: 2)
    if fds.withUnsafeMutableBufferPointer({ swiftos_pipe($0.baseAddress) }) != 0 {
        swiftos_puts("PROCMAX FAIL: pipe() failed\n")
        return 1
    }
    let rfd = fds[0]
    let wfd = fds[1]

    // Fork past the old fixed 64-slot table. Each child drops its write-end copy
    // and parks in read(), so all forked children are simultaneously alive while
    // we measure.
    var kids = [Int32](repeating: 0, count: targetKids)
    var forked = 0
    var lastErr: Int32 = 0
    while forked < targetKids {
        let pid = swiftos_fork()
        if pid < 0 { lastErr = pid; break }
        if pid == 0 {
            _ = swiftos_close(wfd)
            var byte: UInt8 = 0
            _ = swiftos_read(rfd, &byte, 1)   // blocks; returns 0 (EOF) on release
            return 0                          // crt0 _exits the child here
        }
        kids[forked] = pid
        forked += 1
    }

    let peak = liveProcesses()
    swiftos_puts("procmax probe: forked=")
    putUInt(UInt(forked))
    swiftos_puts(" peak live processes=")
    putUInt(UInt(peak))
    swiftos_puts(" target children=")
    putUInt(UInt(targetKids))
    if lastErr < 0 {
        swiftos_puts(" early errno=-")
        putUInt(UInt(-lastErr))
    }
    swiftos_putc(0x0A)

    var ok = true
    if forked <= oldBringupCap {
        swiftos_puts("PROCMAX FAIL: forked children did not exceed the old 16-slot cap\n"); ok = false
    }
    if forked <= oldPT1Cap {
        swiftos_puts("PROCMAX FAIL: forked children did not exceed the old 64-slot cap\n"); ok = false
    }
    if lastErr != 0 {
        swiftos_puts("PROCMAX FAIL: fork failed before crossing the old 64-slot cap\n"); ok = false
    }
    if peak != base + UInt32(forked) {
        swiftos_puts("PROCMAX FAIL: live count did not grow by exactly the number forked\n"); ok = false
    }

    // Release the barrier: closing both ends in the parent makes every child's
    // read() return EOF, so they exit; reap each one.
    _ = swiftos_close(wfd)
    _ = swiftos_close(rfd)
    for i in 0..<forked {
        var status: Int32 = 0
        _ = swiftos_waitpid(kids[i], &status)
    }

    let after = liveProcesses()
    swiftos_puts("procmax probe: after-reap live processes=")
    putUInt(UInt(after))
    swiftos_putc(0x0A)
    if after != base {
        swiftos_puts("PROCMAX FAIL: slot leak after saturate-and-reap\n"); ok = false
    }

    if ok {
        swiftos_puts("PROCMAX OK: process table holds ")
        putUInt(UInt(peak))
        swiftos_puts(" live processes (> old 64-slot cap), no leak\n")
        return 0
    }
    return 1
}
