// SPDX-License-Identifier: Apache-2.0
// logtail.swift — print a serialized kernel log ring tail.
//
// SYS_LOG_READ and SYS_LOG_STATS are capability-gated by capLogExport. Seeded
// accounts do not receive that authority by default, so normal operators see a
// clear denial unless a supervisor/admin context explicitly delegates it.

private let defaultMaxCount: UInt = 32
private let exportBufferCap = 8192

private func argEquals(_ p: UnsafeMutablePointer<CChar>?, _ literal: StaticString) -> Bool {
    guard let p else { return false }
    return literal.withUTF8Buffer { bytes in
        var i = 0
        while i < bytes.count {
            if p[i] == 0 { return false }
            if UInt8(bitPattern: p[i]) != bytes[i] { return false }
            i += 1
        }
        return p[i] == 0
    }
}

private func parseUIntArg(_ p: UnsafeMutablePointer<CChar>?) -> UInt {
    guard let p else { return 0 }
    var value: UInt = 0
    var i = 0
    while true {
        let c = p[i]
        if c == 0 { break }
        if c < 48 || c > 57 { return 0 }
        value = value * 10 + UInt(UInt8(bitPattern: c) - 48)
        i += 1
    }
    return i == 0 ? 0 : value
}

private func putUInt(_ value: UInt) {
    var divisor: UInt = 1
    while value / divisor >= 10 { divisor *= 10 }
    var rest = value
    while divisor > 0 {
        swiftos_putc(0x30 + UInt8(rest / divisor))
        rest %= divisor
        divisor /= 10
    }
}

private func putUsage() {
    swiftos_puts("usage: logtail [max-records]\n")
    swiftos_puts("       logtail --stats\n")
}

private func printStats() -> Int32 {
    var capacity: UInt = 0
    var available: UInt = 0
    var totalWritten: UInt = 0
    var overwritten: UInt = 0

    let rc = swiftos_log_stats(&capacity, &available, &totalWritten, &overwritten)
    if rc == -1 {
        swiftos_puts("logtail: stats permission denied (need capLogExport)\n")
        return 1
    }
    if rc != 0 {
        swiftos_puts("logtail: log stats failed\n")
        return 1
    }

    swiftos_puts("logtail: capacity=")
    putUInt(capacity)
    swiftos_puts(" available=")
    putUInt(available)
    swiftos_puts(" total=")
    putUInt(totalWritten)
    swiftos_puts(" overwritten=")
    putUInt(overwritten)
    swiftos_puts("\n")
    return 0
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp

    var maxCount = defaultMaxCount
    if argc > 2 {
        putUsage()
        return 2
    }
    if argc == 2 {
        let arg = argv?.advanced(by: 1).pointee
        if argEquals(arg, "--stats") {
            return printStats()
        }
        let parsed = parseUIntArg(arg)
        if parsed == 0 {
            putUsage()
            return 2
        }
        maxCount = parsed
    }

    return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: exportBufferCap) { buf in
        let base = buf.baseAddress!
        let n = swiftos_log_read(UnsafeMutableRawPointer(base), UInt(exportBufferCap), maxCount)
        if n == -1 {
            swiftos_puts("logtail: permission denied (need capLogExport)\n")
            return 1
        }
        if n < 0 {
            swiftos_puts("logtail: log export failed\n")
            return 1
        }
        if n == 0 { return 0 }
        _ = swiftos_write(1, UnsafeRawPointer(base), UInt(n))
        return 0
    }
}
