// syscall.swift — tiny POSIX-like syscall dispatcher.

private let sysOpen: UInt = 1
private let sysRead: UInt = 2
private let sysWrite: UInt = 3
private let sysClose: UInt = 4
private let sysExit: UInt = 5
private let sysLseek: UInt = 6
private let sysTcGetAttr: UInt = 7  // tcgetattr(fd, termios*)
private let sysTcSetAttr: UInt = 8  // tcsetattr(fd, actions, termios*)
private let sysSigaction: UInt = 9  // sigaction(sig, handler)
private let sysKill: UInt = 10      // kill(pid, sig)
private let sysGetpid: UInt = 11    // getpid()

// Our termios layout (must match userland/lib/termios.h): four 32-bit flag
// words; only c_lflag (offset 12) is interpreted today.
private let termiosLflagOffset = 12

func syscallDispatch(number: UInt, frame: UnsafeMutablePointer<UInt>) {
    let result: Int

    if number == sysOpen {
        result = vfsOpen(path: frame[0], flags: frame[1])
    } else if number == sysRead {
        if Int(bitPattern: frame[0]) == 0 {
            result = ttyRead(buffer: frame[1], count: frame[2]) // stdin → tty
        } else {
            result = vfsRead(fd: Int(frame[0]), buffer: frame[1], count: frame[2])
        }
    } else if number == sysWrite {
        result = vfsWrite(fd: Int(frame[0]), buffer: frame[1], count: frame[2])
    } else if number == sysClose {
        result = vfsClose(fd: Int(frame[0]))
    } else if number == sysExit {
        // A process launched via processRunElf (M6) unwinds back to the kernel;
        // the standalone M5 EL0 probe (no active process) keeps its old banner.
        if processIsActive() {
            processExit(Int(bitPattern: frame[0])) // never returns
        }
        result = 0
        uartPuts("M5 OK: user open/read/write/close completed\n")
    } else if number == sysLseek {
        result = vfsLseek(fd: Int(frame[0]), offset: Int(frame[1]), whence: Int(frame[2]))
    } else if number == sysTcGetAttr {
        result = syscallTcGetAttr(termios: frame[1])
    } else if number == sysTcSetAttr {
        result = syscallTcSetAttr(termios: frame[2])
    } else if number == sysSigaction {
        signalSetDisposition(Int(bitPattern: frame[0]), frame[1])
        result = 0
    } else if number == sysKill {
        // Single foreground process model: deliver to ourselves immediately.
        signalRaise(Int(bitPattern: frame[1]))
        signalDeliverToForeground() // may not return (fatal default action)
        result = 0
    } else if number == sysGetpid {
        result = 1
    } else {
        result = -38 // ENOSYS
    }

    frame[0] = UInt(bitPattern: result)
}

private func syscallTcGetAttr(termios ptr: UInt) -> Int {
    guard let base = UnsafeMutablePointer<UInt8>(bitPattern: ptr) else { return -22 }
    let words = UnsafeMutableRawPointer(base)
    // Zero the four flag words, then publish the current c_lflag.
    words.storeBytes(of: UInt32(0), toByteOffset: 0, as: UInt32.self)
    words.storeBytes(of: UInt32(0), toByteOffset: 4, as: UInt32.self)
    words.storeBytes(of: UInt32(0), toByteOffset: 8, as: UInt32.self)
    words.storeBytes(of: ttyGetLflag(), toByteOffset: termiosLflagOffset, as: UInt32.self)
    return 0
}

private func syscallTcSetAttr(termios ptr: UInt) -> Int {
    guard let base = UnsafeRawPointer(bitPattern: ptr) else { return -22 }
    let lflag = base.load(fromByteOffset: termiosLflagOffset, as: UInt32.self)
    ttySetLflag(lflag)
    return 0
}
