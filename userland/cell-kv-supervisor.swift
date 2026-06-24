// SPDX-License-Identifier: Apache-2.0
// cell-kv-supervisor.swift — C7d: a REAL in-tree service lifted into a supervised cell.
//
// The C7 payoff: take an existing, real Swift service — /bin/kv, the in-memory
// key-value store (Dictionary<String,String> behind a class; a genuine program, not a
// toy written for this test) — and run it INSIDE a cell, unchanged, supervised by the
// C7c restart/FDIR pattern. The supervisor:
//   * assembles a cell { a /tmp namespace root + a restricted handle set + a page cap +
//     a handle cap } and cell_spawns /bin/kv into it with EXACTLY two handles — a stdin
//     pipe (commands) and a stdout pipe (responses) — and nothing else;
//   * drives a real client round-trip over the pipes: SET a key, GET it back;
//   * asserts isolation (the service holds only its granted handles, within the cap)
//     and accounting (cell_stat charges it to the cell);
//   * faults the service (closes its stdin → EOF → it exits), detects the exit via
//     waitpid, and RESTARTS it in a FRESH cell (a different CellId). The restarted
//     instance has an EMPTY store (GET returns "(nil)") — proving it is a genuinely
//     fresh process, not the old one — and still serves a live round-trip;
//   * tears the cell down cleanly and reclaims the domain.
//
// This exercises the whole cell stack end to end on a real service: namespace + handle
// restriction (C6c/C7b), page + handle caps (C7a/C7b), and supervised restart (C7c).

private let rightRead: UInt32 = 1 << 0
private let rightWrite: UInt32 = 1 << 1
// /bin/kv is a real service: it pulls in the Embedded Swift String/Unicode tables and a
// Dictionary, so its resident footprint is far larger than the toy cell-svc. The caps
// are generous enough that normal operation never hits them (a real service must not be
// strangled by its own host) while still bounding the cell — C7a/C7b prove the caps bite
// at the boundary; here they are a sane ceiling around a real workload.
private let pageCap: UInt = 4096     // 16 MB — comfortably above /bin/kv's footprint
private let handleCap: UInt = 16

private func putUInt(_ value: UInt) {
    if value == 0 { swiftos_putc(0x30); return }
    var digits = [UInt8](repeating: 0, count: 20)
    var n = value
    var count = 0
    while n > 0 { digits[count] = UInt8(0x30 + Int(n % 10)); n /= 10; count += 1 }
    while count > 0 { count -= 1; swiftos_putc(digits[count]) }
}

private func statOf(_ cellRaw: UInt32) -> (procs: Int, handles: Int) {
    var s = swiftos_cell_stat()
    _ = swiftos_cell_query(cellRaw, &s)
    return (Int(s.processes), Int(s.handles))
}

private func writeStr(_ fd: Int32, _ s: StaticString) {
    s.withUTF8Buffer { c in _ = swiftos_write(fd, c.baseAddress!, UInt(c.count)) }
}

// Drain the service's stdout, accumulating across reads, until `token` is seen or we
// give up. Returns true if the token appeared (the real round-trip landed). kv prints
// a startup banner + an "OK" before the value we want, so we accumulate and substring-
// search rather than expecting exact framing over the pipe.
private func awaitToken(_ fd: Int32, _ token: StaticString, maxReads: Int = 24) -> Bool {
    var seen = [UInt8](repeating: 0, count: 1024)
    var len = 0
    return token.withUTF8Buffer { t -> Bool in
        var reads = 0
        while reads < maxReads {
            reads += 1
            let got = seen.withUnsafeMutableBytes { dst -> Int in
                let room = dst.count - len
                if room <= 0 { return 0 }
                return Int(swiftos_read(fd, dst.baseAddress!.advanced(by: len), UInt(room)))
            }
            if got <= 0 { continue }
            len += got
            if len >= t.count {
                var i = 0
                while i + t.count <= len {
                    var j = 0
                    while j < t.count && seen[i + j] == t[j] { j += 1 }
                    if j == t.count { return true }
                    i += 1
                }
            }
        }
        return false
    }
}

// Spawn /bin/kv into the cell with exactly two handles: stdin pipe read end -> fd 0,
// stdout pipe write end -> fd 1.
private func spawnKV(cellFd: Int32, stdinRead: Int32, stdoutWrite: Int32) -> Int {
    return withUnsafeTemporaryAllocation(of: CChar.self, capacity: 8) { nameBuf -> Int in
        let name = nameBuf.baseAddress!
        var i = 0
        for c in "kv".utf8 { name[i] = CChar(bitPattern: c); i += 1 }
        name[i] = 0
        return withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<CChar>?.self, capacity: 2) { argv -> Int in
            argv[0] = name; argv[1] = nil
            return withUnsafeTemporaryAllocation(byteCount: 32, alignment: 4) { specs -> Int in
                let sp = specs.baseAddress!
                func put(_ idx: Int, _ src: Int32, _ dst: Int32, _ rights: UInt32) {
                    let b = idx * 16
                    sp.storeBytes(of: src, toByteOffset: b + 0, as: Int32.self)
                    sp.storeBytes(of: dst, toByteOffset: b + 4, as: Int32.self)
                    sp.storeBytes(of: rights, toByteOffset: b + 8, as: UInt32.self)
                    sp.storeBytes(of: UInt32(0), toByteOffset: b + 12, as: UInt32.self)
                }
                put(0, stdinRead, 0, rightRead)    // commands -> kv stdin
                put(1, stdoutWrite, 1, rightWrite) // kv stdout -> supervisor
                return Int(swiftos_cell_spawn(cellFd, "/bin/kv",
                            UnsafeMutableRawPointer(argv.baseAddress!), sp, 2))
            }
        }
    }
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp
    var ok = true

    // ---- Generation 1: bring the real service up + a live round-trip --------
    var inPipe = [Int32](repeating: -1, count: 2)   // [read, write]
    var outPipe = [Int32](repeating: -1, count: 2)
    if inPipe.withUnsafeMutableBufferPointer({ swiftos_pipe($0.baseAddress) }) != 0 ||
       outPipe.withUnsafeMutableBufferPointer({ swiftos_pipe($0.baseAddress) }) != 0 {
        swiftos_puts("C7d FAIL: pipe() failed\n"); return 1
    }
    var cell1: UInt32 = 0
    let cellFd1 = swiftos_cell_create("/tmp", pageCap, handleCap, &cell1)
    if cellFd1 < 0 || cell1 < 2 { swiftos_puts("C7d FAIL: cell_create failed\n"); return 1 }

    let pid1 = spawnKV(cellFd: cellFd1, stdinRead: inPipe[0], stdoutWrite: outPipe[1])
    if pid1 <= 0 { swiftos_puts("C7d FAIL: cell_spawn /bin/kv failed\n"); return 1 }
    _ = swiftos_close(inPipe[0]); _ = swiftos_close(outPipe[1]) // the service owns its ends
    swiftos_puts("C7d probe: gen 1 /bin/kv up in cell=")
    putUInt(UInt(cell1)); swiftos_puts(" root=/tmp\n")

    // Real client round-trip against the cell-hosted service. kv reads one line per
    // read(), so we await each response before sending the next command (otherwise a
    // second command could be coalesced into kv's single read of the first).
    writeStr(inPipe[1], "SET greeting c7d-real-value\n")
    let set1 = awaitToken(outPipe[0], "OK")
    writeStr(inPipe[1], "GET greeting\n")
    if set1 && awaitToken(outPipe[0], "c7d-real-value") {
        swiftos_puts("C7d probe: round-trip OK (GET returned the stored value)\n")
    } else {
        swiftos_puts("C7d FAIL: no round-trip from the cell-hosted kv\n"); ok = false
    }

    // Isolation + accounting: the service holds only its granted handles (within the
    // cap) and is charged to its cell.
    let s1 = statOf(cell1)
    swiftos_puts("C7d probe: cell_stat processes=")
    putUInt(UInt(s1.procs)); swiftos_puts(" handles=")
    putUInt(UInt(s1.handles)); swiftos_putc(0x0A)
    if s1.procs != 1 { swiftos_puts("C7d FAIL: service not charged to its cell\n"); ok = false }
    if s1.handles > Int(handleCap) {
        swiftos_puts("C7d FAIL: service handles exceeded the cap\n"); ok = false
    } else {
        swiftos_puts("C7d probe: service isolated (handles within cap)\n")
    }

    // ---- Fault + supervised restart in a FRESH cell -------------------------
    // Close the service's stdin → it reads EOF and exits; the supervisor detects it.
    _ = swiftos_close(inPipe[1])
    var st1: Int32 = 0
    _ = swiftos_waitpid(Int32(pid1), &st1)
    _ = swiftos_close(outPipe[0])
    swiftos_puts("C7d probe: gen 1 exited, supervisor detected it\n")

    // Restart in a fresh cell BEFORE reclaiming the old one, so the CellId differs.
    var in2 = [Int32](repeating: -1, count: 2)
    var out2 = [Int32](repeating: -1, count: 2)
    _ = in2.withUnsafeMutableBufferPointer { swiftos_pipe($0.baseAddress) }
    _ = out2.withUnsafeMutableBufferPointer { swiftos_pipe($0.baseAddress) }
    var cell2: UInt32 = 0
    let cellFd2 = swiftos_cell_create("/tmp", pageCap, handleCap, &cell2)
    if cellFd2 < 0 || cell2 < 2 { swiftos_puts("C7d FAIL: restart cell_create failed\n"); return 1 }
    let pid2 = spawnKV(cellFd: cellFd2, stdinRead: in2[0], stdoutWrite: out2[1])
    if pid2 <= 0 { swiftos_puts("C7d FAIL: restart spawn failed\n"); return 1 }
    _ = swiftos_close(in2[0]); _ = swiftos_close(out2[1])
    if cell2 == cell1 {
        swiftos_puts("C7d FAIL: restart reused the old CellId\n"); ok = false
    } else {
        swiftos_puts("C7d probe: gen 2 /bin/kv restarted in a fresh cell=")
        putUInt(UInt(cell2)); swiftos_putc(0x0A)
    }

    // The restarted instance must have a FRESH (empty) store — proof it is a genuinely
    // new process, not the old one: GET of the gen-1 key returns "(nil)".
    writeStr(in2[1], "GET greeting\n")
    if awaitToken(out2[0], "(nil)") {
        swiftos_puts("C7d probe: restarted service has fresh state (GET -> (nil))\n")
    } else {
        swiftos_puts("C7d FAIL: restarted service did not start fresh\n"); ok = false
    }
    // And it still serves live work.
    writeStr(in2[1], "SET k2 v2\n")
    let set2 = awaitToken(out2[0], "OK")
    writeStr(in2[1], "GET k2\n")
    if !(set2 && awaitToken(out2[0], "v2")) {
        swiftos_puts("C7d FAIL: restarted service did not serve a round-trip\n"); ok = false
    }

    // ---- Reclaim gen 1, then tear down gen 2 --------------------------------
    if swiftos_cell_destroy(cellFd1) != 0 {
        swiftos_puts("C7d FAIL: could not reclaim the faulted cell\n"); ok = false
    } else if statOf(cell1).procs != 0 {
        swiftos_puts("C7d FAIL: faulted cell still charged after reclaim\n"); ok = false
    } else {
        swiftos_puts("C7d probe: gen 1 cell reclaimed, accounting reset\n")
    }

    _ = swiftos_close(in2[1])
    var st2: Int32 = 0
    _ = swiftos_waitpid(Int32(pid2), &st2)
    _ = swiftos_close(out2[0])
    if swiftos_cell_destroy(cellFd2) != 0 {
        swiftos_puts("C7d FAIL: could not tear down gen 2\n"); ok = false
    } else {
        swiftos_puts("C7d probe: gen 2 cell torn down cleanly\n")
    }

    if ok {
        swiftos_puts("C7d OK: a real service (/bin/kv) ran isolated in a supervised cell, restarted in a fresh cell, and tore down cleanly\n")
        return 0
    }
    return 1
}
