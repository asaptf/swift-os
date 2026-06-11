// SPDX-License-Identifier: Apache-2.0
// logtail.swift — print a serialized kernel log ring tail.
//
// SYS_LOG_READ is capability-gated by capLogExport. Seeded accounts do not
// receive that authority by default, so normal operators see a clear denial
// unless a supervisor/admin context explicitly delegates it.

private let defaultMaxCount: UInt = 32
private let exportBufferCap = 8192

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

private func putUsage() {
    swiftos_puts("usage: logtail [max-records]\n")
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
        let parsed = parseUIntArg(argv?.advanced(by: 1).pointee)
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
