// syscall.swift — tiny POSIX-like syscall dispatcher.

private let sysOpen: UInt = 1
private let sysRead: UInt = 2
private let sysWrite: UInt = 3
private let sysClose: UInt = 4
private let sysExit: UInt = 5
private let sysLseek: UInt = 6

func syscallDispatch(number: UInt, frame: UnsafeMutablePointer<UInt>) {
    let result: Int

    if number == sysOpen {
        result = vfsOpen(path: frame[0], flags: frame[1])
    } else if number == sysRead {
        result = vfsRead(fd: Int(frame[0]), buffer: frame[1], count: frame[2])
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
    } else {
        result = -38 // ENOSYS
    }

    frame[0] = UInt(bitPattern: result)
}
