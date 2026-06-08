// SPDX-License-Identifier: Apache-2.0
// log.swift — minimal kernel logging facade (L0 + L1 ring + L2 filtering + L3 structured + L4 context).
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
// L4 (context slice) captures process/security context into the ring: pid=0 and
// principal=1 mean kernel/boot context; non-kernel entries print their compact
// context suffix in logDumpRecent.
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
    var pid: Int32       // 0 means no current process / kernel context
    var principal: UInt32 // 1 is the boot/root principal
}

// Static global ring. Initialiser materialises a small .data/.bss blob.
// Our first klog use is after M1 heap + timer, so this is fine.
private var ring: [LogEntry] = .init(
    repeating: LogEntry(tick: 0, level: .info, source: "", message: "", detail: 0, pid: 0, principal: 1),
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

private func currentLogContext() -> (pid: Int32, principal: UInt32) {
    (Int32(truncatingIfNeeded: processCurrentPid()), processCurrentPrincipal())
}

private func ringStore(_ entry: LogEntry) {
    // L3: ring now carries the optional detail; stored verbatim (0 = none).
    // L4: process/security context is already captured by the caller.
    ring[ringNext] = entry
    ringNext = (ringNext + 1) % ringCapacity
    if ringNext == 0 { ringFull = true }
}

private func klogAccepts(_ level: LogLevel) -> Bool {
    level == .panic || level.rawValue >= minLogLevel.rawValue
}

private func ringStoreContext(_ tick: UInt64, _ level: LogLevel,
                              _ source: StaticString, _ message: StaticString,
                              _ detail: UInt64) {
    let ctx = currentLogContext()
    ringStore(LogEntry(tick: tick, level: level, source: source, message: message,
                       detail: detail, pid: ctx.pid, principal: ctx.principal))
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
        if e.pid != 0 || e.principal != 1 {
            uartPuts(" pid=")
            uartPutUInt(UInt64(UInt32(bitPattern: e.pid)))
            uartPuts(" principal=")
            uartPutUInt(UInt64(e.principal))
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

/// Record an accepted log event into the in-memory ring without rendering a
/// live UART line. Use this for useful-but-chatty foreground process events
/// where writing to the console would perturb user-visible stdout/prompt tests.
func klogRing(_ level: LogLevel, _ source: StaticString, _ message: StaticString, _ detail: UInt64 = 0) {
    if !klogAccepts(level) { return }
    ringStoreContext(timerGetTicks(), level, source, message, detail)
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
/// - the in-memory record also captures the current pid/principal context for
///   later dumps; live UART lines intentionally keep the stable L0 format.
///
/// This function is safe to call:
/// - before timerInit / schedulerInit / heap;
/// - from IRQ handlers (the underlying uartPut* are polled);
/// - with IRQs masked (no locks are taken).
func klog(_ level: LogLevel, _ source: StaticString, _ message: StaticString, _ detail: UInt64 = 0) {
    // L2 filtering: drop everything below the current min level.
    // .panic is never filtered (always want the message + ring tail).
    if !klogAccepts(level) { return }

    let tick = timerGetTicks()

    uartPutc(0x5B) // [
    uartPutUInt(tick)
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
    // L4: pid/principal context travels with the ring entry, not the live line.
    ringStoreContext(tick, level, source, message, detail)
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

    let ctx = currentLogContext()
    let entry = LogEntry(tick: timerGetTicks(), level: .panic, source: "panic",
                         message: message, detail: 0, pid: ctx.pid, principal: ctx.principal)
    ringStore(entry)
    logDumpRecent(24)

    while true {}
}
