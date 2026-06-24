// SPDX-License-Identifier: Apache-2.0
// cellopener.swift — the workload a C7b cell supervisor launches into a cell with a
// HANDLE cap.
//
// It tries to grow its OWN handle table past the cell's handle cap, proving C7b's
// enforcement at the user-facing handle constructors: open() is refused with EMFILE
// once the cell's aggregate handle count reaches the cap, not just at spawn time. It:
//   1. open()s a readable file (/etc/motd) over and over, never closing, until the
//      kernel refuses with EMFILE (-24);
//   2. signals the supervisor (a byte on fd 2) that it is capped-out yet still alive,
//      so the supervisor can sample cell_stat and assert handles <= cap;
//   3. blocks on the barrier (fd 0) until the supervisor releases it (EOF), then exits.
// It is granted exactly three handles: barrier-read (fd 0), stdout (fd 1), signal-write
// (fd 2). No timing assumptions — the supervisor controls teardown.

private let oRdOnly: Int32 = 0
private let eMFile: Int32 = -24   // EMFILE — the handle cap refused an open
private let openSafetyLimit = 1024

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp
    swiftos_puts("CELLOPENER: alive, opening files until the cap refuses\n")

    // 1. Open (never close) until the cell handle cap refuses.
    var opened = 0
    var lastErr: Int32 = 0
    while opened < openSafetyLimit {
        let fd = swiftos_open("/etc/motd", oRdOnly)
        if fd < 0 { lastErr = Int32(fd); break }
        opened += 1
    }
    if lastErr == eMFile {
        swiftos_puts("CELLOPENER: open refused at the cap (EMFILE)\n")
    } else {
        swiftos_puts("CELLOPENER FAIL: open refused with unexpected errno\n")
    }

    // 2. Tell the supervisor we are capped-out and still alive (one byte on fd 2),
    //    so it can sample cell_stat while our handle table sits at the ceiling.
    var sig: UInt8 = 1
    _ = swiftos_write(2, &sig, 1)

    // 3. Block on the barrier until the supervisor closes it (EOF), then exit.
    var done: UInt8 = 0
    _ = swiftos_read(0, &done, 1)
    return 0
}
