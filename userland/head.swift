// head.swift — native Swift `/bin/head` for swift-os.
//
// Prints the first N lines (default 10; -n N) of each file argument, or of
// standard input when none is given.

private let oRdOnly: Int32 = 0
private let bufCap = 4096

private func parseUInt(_ p: UnsafePointer<CChar>) -> (Int, Bool) {
    var v = 0, i = 0
    if p[0] == 0 { return (0, false) }
    while p[i] != 0 {
        let c = p[i]
        if c < 0x30 || c > 0x39 { return (0, false) }
        v = v * 10 + Int(c - 0x30); i += 1
    }
    return (v, true)
}

// Print the first `limit` lines of an open fd. Returns once the limit is hit.
private func headFd(_ fd: Int32, _ limit: Int) {
    var printed = 0
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: bufCap) { buf in
        let base = buf.baseAddress!
        while printed < limit {
            let r = swiftos_read(fd, UnsafeMutableRawPointer(base), UInt(bufCap))
            if r <= 0 { break }
            var start = 0
            var i = 0
            while i < Int(r) {
                if base[i] == 0x0A {
                    _ = swiftos_write(1, base + start, UInt(i - start + 1))
                    start = i + 1
                    printed += 1
                    if printed >= limit { return }
                }
                i += 1
            }
            if start < Int(r) { _ = swiftos_write(1, base + start, UInt(Int(r) - start)) }
        }
    }
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp
    var limit = 10
    var firstFile = -1

    if let argv = argv {
        var i = 1
        while i < Int(argc) {
            guard let a = argv[i] else { i += 1; continue }
            if a[0] == 0x2D && a[1] == 0x6E {           // -n
                // "-n N" (next arg) or "-nN" (attached).
                if a[2] != 0 {
                    let (v, ok) = parseUInt(a + 2); if ok { limit = v }
                } else if i + 1 < Int(argc), let n = argv[i + 1] {
                    let (v, ok) = parseUInt(n); if ok { limit = v }; i += 1
                }
            } else if firstFile < 0 {
                firstFile = i
            }
            i += 1
        }
    }

    if firstFile < 0 {
        headFd(0, limit)   // stdin
        return 0
    }
    var status: Int32 = 0
    var i = firstFile
    while i < Int(argc) {
        if let p = argv![i] {
            let fd = swiftos_open(UnsafePointer(p), oRdOnly)
            if fd < 0 { swiftos_puts("head: cannot open file\n"); status = 1 }
            else { headFd(fd, limit); _ = swiftos_close(fd) }
        }
        i += 1
    }
    return status
}
