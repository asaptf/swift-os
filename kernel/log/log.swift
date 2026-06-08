// SPDX-License-Identifier: Apache-2.0
// log.swift — minimal kernel logging facade (L0 + L1 ring + L2 filtering + L3 structured).
//
// Provides klog(level, source, message) that renders timestamped, leveled,
// source-tagged records to the UART (and the framebuffer mirror via uartPutc).
// This establishes the vocabulary and calling shape required for future
// work: ring buffer, runtime filtering, structured payloads, capability-gated
// export, and shipping to a central collector for AI-assisted bug analysis.
//
// L0 was additive only (existing banners untouched).
// L1 adds an in-memory ring (overwrite) + logDumpRecent + automatic tail
// dump from kpanic paths.
// L2 adds global min-level filtering (default .info so debug is quiet;
// .panic always goes through). Ring only stores what passes the current filter.
// L3 (this slice) adds basic structured detail (UInt64, 0=none) to LogEntry and
// klog; detail is stored in the ring and rendered in logDumpRecent when non-zero.
// Callers use 4-arg form for detail; 3-arg form unchanged (default detail=0).
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

// MARK: - L1 ring buffer (fixed size, overwrite, StaticString entries)

private let ringCapacity = 256   // keep small and predictable

private struct LogEntry {
    var tick: UInt64
    var level: LogLevel
    var source: StaticString
    var message: StaticString
    var detail: UInt64   // 0 means no structured detail for this entry
}

// Static global ring. Initialiser materialises a small .data/.bss blob.
// Our first klog use is after M1 heap + timer, so this is fine.
private var ring: [LogEntry] = .init(
    repeating: LogEntry(tick: 0, level: .info, source: "", message: "", detail: 0),
    count: ringCapacity
)
private var ringNext = 0     // next write index
private var ringFull = false // set once we have wrapped at least once

// L2: global minimum level. Messages with level < minLogLevel are dropped
// (both from UART and from the ring) unless they are .panic.
// Default .info keeps the early boot "info" lines visible while suppressing
// chatter. Callers can raise/lower at runtime (e.g. from a debug console or
// capability-gated service later).
private var minLogLevel: LogLevel = .info

private func ringStore(_ entry: LogEntry) {
    // L3: ring now carries the optional detail; stored verbatim (0 = none).
    ring[ringNext] = entry
    ringNext = (ringNext + 1) % ringCapacity
    if ringNext == 0 { ringFull = true }
}

/// Dump the most recent `maxCount` entries (or all available) to the UART.
/// Entries are printed oldest-to-newest within the window.
/// Safe to call from panic paths, IRQ-masked code, etc. (only uses uartPuts).
func logDumpRecent(_ maxCount: Int = 32) {
    var n = maxCount
    if n <= 0 { return }

    let available = ringFull ? ringCapacity : ringNext
    if available == 0 {
        uartPuts("log: ring empty\n")
        return
    }
    if n > available { n = available }

    uartPuts("log: recent ")
    uartPutUInt(UInt64(n))
    uartPuts(" entries (oldest first):\n")

    let start = ringFull ? ringNext : 0
    for i in 0..<n {
        let idx = (start + i) % ringCapacity
        let e = ring[idx]

        uartPutc(0x5B) // [
        uartPutUInt(e.tick)
        uartPuts("] [")

        let ch = levelChar.withUTF8Buffer { buf in buf[Int(e.level.rawValue)] }
        uartPutc(ch)

        uartPuts("] ")
        uartPuts(e.source)
        uartPuts(": ")
        uartPuts(e.message)
        if e.detail != 0 {
            uartPuts(" detail=")
            uartPutUInt(e.detail)
        }
        uartPuts("\n")
    }
}

// MARK: - L2 runtime level control

/// Set the global minimum log level. Messages below this are dropped from
/// both the console and the ring (except .panic, which is never dropped).
/// This is the knob that will later be driven by boot options, a privileged
/// debug service, or per-cell policy.
func klogSetMinLevel(_ level: LogLevel) {
    minLogLevel = level
}

/// Current minimum level (for diagnostics / debug dumps).
func klogGetMinLevel() -> LogLevel {
    minLogLevel
}

/// Emit a log record.
///
/// The output line has the shape:
///   [tick] [L] source: message\n
/// (detail is not emitted on the live line in this L3 slice; it is recorded
/// and appears when the ring is dumped via logDumpRecent.)
///
/// - `tick` is the monotonic value from timerGetTicks() (0 if the timer is not
///   yet initialised — this path is exercised and useful for very early logs).
/// - `L` is a single character from levelChar.
/// - `source` and `message` are emitted verbatim (they are StaticString).
/// - `detail` (optional, default 0) carries a small structured numeric payload
///   (0 means "none"). Callers can use the 4-arg form without breaking any
///   existing 3-arg call sites: `klog(.info, "pmm", "free frames", pmmFreeCount())`.
///
/// This function is safe to call:
/// - before timerInit / schedulerInit / heap;
/// - from IRQ handlers (the underlying uartPut* are polled);
/// - with IRQs masked (no locks are taken).
func klog(_ level: LogLevel, _ source: StaticString, _ message: StaticString, _ detail: UInt64 = 0) {
    // L2 filtering: drop everything below the current min level.
    // .panic is never filtered (always want the message + ring tail).
    if level != .panic && level.rawValue < minLogLevel.rawValue {
        return
    }

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

    // L1: also record in the ring (cheap copy of StaticString).
    // L3: detail travels with the entry (0 = none).
    ringStore(LogEntry(tick: timerGetTicks(), level: level, source: source, message: message, detail: detail))
}

/// Convenience wrapper for the common "info" level.
func klogInfo(_ source: StaticString, _ message: StaticString) {
    klog(.info, source, message)
}

/// A panic-flavoured log that also provides a safe halting point.
/// Callers are still expected to dump additional diagnostics (ESR, etc.)
/// and then loop. The Never return helps the type checker in sites that
/// truly never continue.
///
/// L1: this path now also dumps the recent ring tail (after emitting the
/// panic line) so that the last events leading to the failure are visible
/// even if the console was quiet or wrapped.
func kpanic(_ message: StaticString) -> Never {
    uartPuts("panic: ")
    uartPuts(message)
    uartPuts("\n")

    let entry = LogEntry(tick: timerGetTicks(), level: .panic, source: "panic", message: message, detail: 0)
    ringStore(entry)
    logDumpRecent(24)

    while true {}
}
