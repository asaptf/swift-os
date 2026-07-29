// SPDX-License-Identifier: Apache-2.0
// cellgrower.swift — the workload a C7a cell supervisor launches into a CAPPED cell.
//
// Unlike the C6d cellchild (which just blocks), this one actively tries to grow its
// OWN resident footprint past the cell's resident-page cap, proving C7a's intra-member
// enforcement: the cap is checked at the per-process growth sites (sbrk/mmap), not only
// at spawn-into-cell time. It:
//   1. sbrk()s one page at a time until the kernel refuses the grow (the cap bites);
//   2. confirms a fresh anon mmap is ALSO refused now (cross-path: both growth paths
//      consult the same cell-cap guard);
//   3. signals the supervisor (a byte on fd 2) that it is capped-out yet still alive,
//      so the supervisor can sample cell_stat and assert residentPages <= cap;
//   4. blocks on the barrier (fd 0) until the supervisor releases it (EOF), then exits.
// It is granted exactly three handles: barrier-read (fd 0), stdout (fd 1), signal-write
// (fd 2). No timing assumptions — the supervisor controls teardown.
//
// Silence is not an outcome: every refusal path prints a distinguishable line (grew
// count, zero-growth FAIL, mmap FAIL). The supervisor still gets the signal byte even
// on FAIL so it cannot hang waiting for a grower that already died.

private let pageBytes = 4096
private let sbrkFail = UInt(bitPattern: -1)

// Stack-only digit printer. After sbrk has burned the cell's page cap, any
// heap allocation (e.g. Array) would re-enter sbrk, fail, and trap the process
// before it can signal the supervisor — a mute hang for the probe. Keep this
// off the heap.
private func putUInt(_ value: UInt) {
    if value == 0 { swiftos_putc(0x30); return }
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 20) { digits in
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
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp
    var ok = true
    swiftos_puts("CELLGROWER: alive, growing heap until the cap refuses\n")

    // 1. Grow the heap one page at a time until the cell's resident-page cap refuses.
    var grew = 0
    while swiftos_sbrk(Int(pageBytes)) != sbrkFail { grew += 1 }
    if grew == 0 {
        // Cap already below the process's base footprint (ELF + stack), or growth
        // was refused for some other reason before any page committed. That is not
        // "the cap bit mid-member" — report it loudly.
        swiftos_puts("CELLGROWER FAIL: sbrk refused with zero growth (cap below base footprint?)\n")
        ok = false
    } else {
        swiftos_puts("CELLGROWER: sbrk refused at the cap after growing ")
        putUInt(UInt(grew))
        swiftos_puts(" pages\n")
        // Keep the historical marker the harness awaits (substring match on the
        // "sbrk refused at the cap" phrase).
        swiftos_puts("CELLGROWER: sbrk refused at the cap\n")
    }

    // 2. Cross-path: an anonymous mmap must ALSO be refused now (same cap guard).
    let m = swiftos_mmap(UInt(pageBytes), SWIFTOS_PROT_READ | SWIFTOS_PROT_WRITE)
    if m == 0 {
        swiftos_puts("CELLGROWER: mmap also refused (cross-path)\n")
    } else {
        swiftos_puts("CELLGROWER FAIL: mmap succeeded past the cap\n")
        ok = false
    }

    // 3. Tell the supervisor we are capped-out and still alive (one byte on fd 2),
    //    so it can sample cell_stat while our resident set sits at the ceiling.
    //    Always signal — even on FAIL — so the supervisor cannot hang on read.
    var sig: UInt8 = ok ? 1 : 0
    let wn = swiftos_write(2, &sig, 1)
    if wn != 1 {
        swiftos_puts("CELLGROWER FAIL: signal write to supervisor failed\n")
        ok = false
    }

    // 4. Block on the barrier until the supervisor closes it (EOF), then exit.
    var done: UInt8 = 0
    _ = swiftos_read(0, &done, 1)
    return ok ? 0 : 1
}
