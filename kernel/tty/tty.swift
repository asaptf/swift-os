// tty.swift — console line discipline for the PL011 serial tty.
//
// Receives bytes from the UART IRQ (ttyOnInput) and serves read(0) (ttyRead).
// Two modes, selected by the termios local flags:
//   - canonical (ICANON): line-buffered with echo and backspace editing; a line
//     becomes readable only on Enter.
//   - raw: each byte is delivered as it arrives.
// ECHO controls echoing; ISIG makes Ctrl-C raise SIGINT to the foreground.
//
// Buffers are allocated once from the kernel heap so their addresses are stable.

// termios c_lflag bits (our own ABI; userland lib/termios.h must match).
let ttyICANON: UInt32 = 1 << 0
let ttyECHO: UInt32 = 1 << 1
let ttyISIG: UInt32 = 1 << 2

private var lflag: UInt32 = ttyICANON | ttyECHO | ttyISIG

private let editCap = 256
private let cookedCap = 1024
private var editBuf: UnsafeMutablePointer<UInt8>! = nil
private var editLen = 0          // characters in the current line
private var editPos = 0          // cursor index within the line (0...editLen)
private var cookedBuf: UnsafeMutablePointer<UInt8>! = nil
private var cookedHead = 0
private var cookedTail = 0

// Escape-sequence decoder for the cooked line editor: 0 = idle, 1 = saw ESC,
// 2 = inside a CSI ("ESC ["). escParam accumulates the numeric argument (for
// sequences like ESC [ 3 ~ = forward delete).
private var escState = 0
private var escParam = 0

func ttyInit() {
    guard let e = swiftos_kernel_alloc(UInt(editCap), 16),
          let c = swiftos_kernel_alloc(UInt(cookedCap), 16) else {
        uartPuts("panic: tty buffer allocation failed\n")
        while true {}
    }
    editBuf = e.bindMemory(to: UInt8.self, capacity: editCap)
    cookedBuf = c.bindMemory(to: UInt8.self, capacity: cookedCap)
}

func ttyGetLflag() -> UInt32 { lflag }
func ttySetLflag(_ value: UInt32) { lflag = value }
func ttyReadable() -> Bool { cookedCount() > 0 }

private func cookedCount() -> Int {
    (cookedTail - cookedHead + cookedCap) % cookedCap
}

private func cookedPush(_ byte: UInt8) {
    let next = (cookedTail + 1) % cookedCap
    if next == cookedHead { return } // full: drop (rare for interactive input)
    cookedBuf[cookedTail] = byte
    cookedTail = next
}

private func cookedPop() -> UInt8 {
    let byte = cookedBuf[cookedHead]
    cookedHead = (cookedHead + 1) % cookedCap
    return byte
}

@inline(__always)
private func echo(_ byte: UInt8) {
    if (lflag & ttyECHO) != 0 { uartPutc(byte) }
}

/// Reprint the line from `start` to the end, optionally erasing one trailing
/// glyph (after a deletion), then back the cursor up to `editPos`. This keeps
/// the visible terminal cursor aligned with `editPos` using only printable
/// bytes and backspaces — which both a real terminal and our framebuffer
/// console understand.
private func repaintTail(from start: Int, eraseExtra: Bool) {
    if (lflag & ttyECHO) == 0 { return }
    var col = start
    while col < editLen { uartPutc(editBuf[col]); col += 1 }
    if eraseExtra { uartPutc(0x20); col += 1 }
    while col > editPos { uartPutc(0x08); col -= 1 }
}

/// Handle a decoded cursor/edit action coming from an escape sequence.
private func ttyEditAction(_ final: UInt8) {
    switch final {
    case 0x44: // ESC [ D — left
        if editPos > 0 { editPos -= 1; echo(0x08) }
    case 0x43: // ESC [ C — right
        if editPos < editLen { echo(editBuf[editPos]); editPos += 1 }
    case 0x48: // ESC [ H — home
        while editPos > 0 { editPos -= 1; echo(0x08) }
    case 0x46: // ESC [ F — end
        while editPos < editLen { echo(editBuf[editPos]); editPos += 1 }
    case 0x7E where escParam == 3: // ESC [ 3 ~ — forward delete
        if editPos < editLen {
            var i = editPos
            while i < editLen - 1 { editBuf[i] = editBuf[i + 1]; i += 1 }
            editLen -= 1
            repaintTail(from: editPos, eraseExtra: true)
        }
    case 0x7E where escParam == 1 || escParam == 7: // ESC [ 1~/7~ — home
        while editPos > 0 { editPos -= 1; echo(0x08) }
    case 0x7E where escParam == 4 || escParam == 8: // ESC [ 4~/8~ — end
        while editPos < editLen { echo(editBuf[editPos]); editPos += 1 }
    default:
        break // ESC [ A/B (up/down): no history yet — ignore
    }
}

/// Feed one received byte through the line discipline. Runs in IRQ context.
func ttyOnInput(_ byte: UInt8) {
    if (lflag & ttyISIG) != 0 && byte == 0x03 { // Ctrl-C (ETX)
        if (lflag & ttyECHO) != 0 {
            uartPutc(0x5E); uartPutc(0x43); uartPutc(0x0D); uartPutc(0x0A) // "^C\r\n"
        }
        escState = 0
        signalRaise(SIGINT)
        return
    }

    if (lflag & ttyICANON) == 0 {
        // Raw mode: deliver bytes verbatim (escape sequences included) so the
        // foreground program does its own editing.
        if (lflag & ttyECHO) != 0 { uartPutc(byte) }
        cookedPush(byte)
        return
    }

    // Canonical mode: a small line editor with a movable cursor.
    if escState == 1 {
        escState = byte == 0x5B ? 2 : 0 // expect '[' after ESC; else abandon
        escParam = 0
        return
    }
    if escState == 2 {
        if byte >= 0x30 && byte <= 0x39 { // accumulate the numeric parameter
            escParam = escParam * 10 + Int(byte - 0x30)
            return
        }
        ttyEditAction(byte)
        escState = 0
        return
    }
    if byte == 0x1B { escState = 1; return } // ESC: start of a sequence

    if byte == 0x7F || byte == 0x08 { // DEL / Backspace: delete left of cursor
        if editPos > 0 {
            echo(0x08)
            var i = editPos - 1
            while i < editLen - 1 { editBuf[i] = editBuf[i + 1]; i += 1 }
            editLen -= 1
            editPos -= 1
            repaintTail(from: editPos, eraseExtra: true)
        }
        return
    }

    if byte == 0x0D || byte == 0x0A { // Enter: commit the line
        if (lflag & ttyECHO) != 0 { uartPutc(0x0D); uartPutc(0x0A) }
        for i in 0..<editLen { cookedPush(editBuf[i]) }
        cookedPush(0x0A)
        editLen = 0
        editPos = 0
        return
    }

    // A printable byte: insert at the cursor and shift the tail right.
    if editLen < editCap {
        var i = editLen
        while i > editPos { editBuf[i] = editBuf[i - 1]; i -= 1 }
        editBuf[editPos] = byte
        editLen += 1
        editPos += 1
        repaintTail(from: editPos - 1, eraseExtra: false)
    }
}

/// Backing for read(0). Blocks until input is available; in canonical mode a
/// whole line at a time.
///
/// The full trap frame (exceptions.S) makes it safe to unmask IRQs inside a
/// syscall, so we simply enable interrupts and wait: the UART IRQ fills the
/// cooked buffer, and Ctrl-C is delivered along the IRQ path (terminating the
/// process without returning here).
func ttyRead(buffer: UInt, count: UInt) -> Int {
    if count == 0 { return 0 }
    guard let dst = userWritableBuffer(buffer, count) else { return -22 }

    enable_irq()
    while cookedCount() == 0 {
        wfi()
    }

    var n = 0
    while n < Int(count) && cookedCount() > 0 {
        let byte = cookedPop()
        dst[n] = byte
        n += 1
        if (lflag & ttyICANON) != 0 && byte == 0x0A { break } // one line per read
    }
    return n
}
