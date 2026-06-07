// top.swift — process/resource monitor for swift-os (a native Embedded Swift
// EL0 app, like /bin/ps but live).
//
// Reads two kernel snapshots — SYS_SYSINFO (uptime, memory, idle, tick rate)
// and SYS_PROCSTAT (per-process pid/ppid/state/principal/CPU ticks/start tick/
// resident bytes/name) — through the swift_user bridge, and renders a top-style
// screen: a summary header (uptime, tasks, CPU busy/idle, memory, and the
// kernel's own footprint) plus a per-process table sorted by %CPU.
//
//   top              interactive: clear+repaint every 2s, 'q' quits
//   top -d SECS      set the refresh delay (default 2s)
//   top -n N         run N refreshes then exit
//   top -b           batch mode (no cursor control / raw tty; for scripts/logs)
//   top -h           help
//
// %CPU is computed from the delta in a process's CPU ticks between refreshes
// (the first frame falls back to its average since it started). Everything is
// byte-oriented (no String/Unicode tables), so it links small like /bin/ps.

// Process states (kernel/user/process.swift).
private let stateReady: UInt32 = 1
private let stateRunning: UInt32 = 2
private let stateBlocked: UInt32 = 3
private let stateZombie: UInt32 = 4

private let pidMax = 16 // SWIFTOS_TOP_MAX; pid = slot+1, so 1..16

// POLLIN, for the stdin readiness poll that doubles as the refresh delay.
private let pollIn: UInt8 = 0x01

private func cStringEquals(_ s: UnsafePointer<CChar>, _ expected: StaticString) -> Bool {
    var ok = true
    expected.withUTF8Buffer { e in
        var i = 0
        while i < e.count {
            if UInt8(bitPattern: s[i]) != e[i] { ok = false; return }
            i += 1
        }
        if s[e.count] != 0 { ok = false }
    }
    return ok
}

/// Parse a leading non-negative decimal from a C string. Returns (value, ok).
private func parseUInt(_ s: UnsafePointer<CChar>) -> (UInt, Bool) {
    var i = 0
    var v: UInt = 0
    var any = false
    while s[i] != 0 {
        let b = UInt8(bitPattern: s[i])
        if b < 0x30 || b > 0x39 { return (0, false) }
        v = v * 10 + UInt(b - 0x30)
        any = true
        i += 1
    }
    return (v, any)
}

/// The renderer. Owns a reusable frame buffer, a cached copy of the identity
/// store (for the USER column), and the previous frame's CPU counters so %CPU
/// can be a per-interval rate rather than a since-boot average.
private final class Top {
    private let cap = 8192
    private let buf: UnsafeMutablePointer<UInt8>
    private var len = 0

    private let storeCap = 4096
    private let store: UnsafeMutablePointer<UInt8>
    private var storeLen = 0

    private let prevCpu: UnsafeMutablePointer<UInt>   // [pidMax+1], indexed by pid
    private let prevSeen: UnsafeMutablePointer<UInt8>   // [pidMax+1]
    private let order: UnsafeMutablePointer<Int32>      // [pidMax] sort permutation
    private let pct10: UnsafeMutablePointer<UInt>     // [pidMax] %CPU * 10, per record
    private var prevUptime: UInt = 0
    private var prevIdle: UInt = 0
    private var havePrev = false

    init() {
        buf = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        store = UnsafeMutablePointer<UInt8>.allocate(capacity: storeCap)
        prevCpu = UnsafeMutablePointer<UInt>.allocate(capacity: pidMax + 1)
        prevSeen = UnsafeMutablePointer<UInt8>.allocate(capacity: pidMax + 1)
        order = UnsafeMutablePointer<Int32>.allocate(capacity: pidMax)
        pct10 = UnsafeMutablePointer<UInt>.allocate(capacity: pidMax)
        for i in 0...pidMax { prevCpu[i] = 0; prevSeen[i] = 0 }
        loadStore()
    }

    // ---- frame buffer ----------------------------------------------------
    private func byte(_ b: UInt8) { if len < cap { buf[len] = b; len += 1 } }
    private func str(_ s: StaticString) { s.withUTF8Buffer { for c in $0 { byte(c) } } }
    private func spaces(_ n: Int) { var i = 0; while i < n { byte(0x20); i += 1 } }
    private func nl() { byte(0x0A) }

    private func digits(_ v: UInt) -> Int {
        var n = v, d = 1
        while n >= 10 { n /= 10; d += 1 }
        return d
    }

    private func decimal(_ v: UInt) {
        var divisor: UInt = 1
        while v / divisor >= 10 { divisor *= 10 }
        var rest = v
        while divisor > 0 {
            byte(0x30 + UInt8(rest / divisor))
            rest %= divisor
            divisor /= 10
        }
    }

    private func decimalPad(_ v: UInt, _ width: Int) {
        let d = digits(v)
        if d < width { spaces(width - d) }
        decimal(v)
    }

    /// `pct10` is percent*10; render as right-aligned "P.f".
    private func percent(_ p: UInt, _ width: Int) {
        let whole = p / 10, frac = p % 10
        let n = digits(whole) + 2 // "." + one fractional digit
        if n < width { spaces(width - n) }
        decimal(whole); byte(0x2E); byte(0x30 + UInt8(frac))
    }

    /// CPU time as M:SS.cc (centiseconds), like top's TIME+ column.
    private func timePlus(_ cpuTicks: UInt, _ hz: UInt) {
        let totalSec = hz > 0 ? cpuTicks / hz : 0
        let centi = hz > 0 ? (cpuTicks % hz) * 100 / hz : 0
        let mm = totalSec / 60, ss = totalSec % 60
        decimal(mm); byte(0x3A) // ':'
        if ss < 10 { byte(0x30) }; decimal(ss)
        byte(0x2E)
        if centi < 10 { byte(0x30) }; decimal(centi)
    }

    private func uptime(_ ticks: UInt, _ hz: UInt) {
        let s = hz > 0 ? ticks / hz : 0
        let hh = s / 3600, mm = (s % 3600) / 60, ss = s % 60
        decimal(hh); byte(0x3A)
        if mm < 10 { byte(0x30) }; decimal(mm); byte(0x3A)
        if ss < 10 { byte(0x30) }; decimal(ss)
    }

    private func stateChar(_ s: UInt32) -> UInt8 {
        switch s {
        case stateReady, stateRunning: return 0x52 // R
        case stateBlocked: return 0x53             // S
        case stateZombie: return 0x5A              // Z
        default: return 0x3F                       // ?
        }
    }

    private func flush() {
        if len > 0 {
            _ = swiftos_write(1, UnsafeRawPointer(buf), UInt(len))
            len = 0
        }
    }

    // ---- identity store (USER column) -----------------------------------
    private func loadStore() {
        let fd = swiftos_open("/etc/swos/passwd", 0)
        if fd < 0 { storeLen = 0; return } // unreadable (e.g. a capless principal)
        var total = 0
        while total < storeCap - 1 {
            let r = swiftos_read(fd, UnsafeMutableRawPointer(store + total), UInt(storeCap - 1 - total))
            if r <= 0 { break }
            total += Int(r)
        }
        _ = swiftos_close(fd)
        storeLen = total
    }

    /// Emit the USER column for `principal`: the matching store name (field 0 of
    /// the line whose field 1 == principal), else the numeric id. Left-justified.
    private func putUser(_ principal: UInt32, _ width: Int) {
        var i = 0
        while i < storeLen {
            var j = i
            while j < storeLen && store[j] != 0x0A { j += 1 }
            let ls = i, le = j
            i = j + 1
            if le == ls || store[ls] == 0x23 { continue } // empty or comment

            var c0e = ls
            while c0e < le && store[c0e] != 0x3A { c0e += 1 } // end of name
            let c1s = c0e + 1
            var c1e = c1s
            while c1e < le && store[c1e] != 0x3A { c1e += 1 } // end of principal

            var p: UInt32 = 0
            var k = c1s
            while k < c1e {
                let b = store[k]
                if b < 0x30 || b > 0x39 { p = 0xFFFF_FFFF; break }
                p = p * 10 + UInt32(b - 0x30); k += 1
            }
            if p == principal {
                let nameLen = c0e - ls
                k = ls
                while k < c0e { byte(store[k]); k += 1 }
                if nameLen < width { spaces(width - nameLen) }
                return
            }
        }
        // No match (or store unreadable): numeric principal, left-justified.
        let n = digits(UInt(principal))
        decimal(UInt(principal))
        if n < width { spaces(width - n) }
    }

    // ---- rendering -------------------------------------------------------
    /// Render one frame. `interactive` adds a clear+home so the screen repaints
    /// in place. Returns false on a kernel snapshot error.
    func renderFrame(interactive: Bool) -> Bool {
        if swiftos_sysinfo_refresh() != 0 { return false }
        let count = Int(swiftos_top_refresh())
        if count < 0 { return false }

        let hz = UInt(swiftos_sys_hz())
        let uptimeTicks = swiftos_sys_uptime_ticks()
        let idle = swiftos_sys_idle_ticks()
        let interval = havePrev ? (uptimeTicks >= prevUptime ? uptimeTicks - prevUptime : 0) : uptimeTicks
        let idleDelta = havePrev ? (idle >= prevIdle ? idle - prevIdle : 0) : idle
        let busyDelta = interval >= idleDelta ? interval - idleDelta : 0
        let busy10 = interval > 0 ? busyDelta * 1000 / interval : 0
        let idle10 = interval > 0 ? idleDelta * 1000 / interval : 0

        // Per-process %CPU and task-state tallies.
        var running = 0, sleeping = 0, zombie = 0
        for i in 0..<count {
            let pid = swiftos_top_pid(Int32(i))
            let cpu = swiftos_top_cpu_ticks(Int32(i))
            let start = swiftos_top_start_tick(Int32(i))
            let num: UInt
            let den: UInt
            if havePrev && pid <= UInt32(pidMax) && prevSeen[Int(pid)] != 0 {
                num = cpu >= prevCpu[Int(pid)] ? cpu - prevCpu[Int(pid)] : 0
                den = interval
            } else {
                num = cpu // average since this process started
                den = uptimeTicks > start ? uptimeTicks - start : 1
            }
            var p = den > 0 ? num * 1000 / den : 0
            if p > 1000 { p = 1000 }
            pct10[i] = p
            order[i] = Int32(i)

            switch swiftos_top_state(Int32(i)) {
            case stateReady, stateRunning: running += 1
            case stateBlocked: sleeping += 1
            case stateZombie: zombie += 1
            default: break
            }
        }

        // Selection sort the order[] permutation by %CPU descending.
        var a = 0
        while a < count {
            var best = a
            var b = a + 1
            while b < count {
                if pct10[Int(order[b])] > pct10[Int(order[best])] { best = b }
                b += 1
            }
            if best != a { let t = order[a]; order[a] = order[best]; order[best] = t }
            a += 1
        }

        len = 0
        if interactive { str("\u{1B}[2J\u{1B}[H") }

        // Summary header.
        str("top - up "); uptime(uptimeTicks, hz)
        str(",  "); decimal(UInt(swiftos_sys_proc_total())); str(" tasks,  hz "); decimal(hz); nl()

        str("Tasks: "); decimal(UInt(count)); str(" total, ")
        decimal(UInt(running)); str(" running, ")
        decimal(UInt(sleeping)); str(" sleeping, ")
        decimal(UInt(zombie)); str(" zombie"); nl()

        str("Cpu:  "); percent(busy10, 5); str("% busy, ")
        percent(idle10, 5); str("% idle"); nl()

        let total = swiftos_sys_mem_total()
        let free = swiftos_sys_mem_free()
        let used = total >= free ? total - free : 0
        str("Mem:  "); decimal(total / 1024); str("K total, ")
        decimal(used / 1024); str("K used, ")
        decimal(free / 1024); str("K free"); nl()

        str("Kernel: "); decimal(swiftos_sys_kernel_image() / 1024); str("K image, ")
        decimal(swiftos_sys_kernel_heap() / 1024); str("K heap used"); nl()
        nl()

        // Column header + rows (sorted by %CPU).
        str("  PID  PPID USER      S   %CPU      RES  TIME+      COMMAND"); nl()
        for rank in 0..<count {
            let i = Int(order[rank])
            decimalPad(UInt(swiftos_top_pid(Int32(i))), 5); byte(0x20)
            decimalPad(UInt(swiftos_top_ppid(Int32(i))), 5); byte(0x20)
            putUser(swiftos_top_principal(Int32(i)), 9); byte(0x20)
            byte(stateChar(swiftos_top_state(Int32(i)))); spaces(2)
            percent(pct10[i], 5); spaces(2)
            decimalPad(swiftos_top_res_bytes(Int32(i)) / 1024, 6); byte(0x4B) // 'K'
            spaces(2)
            // TIME+ in a fixed 9-wide field.
            let timeStart = len
            timePlus(swiftos_top_cpu_ticks(Int32(i)), hz)
            let timeWidth = len - timeStart
            if timeWidth < 9 { spaces(9 - timeWidth) }
            byte(0x20)
            if let name = swiftos_top_name(Int32(i)) {
                var k = 0
                while name[k] != 0 { byte(UInt8(bitPattern: name[k])); k += 1 }
            }
            nl()
        }
        flush()

        // Save this frame as the baseline for the next interval's %CPU.
        for k in 0...pidMax { prevSeen[k] = 0 }
        for i in 0..<count {
            let pid = swiftos_top_pid(Int32(i))
            if pid <= UInt32(pidMax) {
                prevCpu[Int(pid)] = swiftos_top_cpu_ticks(Int32(i))
                prevSeen[Int(pid)] = 1
            }
        }
        prevUptime = uptimeTicks
        prevIdle = idle
        havePrev = true
        return true
    }
}

/// Block for up to `ms`, returning true if the user asked to quit ('q'/'Q').
/// Doubles as the inter-frame delay (poll on stdin with a timeout).
private func waitOrQuit(_ ms: Int, interactive: Bool) -> Bool {
    var quit = false
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 8) { pf in
        let b = pf.baseAddress!
        for k in 0..<8 { b[k] = 0 }
        b[4] = pollIn // events = POLLIN (int16 LE)
        let n = swiftos_poll(UnsafeMutableRawPointer(b), 1, ms)
        if n > 0 {
            let r = swiftos_read(0, UnsafeMutableRawPointer(b), 1)
            if r > 0 && interactive && (b[0] == 0x71 || b[0] == 0x51) { quit = true }
        }
    }
    return quit
}

private func usage() {
    swiftos_puts("usage: top [-b] [-d secs] [-n iterations]\n")
    swiftos_puts("  -b   batch mode (no screen clearing or raw input)\n")
    swiftos_puts("  -d   refresh delay in seconds (default 2)\n")
    swiftos_puts("  -n   exit after this many refreshes\n")
    swiftos_puts("  interactive: press q to quit\n")
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp

    var batch = false
    var delaySecs: UInt = 2
    var iterations: UInt = 0 // 0 = unlimited

    var argi: Int32 = 1
    while argi < argc {
        guard let raw = argv?[Int(argi)] else { return 1 }
        let arg = UnsafePointer<CChar>(raw)
        if cStringEquals(arg, "-h") || cStringEquals(arg, "--help") {
            usage(); return 0
        } else if cStringEquals(arg, "-b") {
            batch = true
        } else if cStringEquals(arg, "-n") || cStringEquals(arg, "-d") {
            let isN = cStringEquals(arg, "-n")
            argi += 1
            guard argi < argc, let v = argv?[Int(argi)] else {
                swiftos_puts("top: option requires a value\n"); return 1
            }
            let (val, ok) = parseUInt(UnsafePointer<CChar>(v))
            if !ok { swiftos_puts("top: invalid number\n"); return 1 }
            if isN { iterations = val } else { delaySecs = val }
        } else {
            swiftos_puts("top: unsupported option\n"); usage(); return 1
        }
        argi += 1
    }
    if delaySecs == 0 { delaySecs = 1 }

    let interactive = !batch
    if interactive { swiftos_set_raw(1) }

    let top = Top()
    var done = false
    var iter: UInt = 0
    while !done {
        if !top.renderFrame(interactive: interactive) {
            swiftos_puts("top: kernel snapshot failed\n")
            break
        }
        iter += 1
        if iterations != 0 && iter >= iterations { break }
        if waitOrQuit(Int(delaySecs) * 1000, interactive: interactive) { done = true }
    }

    if interactive { swiftos_set_raw(0) }
    return 0
}
