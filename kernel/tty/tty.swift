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
private var editLen = 0
private var cookedBuf: UnsafeMutablePointer<UInt8>! = nil
private var cookedHead = 0
private var cookedTail = 0

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

/// Feed one received byte through the line discipline. Runs in IRQ context.
func ttyOnInput(_ byte: UInt8) {
    if (lflag & ttyISIG) != 0 && byte == 0x03 { // Ctrl-C (ETX)
        if (lflag & ttyECHO) != 0 {
            uartPutc(0x5E); uartPutc(0x43); uartPutc(0x0D); uartPutc(0x0A) // "^C\r\n"
        }
        signalRaise(SIGINT)
        return
    }

    if (lflag & ttyICANON) == 0 {
        if (lflag & ttyECHO) != 0 { uartPutc(byte) }
        cookedPush(byte)
        return
    }

    // Canonical mode.
    if byte == 0x7F || byte == 0x08 { // DEL / Backspace
        if editLen > 0 {
            editLen -= 1
            if (lflag & ttyECHO) != 0 {
                uartPutc(0x08); uartPutc(0x20); uartPutc(0x08) // erase one glyph
            }
        }
        return
    }

    if byte == 0x0D || byte == 0x0A { // Enter: commit the line
        if (lflag & ttyECHO) != 0 { uartPutc(0x0D); uartPutc(0x0A) }
        for i in 0..<editLen { cookedPush(editBuf[i]) }
        cookedPush(0x0A)
        editLen = 0
        return
    }

    if editLen < editCap {
        editBuf[editLen] = byte
        editLen += 1
        if (lflag & ttyECHO) != 0 { uartPutc(byte) }
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
