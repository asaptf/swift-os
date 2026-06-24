// SPDX-License-Identifier: Apache-2.0
// crond.swift — native Swift cron daemon for swift-os.
//
// A long-running userland service that launches commands on a schedule. It uses
// only primitives the kernel already provides: the PL031 wall clock (time()),
// the monotonic scheduler tick (sysinfo), nanosleep, and a synchronous
// fork+exec+wait (swiftos_run). No kernel changes.
//
// Crontab syntax (hybrid — classic five fields plus @-shortcuts):
//
//     # min hour dom mon dow  command
//     */5  *    *   *   *      /bin/sh -c 'echo tick'
//     0    3    *   *   *      /bin/acme renew
//     @reboot                  command        run once at crond start
//     @hourly / @daily / @weekly / @monthly / @yearly / @midnight
//     @every <dur>             command        dur = 30s, 5m, 2h, 1h30m, …
//
// Each of the five fields accepts: `*`, a number, a list `a,b`, a range `a-b`,
// and a step `*/n` or `a-b/n`. dow uses 0..7 with both 0 and 7 = Sunday. When
// both dom and dow are restricted, a row fires if EITHER matches (Vixie cron).
//
// Sources (both, merged): the signed base default `/etc/crontab`, then the
// mutable durable override `/data/crond/crontab` (appended if /data is mounted).
// An explicit path argument (`crond <file>...`) overrides both — used by the
// acceptance test. There is no live reload yet: edits take effect on restart.
//
// Each fired job runs as `/bin/sh -c "<command>"` so redirection/pipes work and
// argv[0] selects the busybox applet. Jobs run synchronously and are reaped on
// return; a job that never exits stalls the scheduler (WNOHANG is not yet in the
// kernel waitpid — a documented v1 limitation; see docs/NOTES.md).

// open(2) flags (kernel ABI, kernel/vfs/vfs.swift).
private let oRdOnly: Int32 = 0
// stat st_mode type bits.
private let sIFMT:  UInt32 = 0xF000
private let sIFDIR: UInt32 = 0x4000

private let kCalendar: UInt8 = 0
private let kEvery: UInt8 = 1
private let kReboot: UInt8 = 2

private let maxJobs = 64

// A parsed crontab entry. Calendar fields are bitmasks indexed directly by value
// (minute 0..59, hour 0..23, dom 1..31, mon 1..12, dow 0..6 — all < 64).
private struct Job {
    var kind: UInt8 = kCalendar
    var minMask: UInt64 = 0
    var hourMask: UInt64 = 0
    var domMask: UInt64 = 0
    var monMask: UInt64 = 0
    var dowMask: UInt64 = 0
    var domStar: Bool = true
    var dowStar: Bool = true
    var everyTicks: UInt64 = 0       // @every: interval in scheduler ticks
    var nextTick: UInt64 = 0         // @every: next fire (monotonic ticks)
    var lastMinute: Int64 = -1       // calendar: epoch-minute we last fired
    var command: [CChar] = []        // NUL-terminated, for `sh -c`
}

private var jobs: [Job] = []

// ---- small helpers ----------------------------------------------------------

private func cstr(_ s: StaticString) -> [CChar] {
    var a: [CChar] = []
    let n = s.utf8CodeUnitCount
    var i = 0
    while i < n { a.append(CChar(bitPattern: s.utf8Start[i])); i += 1 }
    a.append(0)
    return a
}

private func bytesToCStr(_ b: [UInt8], _ start: Int, _ end: Int) -> [CChar] {
    var a: [CChar] = []
    var i = start
    while i < end { a.append(CChar(bitPattern: b[i])); i += 1 }
    a.append(0)
    return a
}

private func isWS(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 }
private func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
private func bit(_ mask: UInt64, _ v: Int) -> Bool {
    v >= 0 && v < 64 && ((mask >> UInt64(v)) & 1) != 0
}
private func fullMask(_ lo: Int, _ hi: Int) -> UInt64 {
    var m: UInt64 = 0
    var v = lo
    while v <= hi { m |= (UInt64(1) << UInt64(v)); v += 1 }
    return m
}

// ---- filesystem -------------------------------------------------------------

private func statMode(_ path: [CChar]) -> UInt32? {
    var mode: UInt32 = 0, uid: UInt32 = 0, gid: UInt32 = 0, nlink: UInt32 = 0
    var size: UInt = 0, mtime: UInt = 0
    let rc = path.withUnsafeBufferPointer {
        swiftos_stat($0.baseAddress!, &mode, &uid, &gid, &nlink, &size, &mtime)
    }
    return rc == 0 ? mode : nil
}
private func isDir(_ path: [CChar]) -> Bool {
    guard let m = statMode(path) else { return false }
    return (m & sIFMT) == sIFDIR
}

private func readFile(_ path: [CChar]) -> [UInt8]? {
    let fd = path.withUnsafeBufferPointer { swiftos_open($0.baseAddress!, oRdOnly) }
    if fd < 0 { return nil }
    defer { _ = swiftos_close(fd) }
    var data: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = chunk.withUnsafeMutableBytes { swiftos_read(fd, $0.baseAddress, UInt($0.count)) }
        if n <= 0 { break }
        var i = 0
        while i < Int(n) { data.append(chunk[i]); i += 1 }
        if data.count > 256 * 1024 { break }   // sanity bound
    }
    return data
}

// ---- integer + field parsing ------------------------------------------------

private func parseInt(_ b: [UInt8], _ start: Int, _ end: Int) -> Int? {
    if start >= end { return nil }
    var v = 0, k = start
    while k < end {
        if !isDigit(b[k]) { return nil }
        v = v * 10 + Int(b[k] - 0x30)
        if v > 100000 { return nil }
        k += 1
    }
    return v
}

// Parse one comma-item ("*", "*/s", "a", "a-b", "a-b/s") into `mask`.
private func parseItem(_ b: [UInt8], _ start: Int, _ end: Int,
                       _ lo: Int, _ hi: Int, _ mask: inout UInt64) -> Bool {
    var slash = -1, k = start
    while k < end { if b[k] == UInt8(ascii: "/") { slash = k; break }; k += 1 }
    let rangeEnd = slash >= 0 ? slash : end
    var step = 1
    if slash >= 0 {
        guard let s = parseInt(b, slash + 1, end), s >= 1 else { return false }
        step = s
    }
    var a = lo, z = hi
    if rangeEnd - start == 1 && b[start] == UInt8(ascii: "*") {
        a = lo; z = hi
    } else {
        var dash = -1, m = start
        while m < rangeEnd { if b[m] == UInt8(ascii: "-") { dash = m; break }; m += 1 }
        if dash >= 0 {
            guard let lv = parseInt(b, start, dash), let hv = parseInt(b, dash + 1, rangeEnd) else { return false }
            a = lv; z = hv
        } else {
            guard let v = parseInt(b, start, rangeEnd) else { return false }
            a = v; z = v
        }
    }
    if a < lo || z > hi || a > z { return false }
    var v = a
    while v <= z { mask |= (UInt64(1) << UInt64(v)); v += step }
    return true
}

// Parse a whole field over [lo,hi]; returns (mask, isStar) or nil on error.
private func parseField(_ b: [UInt8], _ start: Int, _ end: Int,
                        _ lo: Int, _ hi: Int) -> (UInt64, Bool)? {
    if start >= end { return nil }
    let isStar = (end - start == 1 && b[start] == UInt8(ascii: "*"))
    var mask: UInt64 = 0
    var i = start
    while i < end {
        var j = i
        while j < end && b[j] != UInt8(ascii: ",") { j += 1 }
        if !parseItem(b, i, j, lo, hi, &mask) { return nil }
        i = (j < end) ? j + 1 : j
    }
    return (mask, isStar)
}

// @every duration: "30s","5m","2h","1h30m" or a bare number (seconds). Returns
// seconds, or nil on error.
private func parseDuration(_ b: [UInt8], _ start: Int, _ end: Int) -> UInt64? {
    var total: UInt64 = 0, num: UInt64 = 0
    var haveNum = false, k = start
    while k < end {
        let c = b[k]
        if isDigit(c) { num = num * 10 + UInt64(c - 0x30); haveNum = true }
        else {
            let mult: UInt64
            switch c {
            case UInt8(ascii: "s"): mult = 1
            case UInt8(ascii: "m"): mult = 60
            case UInt8(ascii: "h"): mult = 3600
            case UInt8(ascii: "d"): mult = 86400
            default: return nil
            }
            if !haveNum { return nil }
            total += num * mult; num = 0; haveNum = false
        }
        k += 1
    }
    if haveNum { total += num }   // trailing bare number = seconds
    return total == 0 ? nil : total
}

// ---- line parsing -----------------------------------------------------------

private func tokenEnd(_ b: [UInt8], _ i: Int, _ n: Int) -> Int {
    var j = i
    while j < n && !isWS(b[j]) { j += 1 }
    return j
}
private func skipWS(_ b: [UInt8], _ i: Int, _ n: Int) -> Int {
    var j = i
    while j < n && isWS(b[j]) { j += 1 }
    return j
}
// Trailing position with CR/whitespace stripped.
private func trimEnd(_ b: [UInt8], _ i: Int, _ n: Int) -> Int {
    var e = n
    while e > i && (isWS(b[e - 1]) || b[e - 1] == 0x0D) { e -= 1 }
    return e
}

private func litEq(_ b: [UInt8], _ start: Int, _ end: Int, _ s: StaticString) -> Bool {
    let n = s.utf8CodeUnitCount
    if end - start != n { return false }
    var i = 0
    while i < n { if b[start + i] != s.utf8Start[i] { return false }; i += 1 }
    return true
}

private func makeCalendar(_ command: [CChar],
                          _ minM: UInt64, _ hourM: UInt64, _ domM: UInt64,
                          _ monM: UInt64, _ dowM: UInt64,
                          _ domStar: Bool, _ dowStar: Bool) -> Job {
    var j = Job()
    j.kind = kCalendar
    j.minMask = minM; j.hourMask = hourM; j.domMask = domM
    j.monMask = monM; j.dowMask = dowM
    j.domStar = domStar; j.dowStar = dowStar
    j.command = command
    return j
}

// Parse one crontab line (bytes b[start..<lineEnd]) into a Job, or nil to skip.
private func parseLine(_ b: [UInt8], _ start: Int, _ lineEnd: Int) -> Job? {
    let n = trimEnd(b, start, lineEnd)
    var i = skipWS(b, start, n)
    if i >= n { return nil }
    if b[i] == UInt8(ascii: "#") { return nil }

    let hourAll = fullMask(0, 23)
    let domAll = fullMask(1, 31), monAll = fullMask(1, 12), dowAll = fullMask(0, 6)

    if b[i] == UInt8(ascii: "@") {
        let tEnd = tokenEnd(b, i, n)
        // @every needs a duration token before the command.
        if litEq(b, i, tEnd, "@every") {
            let durStart = skipWS(b, tEnd, n)
            let durEnd = tokenEnd(b, durStart, n)
            guard durStart < durEnd, let secs = parseDuration(b, durStart, durEnd) else { return nil }
            let cmdStart = skipWS(b, durEnd, n)
            if cmdStart >= n { return nil }
            var j = Job()
            j.kind = kEvery
            j.everyTicks = secs            // converted to ticks once hz is known
            j.command = bytesToCStr(b, cmdStart, n)
            return j
        }
        let cmdStart = skipWS(b, tEnd, n)
        if litEq(b, i, tEnd, "@reboot") {
            if cmdStart >= n { return nil }
            var j = Job()
            j.kind = kReboot
            j.command = bytesToCStr(b, cmdStart, n)
            return j
        }
        if cmdStart >= n { return nil }
        let cmd = bytesToCStr(b, cmdStart, n)
        let oneMin = UInt64(1)             // bit 0 set (minute 0)
        if litEq(b, i, tEnd, "@hourly") {
            return makeCalendar(cmd, oneMin, hourAll, domAll, monAll, dowAll, true, true)
        }
        if litEq(b, i, tEnd, "@daily") || litEq(b, i, tEnd, "@midnight") {
            return makeCalendar(cmd, oneMin, 1, domAll, monAll, dowAll, true, true)
        }
        if litEq(b, i, tEnd, "@weekly") {
            return makeCalendar(cmd, oneMin, 1, domAll, monAll, UInt64(1), true, false)
        }
        if litEq(b, i, tEnd, "@monthly") {
            return makeCalendar(cmd, oneMin, 1, UInt64(1) << 1, monAll, dowAll, false, true)
        }
        if litEq(b, i, tEnd, "@yearly") || litEq(b, i, tEnd, "@annually") {
            return makeCalendar(cmd, oneMin, 1, UInt64(1) << 1, UInt64(1) << 1, dowAll, false, false)
        }
        return nil   // unknown @shortcut
    }

    // Five space-separated fields, then the command (rest of line).
    var fStart = [Int](repeating: 0, count: 5)
    var fEnd = [Int](repeating: 0, count: 5)
    var f = 0
    while f < 5 {
        i = skipWS(b, i, n)
        if i >= n { return nil }
        let e = tokenEnd(b, i, n)
        fStart[f] = i; fEnd[f] = e
        i = e
        f += 1
    }
    let cmdStart = skipWS(b, i, n)
    if cmdStart >= n { return nil }

    guard let (minM, minStar) = parseField(b, fStart[0], fEnd[0], 0, 59) else { return nil }
    guard let (hourM, hourStar) = parseField(b, fStart[1], fEnd[1], 0, 23) else { return nil }
    guard let (domM, domStar) = parseField(b, fStart[2], fEnd[2], 1, 31) else { return nil }
    guard let (monM, monStar) = parseField(b, fStart[3], fEnd[3], 1, 12) else { return nil }
    guard let dowField = parseField(b, fStart[4], fEnd[4], 0, 7) else { return nil }
    var dowM = dowField.0
    let dowStar = dowField.1
    _ = (minStar, hourStar, monStar)
    // dow: normalize 7 -> 0 (both are Sunday).
    if bit(dowM, 7) { dowM |= 1; dowM &= ~(UInt64(1) << 7) }

    return makeCalendar(bytesToCStr(b, cmdStart, n),
                        minM, hourM, domM, monM, dowM, domStar, dowStar)
}

// Parse a whole crontab buffer, appending jobs (bounded by maxJobs).
private func parseBuffer(_ b: [UInt8]) {
    let n = b.count
    var i = 0
    while i < n {
        var e = i
        while e < n && b[e] != 0x0A { e += 1 }
        if jobs.count < maxJobs, let j = parseLine(b, i, e) { jobs.append(j) }
        i = e + 1
    }
}

// ---- matching + execution ---------------------------------------------------

private func calendarMatches(_ j: Job, _ t: UInt) -> Bool {
    let minute = Int((t / 60) % 60)
    let hour = Int((t / 3600) % 24)
    let dow = Int((t / 86400 + 4) % 7)        // 1970-01-01 was Thursday; 0 = Sunday
    var mon = 0, dom = 0
    var buf = [CChar](repeating: 0, count: 24)
    buf.withUnsafeMutableBufferPointer { swiftos_fmt_time(t, $0.baseAddress!) }
    // "YYYY-MM-DD HH:MM:SS"
    mon = (Int(UInt8(bitPattern: buf[5])) - 48) * 10 + (Int(UInt8(bitPattern: buf[6])) - 48)
    dom = (Int(UInt8(bitPattern: buf[8])) - 48) * 10 + (Int(UInt8(bitPattern: buf[9])) - 48)

    if !bit(j.minMask, minute) { return false }
    if !bit(j.hourMask, hour) { return false }
    if !bit(j.monMask, mon) { return false }
    let domOk = bit(j.domMask, dom)
    let dowOk = bit(j.dowMask, dow)
    if !j.domStar && !j.dowStar { return domOk || dowOk }
    return domOk && dowOk
}

// Run `command` as `/bin/sh -c "<command>"`, blocking until it exits.
private func runJob(_ command: [CChar]) {
    var path = cstr("/bin/sh")
    var a0 = cstr("sh")
    var a1 = cstr("-c")
    var cmd = command
    path.withUnsafeMutableBufferPointer { p in
        a0.withUnsafeMutableBufferPointer { p0 in
            a1.withUnsafeMutableBufferPointer { p1 in
                cmd.withUnsafeMutableBufferPointer { pc in
                    var argv: [UnsafeMutablePointer<CChar>?] =
                        [p0.baseAddress, p1.baseAddress, pc.baseAddress, nil]
                    argv.withUnsafeMutableBufferPointer { av in
                        _ = swiftos_run(p.baseAddress!, av.baseAddress!)
                    }
                }
            }
        }
    }
}

private func nowTicks() -> UInt64 {
    _ = swiftos_sysinfo_refresh()
    return UInt64(swiftos_sys_uptime_ticks())
}

// ---- entry point ------------------------------------------------------------

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp
    swiftos_puts("crond: starting\n")

    // /data/crond holds the override crontab + per-job state; create it if the
    // durable tier is mounted (best-effort).
    let dataDir = cstr("/data")
    let crondDir = cstr("/data/crond")
    if isDir(dataDir) {
        _ = crondDir.withUnsafeBufferPointer { swiftos_mkdir($0.baseAddress!) }
    }

    // Crontab sources: explicit args (test mode) override the default pair.
    var sources: [[CChar]] = []
    if argc > 1, let av = argv {
        var i = 1
        while i < Int(argc) {
            if let p = av[i] {
                var a: [CChar] = []
                var k = 0
                while p[k] != 0 { a.append(p[k]); k += 1 }
                a.append(0)
                sources.append(a)
            }
            i += 1
        }
    } else {
        sources.append(cstr("/etc/crontab"))
        sources.append(cstr("/data/crond/crontab"))
    }

    for src in sources {
        if let data = readFile(src) { parseBuffer(data) }
    }
    swiftos_puts("crond: loaded ")
    putUInt(UInt64(jobs.count))
    swiftos_puts(" job(s)\n")

    // Convert @every intervals to ticks and seed their first fire time.
    _ = swiftos_sysinfo_refresh()
    var hz = UInt64(swiftos_sys_hz())
    if hz == 0 { hz = 100 }
    let startTick = nowTicks()
    var k = 0
    while k < jobs.count {
        if jobs[k].kind == kEvery {
            jobs[k].everyTicks = jobs[k].everyTicks * hz
            if jobs[k].everyTicks == 0 { jobs[k].everyTicks = hz }
            jobs[k].nextTick = startTick + jobs[k].everyTicks
        }
        k += 1
    }

    // @reboot jobs fire once, now.
    k = 0
    while k < jobs.count {
        if jobs[k].kind == kReboot { runJob(jobs[k].command) }
        k += 1
    }

    // Scheduler loop. Calendar jobs match on the wall clock at minute
    // granularity (guarded so each fires at most once per minute); @every jobs
    // use the monotonic tick so they are immune to RTC absence/jumps.
    var lastMinChecked: Int64 = -1
    while true {
        let now = nowTicks()
        var idx = 0
        while idx < jobs.count {
            if jobs[idx].kind == kEvery && now >= jobs[idx].nextTick {
                runJob(jobs[idx].command)
                jobs[idx].nextTick = nowTicks() + jobs[idx].everyTicks
            }
            idx += 1
        }
        let t = swiftos_time()
        if t != 0 {
            let minute = Int64(t / 60)
            if minute != lastMinChecked {
                lastMinChecked = minute
                idx = 0
                while idx < jobs.count {
                    if jobs[idx].kind == kCalendar
                        && jobs[idx].lastMinute != minute
                        && calendarMatches(jobs[idx], t) {
                        runJob(jobs[idx].command)
                        jobs[idx].lastMinute = minute
                    }
                    idx += 1
                }
            }
        }
        swiftos_nanosleep(1, 0)
    }
}

// Minimal unsigned decimal print (no stdlib String needed at the call site).
private func putUInt(_ v: UInt64) {
    if v == 0 { swiftos_putc(UInt8(ascii: "0")); return }
    var digits = [UInt8]()
    var x = v
    while x > 0 { digits.append(UInt8(ascii: "0") + UInt8(x % 10)); x /= 10 }
    var i = digits.count - 1
    while i >= 0 { swiftos_putc(digits[i]); i -= 1 }
}
