// SPDX-License-Identifier: Apache-2.0
// backtrace.swift — bounded EL0 frame-pointer chain dump for fault reports.
//
// When a user process takes a fatal synchronous fault the first log line already
// carries ESR/ELR/FAR/SP_EL0/FP. A runaway recursion still only shows that SP
// walked off the mapped stack; the FP chain is what identifies which call site
// burned the stack. Walk that chain through the validated user-access helpers
// only: a corrupt, hostile, or half-unmapped FP list must stop cleanly and never
// panic the kernel.

/// Cap the dump so a deep chain cannot flood the serial console. 24 levels is
/// enough to show the call path above a collapsed recursion run.
private let el0BacktraceMaxDepth = 24

/// Load one little-endian UInt64 from a validated user VA, or nil if the 8-byte
/// range is not fully mapped in the current process address space.
private func userLoadU64(_ va: UInt) -> UInt64? {
    guard let base = userReadableBuffer(va, 8) else { return nil }
    // Byte-wise assemble so a misaligned (corrupt) FP never triggers a
    // strict-align fault at EL1; the walk simply ends on the next bad frame.
    let p = UnsafeRawPointer(base)
    var v: UInt64 = 0
    var i = 0
    while i < 8 {
        v |= UInt64(p.load(fromByteOffset: i, as: UInt8.self)) << (i * 8)
        i += 1
    }
    return v
}

/// Walk the AAPCS64 frame-pointer chain starting at `fp` (x29 from the trap
/// frame). Each level's return address is at `[FP + 8]`; the caller's FP is at
/// `[FP]`. Consecutive identical LRs are collapsed into one line with a count so
/// a runaway recursion is greppable as a single repeated-LR entry.
func logEl0UserBacktrace(fp: UInt) {
    var curFP = fp
    var prevFP: UInt = 0
    var depth = 0

    var haveRun = false
    var runLR: UInt = 0
    var runCount: UInt = 0

    func flushRun() {
        if !haveRun { return }
        uartPuts("EL0 backtrace: LR=")
        uartPutHex(runLR)
        uartPuts(" count=")
        uartPutUInt(UInt64(runCount))
        uartPuts("\n")
    }

    while depth < el0BacktraceMaxDepth {
        // Null terminator, or a non-increasing FP (stack grows down so a valid
        // walk strictly increases). The non-increasing check also kills a
        // self-referential cycle without looping forever.
        if curFP == 0 { break }
        if prevFP != 0 && curFP <= prevFP { break }
        // AAPCS64 frame records are 16-byte aligned; anything else is corrupt.
        if (curFP & 0xF) != 0 { break }

        guard let nextFP64 = userLoadU64(curFP) else { break }
        guard let lr64 = userLoadU64(curFP &+ 8) else { break }
        let nextFP = UInt(nextFP64)
        let lr = UInt(lr64)

        if haveRun && lr == runLR {
            runCount &+= 1
        } else {
            flushRun()
            runLR = lr
            runCount = 1
            haveRun = true
        }

        prevFP = curFP
        curFP = nextFP
        depth &+= 1
    }
    flushRun()
}
