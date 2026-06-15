// SPDX-License-Identifier: Apache-2.0
// pty.swift — pseudo-terminal objects (HC34).
//
// A PTY is a bidirectional terminal conduit between a *master* end (held by a
// terminal server such as /bin/sshd) and a *slave* end (the controlling tty of
// an interactive program such as the shell). It carries a per-instance line
// discipline on the master->slave (input) path:
//
//   master write -> line discipline --> cooked ring (slave reads)
//                                   \-> echo bytes -> output ring (master reads)
//   slave  write -> [ONLCR] --------------------> output ring (master reads)
//
//   master read  <- output ring          slave read <- cooked ring
//
// Unlike the console line discipline in tty.swift (which is driven from the UART
// IRQ and echoes straight to the PL011), a PTY is driven entirely from syscall
// context under the VFS lock, so it keeps its own buffers and editor state and
// echoes back to its own master. The termios local-flag bits (ttyICANON/ttyECHO)
// are shared with tty.swift.
//
// Job control (HC36): each PTY carries a foreground target (a process slot set
// via swiftos_pty_set_foreground). When ISIG is set, Ctrl-C (0x03) raises SIGINT
// to that target instead of being delivered as data — the per-process signal
// machinery (signal.swift / process.swift) makes this possible. A target blocked
// in a slave read notices the pending signal and returns so it can be delivered.
// Ctrl-\ (SIGQUIT) and Ctrl-Z (SIGTSTP, which needs stop semantics) are not yet
// handled. See docs/NOTES.md.

private let maxPtys = 8
private let ptyCookedCap = 1024   // slave-readable cooked input (whole lines)
private let ptyOutCap = 4096      // master-readable output (program output + echo)
private let ptyEditCap = 1024     // in-progress canonical line

private struct PtyState {
    var inUse = false
    var masterRefs = 0            // open descriptions on the master end
    var slaveRefs = 0             // open descriptions on the slave end
    var lflag: UInt32 = ttyICANON | ttyECHO | ttyISIG
    var fgPid = 0                 // foreground process pid for tty-generated signals (0 = none)
    var editPtr: UInt = 0
    var editLen = 0
    var cookedPtr: UInt = 0
    var cookedHead = 0
    var cookedTail = 0
    var outPtr: UInt = 0
    var outHead = 0
    var outTail = 0
}

private var ptys = [PtyState](repeating: PtyState(), count: maxPtys)

@inline(__always)
private func ptyBuf(_ addr: UInt) -> UnsafeMutablePointer<UInt8> {
    UnsafeMutablePointer<UInt8>(bitPattern: addr)!
}

// --- cooked ring (slave-readable) ---------------------------------------------

func ptyCookedCount(_ p: Int) -> Int {
    (ptys[p].cookedTail - ptys[p].cookedHead + ptyCookedCap) % ptyCookedCap
}

private func ptyCookedPush(_ p: Int, _ byte: UInt8) {
    let next = (ptys[p].cookedTail + 1) % ptyCookedCap
    if next == ptys[p].cookedHead { return } // full: drop
    ptyBuf(ptys[p].cookedPtr)[ptys[p].cookedTail] = byte
    ptys[p].cookedTail = next
}

func ptyCookedPop(_ p: Int) -> UInt8 {
    let byte = ptyBuf(ptys[p].cookedPtr)[ptys[p].cookedHead]
    ptys[p].cookedHead = (ptys[p].cookedHead + 1) % ptyCookedCap
    return byte
}

// --- output ring (master-readable) --------------------------------------------

func ptyOutCount(_ p: Int) -> Int {
    (ptys[p].outTail - ptys[p].outHead + ptyOutCap) % ptyOutCap
}

func ptyOutSpace(_ p: Int) -> Int { ptyOutCap - ptyOutCount(p) - 1 }

func ptyOutPush(_ p: Int, _ byte: UInt8) {
    let next = (ptys[p].outTail + 1) % ptyOutCap
    if next == ptys[p].outHead { return } // full: drop
    ptyBuf(ptys[p].outPtr)[ptys[p].outTail] = byte
    ptys[p].outTail = next
}

func ptyOutPop(_ p: Int) -> UInt8 {
    let byte = ptyBuf(ptys[p].outPtr)[ptys[p].outHead]
    ptys[p].outHead = (ptys[p].outHead + 1) % ptyOutCap
    return byte
}

// --- validity / lifecycle -----------------------------------------------------

func ptyValid(_ p: Int) -> Bool { p >= 0 && p < maxPtys && ptys[p].inUse }
func ptyMasterRefs(_ p: Int) -> Int { ptyValid(p) ? ptys[p].masterRefs : 0 }
func ptySlaveRefs(_ p: Int) -> Int { ptyValid(p) ? ptys[p].slaveRefs : 0 }
func ptySlaveLflag(_ p: Int) -> UInt32 { ptyValid(p) ? ptys[p].lflag : 0 }
func ptySetLflag(_ p: Int, _ value: UInt32) { if ptyValid(p) { ptys[p].lflag = value } }
func ptyForeground(_ p: Int) -> Int { ptyValid(p) ? ptys[p].fgPid : 0 }
func ptySetForeground(_ p: Int, _ pid: Int) { if ptyValid(p) { ptys[p].fgPid = pid } }

/// Allocate a PTY pair. Returns its index with masterRefs == slaveRefs == 1, or
/// -1 if no slot or buffer is available. Buffers are allocated once per slot and
/// retained across reuse (the kernel heap is a bump allocator).
func ptyAlloc() -> Int {
    for i in 0..<maxPtys where !ptys[i].inUse {
        if ptys[i].cookedPtr == 0 {
            guard let c = swiftos_kernel_alloc(UInt(ptyCookedCap), 16),
                  let o = swiftos_kernel_alloc(UInt(ptyOutCap), 16),
                  let e = swiftos_kernel_alloc(UInt(ptyEditCap), 16) else { return -1 }
            ptys[i].cookedPtr = UInt(bitPattern: c)
            ptys[i].outPtr = UInt(bitPattern: o)
            ptys[i].editPtr = UInt(bitPattern: e)
        }
        let cp = ptys[i].cookedPtr, op = ptys[i].outPtr, ep = ptys[i].editPtr
        ptys[i] = PtyState()
        ptys[i].cookedPtr = cp; ptys[i].outPtr = op; ptys[i].editPtr = ep
        ptys[i].inUse = true
        ptys[i].masterRefs = 1
        ptys[i].slaveRefs = 1
        ptys[i].lflag = ttyICANON | ttyECHO | ttyISIG
        return i
    }
    return -1
}

/// Drop one reference on the master or slave end. When both ends reach zero the
/// slot is reset for reuse (buffers stay attached).
func ptyReleaseEnd(_ p: Int, master: Bool) {
    guard ptyValid(p) else { return }
    if master {
        if ptys[p].masterRefs > 0 { ptys[p].masterRefs -= 1 }
    } else {
        if ptys[p].slaveRefs > 0 { ptys[p].slaveRefs -= 1 }
    }
    if ptys[p].masterRefs == 0 && ptys[p].slaveRefs == 0 {
        let cp = ptys[p].cookedPtr, op = ptys[p].outPtr, ep = ptys[p].editPtr
        ptys[p] = PtyState()
        ptys[p].cookedPtr = cp; ptys[p].outPtr = op; ptys[p].editPtr = ep
    }
}

// --- line discipline ----------------------------------------------------------

@inline(__always)
private func ptyEcho(_ p: Int, _ byte: UInt8) {
    if (ptys[p].lflag & ttyECHO) != 0 { ptyOutPush(p, byte) }
}

/// Feed one byte written to the master through the line discipline. Runs under
/// the VFS lock (never IRQ context).
func ptyInput(_ p: Int, _ byte: UInt8) {
    guard ptyValid(p) else { return }

    // Job control: with ISIG set and a foreground process designated, Ctrl-C
    // raises SIGINT to it rather than being delivered as data. Echo "^C\r\n"
    // (mirroring tty.swift) and discard any partially-typed canonical line. When
    // no foreground is set (a PTY that has not opted into job control, e.g. the
    // HC35 sshd shell), Ctrl-C falls through and is carried as an ordinary byte.
    if (ptys[p].lflag & ttyISIG) != 0 && byte == 0x03 && ptys[p].fgPid > 0 { // Ctrl-C (ETX)
        if (ptys[p].lflag & ttyECHO) != 0 {
            ptyOutPush(p, 0x5E); ptyOutPush(p, 0x43); ptyOutPush(p, 0x0D); ptyOutPush(p, 0x0A) // "^C\r\n"
        }
        ptys[p].editLen = 0
        signalRaiseSlot(ptys[p].fgPid - 1, SIGINT) // pid -> process slot
        return
    }

    if (ptys[p].lflag & ttyICANON) == 0 {
        // Raw mode: deliver verbatim; the foreground program does its own editing.
        ptyEcho(p, byte)
        ptyCookedPush(p, byte)
        return
    }

    // Minimal canonical editor: printable insert, backspace, line commit.
    if byte == 0x7F || byte == 0x08 { // DEL / Backspace
        if ptys[p].editLen > 0 {
            ptys[p].editLen -= 1
            if (ptys[p].lflag & ttyECHO) != 0 {
                ptyOutPush(p, 0x08); ptyOutPush(p, 0x20); ptyOutPush(p, 0x08)
            }
        }
        return
    }

    if byte == 0x0D || byte == 0x0A { // Enter: commit the line (ICRNL: store LF)
        if (ptys[p].lflag & ttyECHO) != 0 { ptyOutPush(p, 0x0D); ptyOutPush(p, 0x0A) }
        let edit = ptyBuf(ptys[p].editPtr)
        for i in 0..<ptys[p].editLen { ptyCookedPush(p, edit[i]) }
        ptyCookedPush(p, 0x0A)
        ptys[p].editLen = 0
        return
    }

    if ptys[p].editLen < ptyEditCap {
        ptyBuf(ptys[p].editPtr)[ptys[p].editLen] = byte
        ptys[p].editLen += 1
        ptyEcho(p, byte)
    }
}
