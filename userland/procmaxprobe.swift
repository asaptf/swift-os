// SPDX-License-Identifier: Apache-2.0
// procmaxprobe.swift — process-table capacity probe.
//
// Proves the EL0 process-slot table holds far more than the historical 16-slot
// cap (kMaxProcesses in kernel/user/process.swift, now 64) and that the cap
// boundary is reached cleanly with EAGAIN rather than a crash or a hang. The
// probe runs in the single globalCell (raw 1), so cell_stat(globalCell).processes
// is the total live process count. It:
//   1. reads the baseline live process count;
//   2. forks children in a loop, each parked on a pipe read (a deterministic
//      liveness barrier — no sleep/timing race), until fork() returns -EAGAIN;
//   3. asserts more than 16 children were live simultaneously (the old cap is
//      gone), that the failing fork returned exactly EAGAIN (a clean boundary,
//      not a corrupt errno), and that the live total grew by exactly the number
//      forked (no lost slot);
//   4. releases the barrier, reaps every child, and asserts the live count is
//      back to baseline (no slot leak across saturation).
// The boot test (tests/procmax_test.sh) asserts on the "PROCMAX OK" marker.

private let globalCellRaw: UInt32 = 1   // matches kernel globalCell = CellId(raw: 1)
private let eagain: Int32 = -11         // -EAGAIN, the kernel's Errno.again.code on a full table
private let oldCap = 16                 // the historical maxProc the table used to be capped at
private let maxKids = 128               // generous upper bound (> kMaxProcesses; the table caps us first)

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

    // Fork until the table refuses. Each child drops its write-end copy and parks
    // in read(), so all forked children are simultaneously alive while we measure.
    var kids = [Int32](repeating: 0, count: maxKids)
    var forked = 0
    var lastErr: Int32 = 0
    while forked < maxKids {
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
    swiftos_puts(" boundary errno=")
    // lastErr is negative; print its magnitude with a leading '-'.
    if lastErr < 0 { swiftos_putc(0x2D); putUInt(UInt(-lastErr)) } else { putUInt(UInt(lastErr)) }
    swiftos_putc(0x0A)

    var ok = true
    if forked <= oldCap {
        swiftos_puts("PROCMAX FAIL: forked children did not exceed the old 16-slot cap\n"); ok = false
    }
    if lastErr != eagain {
        swiftos_puts("PROCMAX FAIL: cap boundary did not return a clean EAGAIN\n"); ok = false
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
        swiftos_puts(" live processes (> old 16-slot cap), clean EAGAIN at the boundary, no leak\n")
        return 0
    }
    return 1
}
