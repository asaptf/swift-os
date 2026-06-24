// SPDX-License-Identifier: Apache-2.0
// cellstatprobe.swift — C6a per-cell resource-accounting probe.
//
// Proves SYS_cell_stat aggregates the live resource usage of a CellId domain and
// that the aggregate tracks process lifecycle. Everything here runs in the single
// globalCell (raw 1); cell creation arrives in C6b. The probe:
//   1. reads the baseline cell_stat(globalCell);
//   2. forks N children, each blocked on a pipe read (a deterministic barrier —
//      no sleep/timing race), so they are guaranteed alive while we measure;
//   3. re-reads cell_stat and asserts the aggregate grew by exactly N processes,
//      and that resident pages + handles grew (the children carry COW pages and
//      inherited handles);
//   4. closes the pipe so the children hit EOF and exit, reaps them;
//   5. re-reads cell_stat and asserts the process count is back to baseline —
//      a reaped process's charge is removed from the domain.
// The boot test (tests/c6_cell_accounting_test.sh) asserts on the "C6a OK" marker.

private let globalCellRaw: UInt32 = 1   // matches kernel globalCell = CellId(raw: 1)
private let childCount = 3

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

private func report(_ label: StaticString, _ s: swiftos_cell_stat) {
    swiftos_puts("C6a probe: ")
    label.withUTF8Buffer { buf in
        for b in buf { swiftos_putc(b) }
    }
    swiftos_puts(" processes=")
    putUInt(UInt(s.processes))
    swiftos_puts(" residentPages=")
    putUInt(UInt(s.resident_pages))
    swiftos_puts(" handles=")
    putUInt(UInt(s.handles))
    swiftos_putc(0x0A)
}

private func readCell() -> swiftos_cell_stat {
    var s = swiftos_cell_stat()
    _ = swiftos_cell_query(globalCellRaw, &s)
    return s
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp

    let base = readCell()
    report("baseline", base)

    // A pipe used purely as a liveness barrier: children block reading the read
    // end until the parent closes the write end, then they hit EOF and exit.
    var fds = [Int32](repeating: -1, count: 2)
    if fds.withUnsafeMutableBufferPointer({ swiftos_pipe($0.baseAddress) }) != 0 {
        swiftos_puts("C6a FAIL: pipe() failed\n")
        return 1
    }
    let rfd = fds[0]
    let wfd = fds[1]

    var kids = [Int32](repeating: 0, count: childCount)
    for i in 0..<childCount {
        let pid = swiftos_fork()
        if pid < 0 {
            swiftos_puts("C6a FAIL: fork() failed\n")
            return 1
        }
        if pid == 0 {
            // Child: drop the write end (so EOF can occur once the parent drops
            // its copy), then block until the parent releases the barrier.
            _ = swiftos_close(wfd)
            var byte: UInt8 = 0
            _ = swiftos_read(rfd, &byte, 1)   // blocks; returns 0 (EOF) on release
            return 0                          // crt0 _exits the child here
        }
        kids[i] = pid
    }

    // All children are forked and blocked in read(); measure the live domain.
    let live = readCell()
    report("with-children", live)

    var ok = true
    if live.processes != base.processes + UInt32(childCount) {
        swiftos_puts("C6a FAIL: process count did not grow by N\n"); ok = false
    }
    if live.resident_pages <= base.resident_pages {
        swiftos_puts("C6a FAIL: resident pages did not grow\n"); ok = false
    }
    if live.handles <= base.handles {
        swiftos_puts("C6a FAIL: handle count did not grow\n"); ok = false
    }

    // Release the barrier: closing both ends in the parent makes every child's
    // read() return EOF, so they exit; reap each one.
    _ = swiftos_close(wfd)
    _ = swiftos_close(rfd)
    for i in 0..<childCount {
        var status: Int32 = 0
        _ = swiftos_waitpid(kids[i], &status)
    }

    let after = readCell()
    report("after-reap", after)
    if after.processes != base.processes {
        swiftos_puts("C6a FAIL: reaped children still charged to the cell\n"); ok = false
    }

    if ok {
        swiftos_puts("C6a OK: per-cell accounting tracks live processes and reclaims reaped charge\n")
        return 0
    }
    return 1
}
