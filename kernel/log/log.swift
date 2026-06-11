// SPDX-License-Identifier: Apache-2.0
// log.swift — minimal kernel logging facade (L0 + L1 ring + L2 filtering + L3 structured + L4 context/filtering).
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
// L4 (filter slice) adds a tiny per-source min-level override table on top of
// the global min level. Overrides match exact StaticString source tags.
// L4 (wire slice) adds allocation-free key=value formatting for recent ring
// entries. This is the stable shape future log export can consume.
// L4 (sink slice) routes live records through a tiny current-sink dispatch and
// adds capability hook helpers for future userland log export/sink install.
// L5b publishes ring stats for capability-gated local diagnostics.
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
private var ringTotalWritten: UInt64 = 0 // accepted records stored since boot

// L2: global minimum level. Messages with level < minLogLevel are dropped
// (both from UART and from the ring) unless they are .panic.
// Default .info keeps the early boot "info" lines visible while suppressing
// chatter. Callers can raise/lower at runtime (e.g. from a debug console or
// capability-gated service later).
private var minLogLevel: LogLevel = .info

// L4b: per-source min-level overrides. Kept deliberately small and fixed-size:
// no heap traffic, no dictionaries, exact StaticString byte match.
private let maxSourceOverrides = 8

private struct SourceMin {
    var source: StaticString = ""
    var minLevel: LogLevel = .debug
}

private var sourceMins: [SourceMin] = .init(
    repeating: SourceMin(),
    count: maxSourceOverrides
)
private var sourceMinCount = 0

// L4d: current live sink. Keep this tiny: no protocols/existentials/classes on
// the hot klog path. Future slices can add a userland/IPC sink kind behind the
// same switch once the service model exists.
enum LogSinkKind: UInt8 {
    case uart = 0
}

private struct LogSink {
    var kind: LogSinkKind = .uart
}

private var currentLogSink = LogSink()

private func currentLogContext() -> (pid: Int32, principal: UInt32) {
    (Int32(truncatingIfNeeded: processCurrentPid()), processCurrentPrincipal())
}

private func staticStringsEqual(_ a: StaticString, _ b: StaticString) -> Bool {
    a.withUTF8Buffer { ab in
        b.withUTF8Buffer { bb in
            if ab.count != bb.count { return false }
            for i in 0..<ab.count {
                if ab[i] != bb[i] { return false }
            }
            return true
        }
    }
}

private func effectiveMinLevel(for source: StaticString) -> LogLevel {
    for i in 0..<sourceMinCount {
        if staticStringsEqual(sourceMins[i].source, source) {
            return sourceMins[i].minLevel
        }
    }
    return minLogLevel
}

private func ringStore(_ entry: LogEntry) {
    // L3: ring now carries the optional detail; stored verbatim (0 = none).
    // L4: process/security context is already captured by the caller.
    ring[ringNext] = entry
    ringTotalWritten &+= 1
    ringNext = (ringNext + 1) % ringCapacity
    if ringNext == 0 { ringFull = true }
}

private func ringAvailableCount() -> Int {
    ringFull ? ringCapacity : ringNext
}

private func klogAccepts(_ level: LogLevel, _ source: StaticString) -> Bool {
    level == .panic || level.rawValue >= effectiveMinLevel(for: source).rawValue
}

private func ringStoreContext(_ tick: UInt64, _ level: LogLevel,
                              _ source: StaticString, _ message: StaticString,
                              _ detail: UInt64) {
    let ctx = currentLogContext()
    ringStore(LogEntry(tick: tick, level: level, source: source, message: message,
                       detail: detail, pid: ctx.pid, principal: ctx.principal))
}

private func logSinkWrite(_ sink: LogSink, tick: UInt64, level: LogLevel,
                          source: StaticString, message: StaticString,
                          detail: UInt64) {
    switch sink.kind {
    case .uart:
        uartRenderLogLine(tick: tick, level: level, source: source,
                          message: message, detail: detail)
    }
}

private func uartRenderLogLine(tick: UInt64, level: LogLevel,
                               source: StaticString, message: StaticString,
                               detail: UInt64) {
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
    if detail != 0 {
        uartPuts(" detail=")
        uartPutUInt(detail)
    }
    uartPuts("\n")
}

func klogCurrentSinkKind() -> LogSinkKind {
    currentLogSink.kind
}

func klogCanExportRing(capabilities caps: UInt64) -> Bool {
    (caps & capLogExport) != 0
}

func klogCanInstallSink(capabilities caps: UInt64) -> Bool {
    (caps & capLogExport) != 0
}

func logRingStatsCapacity() -> UInt64 {
    UInt64(ringCapacity)
}

func logRingStatsAvailable() -> UInt64 {
    UInt64(ringAvailableCount())
}

func logRingStatsTotalWritten() -> UInt64 {
    ringTotalWritten
}

func logRingStatsOverwritten() -> UInt64 {
    let available = logRingStatsAvailable()
    return ringTotalWritten > available ? ringTotalWritten - available : 0
}

/// Dump the most recent `maxCount` entries (or all available) to the UART.
/// Entries are printed oldest-to-newest within the window.
/// Safe to call from panic paths, IRQ-masked code, etc. (only uses uartPuts).
func logDumpRecent(_ maxCount: Int = 32) {
    var n = maxCount
    if n <= 0 { return }

    let available = ringAvailableCount()
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

// MARK: - L4c wire-format serialization

private func appendByte(_ byte: UInt8, into buffer: UnsafeMutablePointer<UInt8>,
                        capacity: Int, offset: inout Int) {
    if offset < capacity {
        buffer[offset] = byte
        offset += 1
    }
}

private func appendStatic(_ string: StaticString, into buffer: UnsafeMutablePointer<UInt8>,
                          capacity: Int, offset: inout Int) {
    string.withUTF8Buffer { bytes in
        for i in 0..<bytes.count {
            if offset >= capacity { break }
            buffer[offset] = bytes[i]
            offset += 1
        }
    }
}

private func appendUInt64(_ value: UInt64, into buffer: UnsafeMutablePointer<UInt8>,
                          capacity: Int, offset: inout Int) {
    if value == 0 {
        appendByte(0x30, into: buffer, capacity: capacity, offset: &offset)
        return
    }

    var divisor: UInt64 = 1
    while value / divisor >= 10 {
        divisor *= 10
    }

    var remaining = value
    while divisor > 0 {
        let digit = UInt8(remaining / divisor)
        appendByte(0x30 + digit, into: buffer, capacity: capacity, offset: &offset)
        remaining %= divisor
        divisor /= 10
    }
}

private func appendQuotedStatic(_ string: StaticString, into buffer: UnsafeMutablePointer<UInt8>,
                                capacity: Int, offset: inout Int) {
    appendByte(0x22, into: buffer, capacity: capacity, offset: &offset) // "
    string.withUTF8Buffer { bytes in
        for i in 0..<bytes.count {
            if offset >= capacity { break }
            let byte = bytes[i]
            if byte == 0x5C { // backslash
                appendByte(0x5C, into: buffer, capacity: capacity, offset: &offset)
                appendByte(0x5C, into: buffer, capacity: capacity, offset: &offset)
            } else if byte == 0x22 { // "
                appendByte(0x5C, into: buffer, capacity: capacity, offset: &offset)
                appendByte(0x22, into: buffer, capacity: capacity, offset: &offset)
            } else {
                appendByte(byte, into: buffer, capacity: capacity, offset: &offset)
            }
        }
    }
    appendByte(0x22, into: buffer, capacity: capacity, offset: &offset)
}

/// Format one log entry as a stable key=value record with no trailing newline.
/// The caller owns the buffer; the formatter never allocates and never writes
/// to UART. Fields:
///   tick=N level=I source=tag msg="text" [detail=N] [pid=N principal=N]
private func logFormatEntry(_ entry: LogEntry, into buffer: UnsafeMutablePointer<UInt8>,
                            capacity: Int) -> Int {
    if capacity <= 0 { return 0 }
    var offset = 0

    appendStatic("tick=", into: buffer, capacity: capacity, offset: &offset)
    appendUInt64(entry.tick, into: buffer, capacity: capacity, offset: &offset)
    appendStatic(" level=", into: buffer, capacity: capacity, offset: &offset)
    let ch = levelChar.withUTF8Buffer { bytes in bytes[Int(entry.level.rawValue)] }
    appendByte(ch, into: buffer, capacity: capacity, offset: &offset)
    appendStatic(" source=", into: buffer, capacity: capacity, offset: &offset)
    appendStatic(entry.source, into: buffer, capacity: capacity, offset: &offset)
    appendStatic(" msg=", into: buffer, capacity: capacity, offset: &offset)
    appendQuotedStatic(entry.message, into: buffer, capacity: capacity, offset: &offset)

    if entry.detail != 0 {
        appendStatic(" detail=", into: buffer, capacity: capacity, offset: &offset)
        appendUInt64(entry.detail, into: buffer, capacity: capacity, offset: &offset)
    }
    if entry.pid != 0 || entry.principal != 1 {
        appendStatic(" pid=", into: buffer, capacity: capacity, offset: &offset)
        appendUInt64(UInt64(UInt32(bitPattern: entry.pid)), into: buffer,
                     capacity: capacity, offset: &offset)
        appendStatic(" principal=", into: buffer, capacity: capacity, offset: &offset)
        appendUInt64(UInt64(entry.principal), into: buffer, capacity: capacity, offset: &offset)
    }

    return offset
}

/// Format up to `maxCount` recent ring entries (oldest first in the selected
/// window) as newline-separated key=value records. Returns bytes written.
func logFormatRecentTail(_ maxCount: Int, into buffer: UnsafeMutablePointer<UInt8>,
                         capacity: Int) -> Int {
    if capacity <= 0 || maxCount <= 0 { return 0 }

    let available = ringAvailableCount()
    if available == 0 { return 0 }

    var count = maxCount
    if count > available { count = available }

    var offset = 0
    let oldest = ringFull ? ringNext : 0
    let start = (oldest + available - count) % ringCapacity
    for i in 0..<count {
        if offset >= capacity { break }
        let idx = (start + i) % ringCapacity
        let written = logFormatEntry(ring[idx], into: buffer.advanced(by: offset),
                                     capacity: capacity - offset)
        offset += written
        appendByte(0x0A, into: buffer, capacity: capacity, offset: &offset)
    }

    return offset
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

// MARK: - L4b per-source level control

/// Set the minimum accepted level for one exact source tag. Re-setting a source
/// replaces the existing override. If the tiny table is full, extra sources are
/// ignored; global filtering still applies to them.
func klogSetSourceMinLevel(_ source: StaticString, _ level: LogLevel) {
    for i in 0..<sourceMinCount {
        if staticStringsEqual(sourceMins[i].source, source) {
            sourceMins[i].minLevel = level
            return
        }
    }
    if sourceMinCount < maxSourceOverrides {
        sourceMins[sourceMinCount] = SourceMin(source: source, minLevel: level)
        sourceMinCount += 1
    }
}

/// Clear all per-source overrides; the global minimum level becomes the only
/// filter again.
func klogClearSourceMinLevels() {
    sourceMinCount = 0
}

/// Record an accepted log event into the in-memory ring without rendering a
/// live UART line. Use this for useful-but-chatty foreground process events
/// where writing to the console would perturb user-visible stdout/prompt tests.
func klogRing(_ level: LogLevel, _ source: StaticString, _ message: StaticString, _ detail: UInt64 = 0) {
    if !klogAccepts(level, source) { return }
    ringStoreContext(timerGetTicks(), level, source, message, detail)
}

/// Emit a log record.
///
/// The output line has the shape:
///   [tick] [L] source: message detail=N\n
/// (when the optional detail payload is non-zero).
///
/// - `tick` is the monotonic value from timerGetTicks() (0 if the timer is not
///   yet initialised — this path is exercised and useful for very early logs).
/// - `L` is a single character from levelChar.
/// - `source` and `message` are emitted verbatim (they are StaticString).
/// - `detail` (optional, default 0) carries a small structured numeric payload
///   (0 means "none"). Callers can use the 4-arg form without breaking any
///   existing 3-arg call sites: `klog(.info, "pmm", "free frames", pmmFreeCount())`.
/// - the in-memory record also captures the current pid/principal context for
///   later dumps.
///
/// This function is safe to call:
/// - before timerInit / schedulerInit / heap;
/// - from IRQ handlers (the underlying uartPut* are polled);
/// - with IRQs masked (no locks are taken).
func klog(_ level: LogLevel, _ source: StaticString, _ message: StaticString, _ detail: UInt64 = 0) {
    // L2 + L4b filtering: per-source override wins over the global min level.
    // .panic is never filtered (always want the message + ring tail).
    if !klogAccepts(level, source) { return }

    let tick = timerGetTicks()

    logSinkWrite(currentLogSink, tick: tick, level: level,
                 source: source, message: message, detail: detail)

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
