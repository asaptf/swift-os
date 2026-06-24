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

private let pageBytes = 4096
private let sbrkFail = UInt(bitPattern: -1)

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp
    swiftos_puts("CELLGROWER: alive, growing heap until the cap refuses\n")

    // 1. Grow the heap one page at a time until the cell's resident-page cap refuses.
    var grew = 0
    while swiftos_sbrk(Int(pageBytes)) != sbrkFail { grew += 1 }
    swiftos_puts("CELLGROWER: sbrk refused at the cap\n")

    // 2. Cross-path: an anonymous mmap must ALSO be refused now (same cap guard).
    let m = swiftos_mmap(UInt(pageBytes), SWIFTOS_PROT_READ | SWIFTOS_PROT_WRITE)
    if m == 0 {
        swiftos_puts("CELLGROWER: mmap also refused (cross-path)\n")
    } else {
        swiftos_puts("CELLGROWER FAIL: mmap succeeded past the cap\n")
    }

    // 3. Tell the supervisor we are capped-out and still alive (one byte on fd 2),
    //    so it can sample cell_stat while our resident set sits at the ceiling.
    var sig: UInt8 = 1
    _ = swiftos_write(2, &sig, 1)

    // 4. Block on the barrier until the supervisor closes it (EOF), then exit.
    var done: UInt8 = 0
    _ = swiftos_read(0, &done, 1)
    return 0
}
