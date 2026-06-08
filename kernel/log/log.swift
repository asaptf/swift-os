// SPDX-License-Identifier: Apache-2.0
// log.swift — minimal kernel logging facade (L0).
//
// Provides klog(level, source, message) that renders timestamped, leveled,
// source-tagged records to the UART (and the framebuffer mirror via uartPutc).
// This establishes the vocabulary and calling shape required for future
// work: ring buffer, runtime filtering, structured payloads, capability-gated
// export, and shipping to a central collector for AI-assisted bug analysis.
//
// L0 is deliberately additive only:
// - Existing uartPuts("M3 OK: ...") / "panic: ..." banners are left unchanged
//   so that every boot_test.sh, busybox_test.sh, etc. expectation continues
//   to match byte-for-byte.
// - New events (and future code) use klog.
// - No ring, no filtering, no userland API yet.
//
// The design favours:
// - value types + StaticString (no allocation, valid for the life of the image);
// - early-boot safety (works before timerInit, before heap, with IRQs masked);
// - a machine-greppable prefix that is also still pleasant on a serial console.

/// Log severity. The numeric order is intentional for potential bitmask or
/// "minimum level" comparisons later.
enum LogLevel: UInt8 {
    case debug = 0
    case info  = 1
    case warn  = 2
    case error = 3
    case panic = 4
}

private let levelChar: StaticString = "DIWEP"

/// Emit a log record.
///
/// The output line has the shape:
///   [tick] [L] source: message\n
///
/// - `tick` is the monotonic value from timerGetTicks() (0 if the timer is not
///   yet initialised — this path is exercised and useful for very early logs).
/// - `L` is a single character from levelChar.
/// - `source` and `message` are emitted verbatim (they are StaticString).
///
/// This function is safe to call:
/// - before timerInit / schedulerInit / heap;
/// - from IRQ handlers (the underlying uartPut* are polled);
/// - with IRQs masked (no locks are taken).
func klog(_ level: LogLevel, _ source: StaticString, _ message: StaticString) {
    uartPutc(0x5B) // [
    uartPutUInt(timerGetTicks())
    uartPuts("] [")

    let ch = levelChar.withUTF8Buffer { buf in
        buf[Int(level.rawValue)]
    }
    uartPutc(ch)

    uartPuts("] ")
    uartPuts(source)
    uartPuts(": ")
    uartPuts(message)
    uartPuts("\n")
}

/// Convenience wrapper for the common "info" level.
func klogInfo(_ source: StaticString, _ message: StaticString) {
    klog(.info, source, message)
}

/// A panic-flavoured log that also provides a safe halting point.
/// Callers are still expected to dump additional diagnostics (ESR, etc.)
/// and then loop. The Never return helps the type checker in sites that
/// truly never continue.
func kpanic(_ message: StaticString) -> Never {
    klog(.panic, "panic", message)
    // Belt-and-suspenders halt. Real panic sites usually do their own
    // register dump + "while true {}" (or wfi) after the message; this
    // just guarantees we do not accidentally return into broken code.
    while true {}
}
