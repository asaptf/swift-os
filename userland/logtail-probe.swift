// SPDX-License-Identifier: Apache-2.0
// logtail-probe.swift — acceptance helper for the capLogExport gate.

private let capLogExport: UInt = 1 << 6
private let exportBufferCap = 8192

private func putUInt(_ value: UInt64) {
    var divisor: UInt64 = 1
    while value / divisor >= 10 { divisor *= 10 }
    var rest = value
    while divisor > 0 {
        swiftos_putc(0x30 + UInt8(rest / divisor))
        rest %= divisor
        divisor /= 10
    }
}

private func contains(_ base: UnsafeMutablePointer<UInt8>, _ len: Int,
                      _ needle: StaticString) -> Bool {
    return needle.withUTF8Buffer { nb in
        if nb.count == 0 { return true }
        if len < nb.count { return false }
        var i = 0
        while i <= len - nb.count {
            var j = 0
            while j < nb.count && base[i + j] == nb[j] { j += 1 }
            if j == nb.count { return true }
            i += 1
        }
        return false
    }
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp

    return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: exportBufferCap) { buf in
        let base = buf.baseAddress!

        let denied = swiftos_log_read(UnsafeMutableRawPointer(base), UInt(exportBufferCap), 8)
        if denied != -1 {
            swiftos_puts("LOGTAIL-PROBE-FAIL expected denial before capLogExport\n")
            return 1
        }

        var deniedCapacity: UInt = 0
        var deniedAvailable: UInt = 0
        var deniedTotal: UInt = 0
        var deniedOverwritten: UInt = 0
        let deniedStats = swiftos_log_stats(&deniedCapacity, &deniedAvailable,
                                            &deniedTotal, &deniedOverwritten)
        if deniedStats != -1 {
            swiftos_puts("LOGTAIL-PROBE-FAIL expected stats denial before capLogExport\n")
            return 1
        }
        swiftos_puts("LOGTAIL-PROBE-DENIED\n")

        var principal: UInt32 = 0
        var session: UInt32 = 0
        var caps: UInt = 0
        if swiftos_context(&principal, &session, &caps) != 0 {
            swiftos_puts("LOGTAIL-PROBE-FAIL context\n")
            return 1
        }
        if swiftos_login(principal, session, caps | capLogExport) != 0 {
            swiftos_puts("LOGTAIL-PROBE-FAIL grant\n")
            return 1
        }

        var afterPrincipal: UInt32 = 0
        var afterSession: UInt32 = 0
        var afterCaps: UInt = 0
        if swiftos_context(&afterPrincipal, &afterSession, &afterCaps) != 0 ||
            (afterCaps & capLogExport) == 0 {
            swiftos_puts("LOGTAIL-PROBE-FAIL grant-context\n")
            return 1
        }

        let n = swiftos_log_read(UnsafeMutableRawPointer(base), UInt(exportBufferCap), 96)
        if n <= 0 {
            swiftos_puts("LOGTAIL-PROBE-FAIL empty-export\n")
            return 1
        }
        let len = Int(n)
        if !contains(base, len, "tick=") ||
            !contains(base, len, " level=") ||
            !contains(base, len, " source=") ||
            !contains(base, len, " msg=\"") {
            swiftos_puts("LOGTAIL-PROBE-FAIL record-shape\n")
            return 1
        }

        var capacity: UInt = 0
        var available: UInt = 0
        var totalWritten: UInt = 0
        var overwritten: UInt = 0
        let statsRC = swiftos_log_stats(&capacity, &available, &totalWritten, &overwritten)
        if statsRC != 0 {
            swiftos_puts("LOGTAIL-PROBE-FAIL stats-read\n")
            return 1
        }
        if capacity != 256 || available == 0 || available > capacity ||
            totalWritten < available || overwritten > totalWritten {
            swiftos_puts("LOGTAIL-PROBE-FAIL stats-shape\n")
            return 1
        }

        swiftos_puts("LOGTAIL-PROBE-GRANTED bytes=")
        putUInt(UInt64(n))
        swiftos_puts("\nLOGTAIL-PROBE-RECORD-SHAPE\n")
        swiftos_puts("LOGTAIL-PROBE-STATS capacity=")
        putUInt(UInt64(capacity))
        swiftos_puts(" available=")
        putUInt(UInt64(available))
        swiftos_puts(" total=")
        putUInt(UInt64(totalWritten))
        swiftos_puts(" overwritten=")
        putUInt(UInt64(overwritten))
        swiftos_puts("\n")
        swiftos_puts("LOGTAIL-PROBE-BEGIN\n")
        _ = swiftos_write(1, UnsafeRawPointer(base), UInt(n))
        swiftos_puts("LOGTAIL-PROBE-END\n")
        return 0
    }
}
