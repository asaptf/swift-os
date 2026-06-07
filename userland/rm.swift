// SPDX-License-Identifier: Apache-2.0
// rm.swift — native Swift `/bin/rm` for swift-os.
//
// Removes each named file (unlink) from the writable tmpfs. With `-r`/`-R` it
// recurses into directories: it walks the kernel getdents ABI (the same layout
// /bin/ls parses), removing children depth-first before rmdir'ing the now-empty
// directory. `-f` makes a missing path non-fatal (best-effort, like real rm).

private let oRdOnly: Int32 = 0
private let sIFMT: UInt32 = 0xF000
private let sIFDIR: UInt32 = 0x4000

private let dentsCap = 4096
private let pathCap = 256

private func cstrlen(_ p: UnsafePointer<CChar>) -> Int {
    var n = 0
    while p[n] != 0 { n += 1 }
    return n
}

// True for a directory entry named "." or "..".
private func isDotName(_ p: UnsafePointer<UInt8>, _ len: Int) -> Bool {
    if len == 1 && p[0] == 0x2E { return true }            // "."
    if len == 2 && p[0] == 0x2E && p[1] == 0x2E { return true } // ".."
    return false
}

// Build "dir/name\0" into `out` (capacity pathCap), collapsing a trailing slash
// on `dir` so "a/" + "b" -> "a/b". Returns the new length, or -1 if too long.
private func joinPath(_ dir: UnsafePointer<CChar>, _ dirLen: Int,
                      _ name: UnsafePointer<UInt8>, _ nameLen: Int,
                      _ out: UnsafeMutablePointer<CChar>) -> Int {
    var dl = dirLen
    while dl > 1 && dir[dl - 1] == 0x2F { dl -= 1 }        // drop trailing '/'
    if dl + 1 + nameLen + 1 > pathCap { return -1 }
    var o = 0
    var i = 0
    while i < dl { out[o] = dir[i]; o += 1; i += 1 }
    out[o] = 0x2F; o += 1                                  // '/'
    i = 0
    while i < nameLen { out[o] = CChar(bitPattern: name[i]); o += 1; i += 1 }
    out[o] = 0
    return o
}

// Recursively empty `path` (a directory), then remove it. Returns 0 on success.
private func removeDir(_ path: UnsafePointer<CChar>, force: Bool) -> Int32 {
    let fd = swiftos_open(path, oRdOnly)
    if fd < 0 {
        if force { return 0 }
        swiftos_puts("rm: cannot open directory\n")
        return 1
    }
    let dirLen = cstrlen(path)
    var status: Int32 = 0

    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: dentsCap) { dbuf in
      withUnsafeTemporaryAllocation(of: CChar.self, capacity: pathCap) { pbuf in
        let dbase = dbuf.baseAddress!
        let pbase = pbuf.baseAddress!
        while true {
            let n = swiftos_getdents(fd, UnsafeMutableRawPointer(dbase), UInt(dentsCap))
            if n <= 0 { break }
            var off = 0
            while off < Int(n) {
                let rec = dbase + off
                let reclen = Int(UInt16(rec[16]) | (UInt16(rec[17]) << 8))
                if reclen <= 0 { break }
                let namePtr = rec + 19
                var nameLen = 0
                while namePtr[nameLen] != 0 { nameLen += 1 }
                off += reclen
                if isDotName(namePtr, nameLen) { continue }
                if joinPath(path, dirLen, namePtr, nameLen, pbase) < 0 {
                    swiftos_puts("rm: path too long\n")
                    status = 1
                    continue
                }
                if removePath(pbase, force: force) != 0 { status = 1 }
            }
        }
      }
    }
    _ = swiftos_close(fd)

    if swiftos_rmdir(path) != 0 {
        swiftos_puts("rm: cannot remove directory\n")
        return 1
    }
    return status
}

// Remove a single path. A directory is descended into (callers only reach this
// for directories once `-r` has been confirmed). Returns 0 on success.
private func removePath(_ path: UnsafePointer<CChar>, force: Bool) -> Int32 {
    var mode: UInt32 = 0
    if swiftos_stat(path, &mode, nil, nil, nil, nil, nil) != 0 {
        if force { return 0 }
        swiftos_puts("rm: cannot remove file\n")
        return 1
    }
    if (mode & sIFMT) == sIFDIR {
        return removeDir(path, force: force)
    }
    if swiftos_unlink(path) != 0 {
        if force { return 0 }
        swiftos_puts("rm: cannot remove file\n")
        return 1
    }
    return 0
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp
    guard let argv = argv, argc > 1 else {
        swiftos_puts("usage: rm [-rRf] FILE...\n")
        return 1
    }

    var recursive = false
    var force = false
    var paths = false
    var status: Int32 = 0

    var i = 1
    while i < Int(argc) {
        guard let a = argv[i] else { i += 1; continue }
        if a[0] == 0x2D && a[1] != 0 {              // a flag bundle like -r / -rf
            var k = 1
            while a[k] != 0 {
                switch a[k] {
                case 0x72, 0x52: recursive = true   // 'r' / 'R'
                case 0x66:       force = true        // 'f'
                default:
                    swiftos_puts("rm: unknown option\n")
                    return 1
                }
                k += 1
            }
        } else {
            paths = true
            let p = UnsafePointer(a)
            var mode: UInt32 = 0
            if swiftos_stat(p, &mode, nil, nil, nil, nil, nil) == 0,
               (mode & sIFMT) == sIFDIR, !recursive {
                swiftos_puts("rm: is a directory\n")
                status = 1
            } else if removePath(p, force: force) != 0 {
                status = 1
            }
        }
        i += 1
    }

    if !paths && !force {
        swiftos_puts("usage: rm [-rRf] FILE...\n")
        return 1
    }
    return status
}
