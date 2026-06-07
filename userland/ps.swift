// SPDX-License-Identifier: Apache-2.0
// ps.swift — small process listing utility for swift-os.

private let stateReady: UInt32 = 1
private let stateRunning: UInt32 = 2
private let stateBlocked: UInt32 = 3
private let stateZombie: UInt32 = 4
private let psMax: Int32 = 16

private let modeDefault: Int32 = 0
private let modeFull: Int32 = 1
private let modeAux: Int32 = 2
private let modeCustom: Int32 = 3

private let fieldPid: Int32 = 1
private let fieldPpid: Int32 = 2
private let fieldState: Int32 = 3
private let fieldStat: Int32 = 4
private let fieldCmd: Int32 = 5
private let fieldUser: Int32 = 6
private let fieldUid: Int32 = 7

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

private func putStat(_ state: UInt32) {
    if state == stateZombie {
        swiftos_putc(0x5A) // Z
    } else if state == stateBlocked {
        swiftos_putc(0x53) // S
    } else if state == stateReady || state == stateRunning {
        swiftos_putc(0x52) // R
    } else {
        swiftos_putc(0x3F) // ?
    }
}

private func putName(_ index: Int32) {
    if let name = swiftos_ps_name(index) {
        swiftos_puts(name)
    } else {
        swiftos_puts("?")
    }
}

private func byteAt(_ s: UnsafePointer<CChar>, _ index: Int32) -> UInt8 {
    UInt8(bitPattern: s[Int(index)])
}

private func cStringEquals(_ s: UnsafePointer<CChar>, _ expected: StaticString) -> Bool {
    var ok = true
    expected.withUTF8Buffer { e in
        var i = 0
        while i < e.count {
            if byteAt(s, Int32(i)) != e[i] { ok = false; return }
            i += 1
        }
        if byteAt(s, Int32(e.count)) != 0 { ok = false }
    }
    return ok
}

private func tokenEquals(_ s: UnsafePointer<CChar>, _ start: Int32, _ end: Int32,
                         _ expected: StaticString) -> Bool {
    var ok = true
    expected.withUTF8Buffer { e in
        if end - start != Int32(e.count) {
            ok = false
            return
        }
        var i: Int32 = 0
        while i < Int32(e.count) {
            let b = byteAt(s, start + i)
            let folded = (b >= 0x41 && b <= 0x5A) ? b + 0x20 : b
            if folded != e[Int(i)] { ok = false; return }
            i += 1
        }
    }
    return ok
}

private func decimalPrefix(_ s: UnsafePointer<CChar>, _ start: inout Int32) -> UInt32 {
    var value: UInt32 = 0
    while byteAt(s, start) >= 0x30 && byteAt(s, start) <= 0x39 {
        value = value * 10 + UInt32(byteAt(s, start) - 0x30)
        start += 1
    }
    return value
}

private func pidMatches(_ spec: UnsafePointer<CChar>?, _ pid: UInt32) -> Bool {
    guard let spec else { return true }
    var i: Int32 = 0
    while byteAt(spec, i) != 0 {
        while byteAt(spec, i) == 0x20 || byteAt(spec, i) == 0x2C { i += 1 }
        if byteAt(spec, i) == 0 { break }
        let parsed = decimalPrefix(spec, &i)
        if parsed == pid { return true }
        while byteAt(spec, i) != 0 && byteAt(spec, i) != 0x2C { i += 1 }
    }
    return false
}

private func fieldKind(_ spec: UnsafePointer<CChar>, _ start: Int32, _ end: Int32) -> Int32 {
    if tokenEquals(spec, start, end, "pid") { return fieldPid }
    if tokenEquals(spec, start, end, "ppid") { return fieldPpid }
    if tokenEquals(spec, start, end, "state") { return fieldState }
    if tokenEquals(spec, start, end, "stat") || tokenEquals(spec, start, end, "s") { return fieldStat }
    if tokenEquals(spec, start, end, "cmd") || tokenEquals(spec, start, end, "comm") ||
        tokenEquals(spec, start, end, "command") || tokenEquals(spec, start, end, "args") {
        return fieldCmd
    }
    if tokenEquals(spec, start, end, "user") { return fieldUser }
    if tokenEquals(spec, start, end, "uid") { return fieldUid }
    return 0
}

private func putFieldHeader(_ field: Int32) {
    if field == fieldPid {
        swiftos_puts("PID")
    } else if field == fieldPpid {
        swiftos_puts("PPID")
    } else if field == fieldState {
        swiftos_puts("STATE")
    } else if field == fieldStat {
        swiftos_puts("STAT")
    } else if field == fieldCmd {
        swiftos_puts("CMD")
    } else if field == fieldUser {
        swiftos_puts("USER")
    } else if field == fieldUid {
        swiftos_puts("UID")
    }
}

private func putFieldValue(_ field: Int32, _ index: Int32) {
    if field == fieldPid {
        putUInt(swiftos_ps_pid(index))
    } else if field == fieldPpid {
        putUInt(swiftos_ps_ppid(index))
    } else if field == fieldState {
        putState(swiftos_ps_state(index))
    } else if field == fieldStat {
        putStat(swiftos_ps_state(index))
    } else if field == fieldCmd {
        putName(index)
    } else if field == fieldUser {
        swiftos_puts("root")
    } else if field == fieldUid {
        swiftos_putc(0x30)
    }
}

private func putCustomHeader(_ spec: UnsafePointer<CChar>) -> Bool {
    var first = true
    var i: Int32 = 0
    while byteAt(spec, i) != 0 {
        while byteAt(spec, i) == 0x20 || byteAt(spec, i) == 0x2C { i += 1 }
        let start = i
        while byteAt(spec, i) != 0 && byteAt(spec, i) != 0x2C { i += 1 }
        var end = i
        while end > start && byteAt(spec, end - 1) == 0x20 { end -= 1 }
        if end > start {
            let field = fieldKind(spec, start, end)
            if field == 0 { return false }
            if !first { swiftos_putc(0x20) }
            putFieldHeader(field)
            first = false
        }
    }
    swiftos_putc(0x0A)
    return !first
}

private func customSpecIsSupported(_ spec: UnsafePointer<CChar>) -> Bool {
    var sawField = false
    var i: Int32 = 0
    while byteAt(spec, i) != 0 {
        while byteAt(spec, i) == 0x20 || byteAt(spec, i) == 0x2C { i += 1 }
        let start = i
        while byteAt(spec, i) != 0 && byteAt(spec, i) != 0x2C { i += 1 }
        var end = i
        while end > start && byteAt(spec, end - 1) == 0x20 { end -= 1 }
        if end > start {
            if fieldKind(spec, start, end) == 0 { return false }
            sawField = true
        }
    }
    return sawField
}

private func putCustomRow(_ spec: UnsafePointer<CChar>, _ index: Int32) {
    var first = true
    var i: Int32 = 0
    while byteAt(spec, i) != 0 {
        while byteAt(spec, i) == 0x20 || byteAt(spec, i) == 0x2C { i += 1 }
        let start = i
        while byteAt(spec, i) != 0 && byteAt(spec, i) != 0x2C { i += 1 }
        var end = i
        while end > start && byteAt(spec, end - 1) == 0x20 { end -= 1 }
        if end > start {
            if !first { swiftos_putc(0x20) }
            putFieldValue(fieldKind(spec, start, end), index)
            first = false
        }
    }
    swiftos_putc(0x0A)
}

private func usage() {
    swiftos_puts("usage: ps [-eA] [-f] [-p pid[,pid...]] [-o pid,ppid,state,stat,user,uid,cmd]\n")
    swiftos_puts("       ps aux\n")
}

private func optionBody(_ arg: UnsafePointer<CChar>, _ offset: Int32) -> UnsafePointer<CChar> {
    UnsafeRawPointer(arg).advanced(by: Int(offset)).assumingMemoryBound(to: CChar.self)
}

private func isBsdPsSyntax(_ arg: UnsafePointer<CChar>, _ start: Int32) -> Bool {
    var i = start
    var saw = false
    while byteAt(arg, i) != 0 {
        let ch = byteAt(arg, i)
        if ch != 0x61 && ch != 0x75 && ch != 0x78 { return false } // a/u/x
        saw = true
        i += 1
    }
    return saw
}

private func hasBsdUserFlag(_ arg: UnsafePointer<CChar>, _ start: Int32) -> Bool {
    var i = start
    while byteAt(arg, i) != 0 {
        if byteAt(arg, i) == 0x75 { return true } // u
        i += 1
    }
    return false
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp

    var mode = modeDefault
    var filterSpec: UnsafePointer<CChar>? = nil
    var customSpec: UnsafePointer<CChar>? = nil

    var argi: Int32 = 1
    while argi < argc {
        guard let rawArg = argv?[Int(argi)] else { return 1 }
        let arg = UnsafePointer<CChar>(rawArg)

        if cStringEquals(arg, "--help") || cStringEquals(arg, "-h") {
            usage()
            return 0
        } else if isBsdPsSyntax(arg, 0) {
            if hasBsdUserFlag(arg, 0) { mode = modeAux }
        } else if cStringEquals(arg, "-o") {
            argi += 1
            if argi >= argc || argv?[Int(argi)] == nil {
                swiftos_puts("ps: -o requires a field list\n")
                return 1
            }
            customSpec = UnsafePointer<CChar>(argv![Int(argi)]!)
            mode = modeCustom
        } else if byteAt(arg, 0) == 0x2D && byteAt(arg, 1) == 0x6F {
            customSpec = optionBody(arg, 2)
            mode = modeCustom
        } else if cStringEquals(arg, "-p") {
            argi += 1
            if argi >= argc || argv?[Int(argi)] == nil {
                swiftos_puts("ps: -p requires a pid list\n")
                return 1
            }
            filterSpec = UnsafePointer<CChar>(argv![Int(argi)]!)
        } else if byteAt(arg, 0) == 0x2D && byteAt(arg, 1) == 0x70 {
            filterSpec = optionBody(arg, 2)
        } else if byteAt(arg, 0) == 0x2D {
            if isBsdPsSyntax(arg, 1) {
                if hasBsdUserFlag(arg, 1) { mode = modeAux }
                argi += 1
                continue
            }
            var j: Int32 = 1
            while byteAt(arg, j) != 0 {
                let ch = byteAt(arg, j)
                if ch == 0x65 || ch == 0x41 { // -e / -A: all processes (already the default).
                } else if ch == 0x66 { // -f
                    if mode != modeCustom { mode = modeFull }
                } else {
                    swiftos_puts("ps: unsupported option\n")
                    usage()
                    return 1
                }
                j += 1
            }
        } else {
            swiftos_puts("ps: unsupported syntax\n")
            usage()
            return 1
        }
        argi += 1
    }

    if mode == modeCustom {
        guard let spec = customSpec else {
            swiftos_puts("ps: -o requires a field list\n")
            return 1
        }
        if !customSpecIsSupported(spec) {
            swiftos_puts("ps: unsupported -o field\n")
            return 1
        }
        _ = putCustomHeader(spec)
    } else if mode == modeFull {
        swiftos_puts("UID   PID  PPID STATE CMD\n")
    } else if mode == modeAux {
        swiftos_puts("USER   PID  PPID STAT COMMAND\n")
    } else {
        swiftos_puts(" PID PPID STATE CMD\n")
    }

    let count = swiftos_ps_refresh()
    if count < 0 {
        swiftos_puts("ps: psinfo failed\n")
        return 1
    }

    var i: Int32 = 0
    while i < count && i < psMax {
        if pidMatches(filterSpec, swiftos_ps_pid(i)) {
            if mode == modeCustom {
                putCustomRow(customSpec!, i)
            } else if mode == modeFull {
                swiftos_puts("root ")
                putPaddedUInt(swiftos_ps_pid(i), width: 5)
                swiftos_putc(0x20)
                putPaddedUInt(swiftos_ps_ppid(i), width: 5)
                swiftos_putc(0x20)
                putState(swiftos_ps_state(i))
                putName(i)
                swiftos_putc(0x0A)
            } else if mode == modeAux {
                swiftos_puts("root ")
                putPaddedUInt(swiftos_ps_pid(i), width: 5)
                swiftos_putc(0x20)
                putPaddedUInt(swiftos_ps_ppid(i), width: 5)
                swiftos_putc(0x20)
                putStat(swiftos_ps_state(i))
                swiftos_puts("    ")
                putName(i)
                swiftos_putc(0x0A)
            } else {
                putPaddedUInt(swiftos_ps_pid(i), width: 4)
                swiftos_putc(0x20)
                putPaddedUInt(swiftos_ps_ppid(i), width: 4)
                swiftos_putc(0x20)
                putState(swiftos_ps_state(i))
                putName(i)
                swiftos_putc(0x0A)
            }
        }
        i += 1
    }
    return 0
}
