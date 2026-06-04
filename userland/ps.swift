// ps.swift — minimal process listing utility for swift-os.

private let stateReady: UInt32 = 1
private let stateRunning: UInt32 = 2
private let stateBlocked: UInt32 = 3
private let stateZombie: UInt32 = 4
private let psMax: Int32 = 16

private func putSpaces(_ count: Int32) {
    var i: Int32 = 0
    while i < count {
        swiftos_putc(0x20)
        i += 1
    }
}

private func decimalWidth(_ value: UInt32) -> Int32 {
    var n = value
    var width: Int32 = 1
    while n >= 10 {
        n /= 10
        width += 1
    }
    return width
}

private func putUInt(_ value: UInt32) {
    var divisor: UInt32 = 1
    while value / divisor >= 10 {
        divisor *= 10
    }

    var rest = value
    while divisor > 0 {
        let digit = UInt8(rest / divisor)
        swiftos_putc(0x30 + digit)
        rest %= divisor
        divisor /= 10
    }
}

private func putPaddedUInt(_ value: UInt32, width: Int32) {
    putSpaces(width - decimalWidth(value))
    putUInt(value)
}

private func putState(_ state: UInt32) {
    if state == stateReady {
        swiftos_puts("READY ")
    } else if state == stateRunning {
        swiftos_puts("RUN   ")
    } else if state == stateBlocked {
        swiftos_puts("BLOCK ")
    } else if state == stateZombie {
        swiftos_puts("ZOMB  ")
    } else {
        swiftos_puts("?     ")
    }
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc
    _ = argv
    _ = envp

    let count = swiftos_ps_refresh()
    if count < 0 {
        swiftos_puts("ps: psinfo failed\n")
        return 1
    }

    swiftos_puts(" PID PPID STATE CMD\n")
    var i: Int32 = 0
    while i < count && i < psMax {
        putPaddedUInt(swiftos_ps_pid(i), width: 4)
        swiftos_putc(0x20)
        putPaddedUInt(swiftos_ps_ppid(i), width: 4)
        swiftos_putc(0x20)
        putState(swiftos_ps_state(i))
        if let name = swiftos_ps_name(i) {
            swiftos_puts(name)
        } else {
            swiftos_puts("?")
        }
        swiftos_putc(0x0A)
        i += 1
    }
    return 0
}
