// ls.swift — a native Swift `/bin/ls` for swift-os (with `-l`).
//
// Lists a directory (or a single file) using the kernel getdents/stat ABI, and
// for `-l` formats mode/owner/group/size like coreutils, resolving owner and
// group names from /etc/passwd and /etc/group (falling back to the numeric id).
// This dogfoods the M13c per-file ownership work in a pure-Swift userland tool,
// instead of relying on busybox.

private let oRdOnly: Int32 = 0
private let sIFMT: UInt32 = 0xF000
private let sIFDIR: UInt32 = 0x4000
private let sIFCHR: UInt32 = 0x2000
private let sIFIFO: UInt32 = 0x1000

// ---- small output helpers --------------------------------------------------

private func putc(_ c: UInt8) { swiftos_putc(c) }

private func putUInt(_ value: UInt64) {
    var divisor: UInt64 = 1
    while value / divisor >= 10 { divisor *= 10 }
    var rest = value
    while divisor > 0 {
        putc(0x30 + UInt8(rest / divisor))
        rest %= divisor
        divisor /= 10
    }
}

private func putBytes(_ p: UnsafePointer<UInt8>, _ len: Int) {
    var i = 0
    while i < len { putc(p[i]); i += 1 }
}

private func cstrlen(_ p: UnsafePointer<CChar>) -> Int {
    var n = 0
    while p[n] != 0 { n += 1 }
    return n
}

// ---- name resolution (uid/gid -> name) -------------------------------------

private let resolveCap = 4096

// Open `file` (an /etc colon table), find the line whose 3rd field (index 2,
// decimal) equals `id`, and print its 1st field (the name). Returns true if a
// name was printed. Used for both /etc/passwd (uid) and /etc/group (gid), which
// share the `name:x:id:...` shape.
private func printIdName(_ id: UInt32, file: StaticString) -> Bool {
    let filePtr = UnsafeRawPointer(file.utf8Start).assumingMemoryBound(to: CChar.self)
    let fd = swiftos_open(filePtr, oRdOnly)
    if fd < 0 { return false }
    var printed = false
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: resolveCap) { buf in
        let base = buf.baseAddress!
        var total = 0
        while total < resolveCap - 1 {
            let r = swiftos_read(fd, UnsafeMutableRawPointer(base + total), UInt(resolveCap - 1 - total))
            if r <= 0 { break }
            total += Int(r)
        }
        _ = swiftos_close(fd)

        var i = 0
        while i < total && !printed {
            var j = i
            while j < total && base[j] != 0x0A { j += 1 }
            let ls = i, le = j
            i = j + 1
            if le == ls || base[ls] == 0x23 { continue } // empty or comment

            // field 0 = name [ls, c0e); field 2 = numeric id.
            var c0e = ls
            while c0e < le && base[c0e] != 0x3A { c0e += 1 }
            var f = c0e + 1                              // start of field 1
            var col = 1
            while col < 2 && f < le {                    // skip to field 2
                if base[f] == 0x3A { col += 1 }
                f += 1
            }
            var v: UInt32 = 0
            var k = f
            while k < le && base[k] >= 0x30 && base[k] <= 0x39 {
                v = v * 10 + UInt32(base[k] - 0x30); k += 1
            }
            if v == id {
                putBytes(base + ls, c0e - ls)
                printed = true
            }
        }
    }
    return printed
}

private func printOwner(_ uid: UInt32) {
    if !printIdName(uid, file: "/etc/passwd") { putUInt(UInt64(uid)) }
}

private func printGroup(_ gid: UInt32) {
    if !printIdName(gid, file: "/etc/group") { putUInt(UInt64(gid)) }
}

// ---- mode formatting -------------------------------------------------------

private func printModeString(_ mode: UInt32) {
    switch mode & sIFMT {
    case sIFDIR: putc(0x64) // 'd'
    case sIFCHR: putc(0x63) // 'c'
    case sIFIFO: putc(0x70) // 'p'
    default:     putc(0x2D) // '-'
    }
    let rwx: [UInt8] = [0x72, 0x77, 0x78] // r w x
    var shift = 8
    while shift >= 0 {
        let bit = (mode >> UInt32(shift)) & 1
        putc(bit != 0 ? rwx[2 - (shift % 3)] : 0x2D)
        shift -= 1
    }
}

// Print the "YYYY-MM-DD HH:MM" prefix (16 chars) of the formatted UTC time.
private func printDate(_ mtime: UInt64) {
    withUnsafeTemporaryAllocation(of: CChar.self, capacity: 24) { tb in
        let p = tb.baseAddress!
        swiftos_fmt_time(UInt(mtime), p)   // "YYYY-MM-DD HH:MM:SS"
        putBytes(UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self), 16)
    }
}

// One long-format line: "mode nlink owner group size date name".
private func printLongEntry(_ namePtr: UnsafePointer<UInt8>, _ nameLen: Int,
                            mode: UInt32, uid: UInt32, gid: UInt32, nlink: UInt32,
                            size: UInt64, mtime: UInt64) {
    printModeString(mode)
    putc(0x20); putUInt(UInt64(nlink))
    putc(0x20); printOwner(uid)
    putc(0x20); printGroup(gid)
    putc(0x20); putUInt(size)
    putc(0x20); printDate(mtime)
    putc(0x20); putBytes(namePtr, nameLen)
    putc(0x0A)
}

// ---- directory listing -----------------------------------------------------

private let dentsCap = 2048
private let pathCap = 256

// Build "dir/name\0" into `out` (capacity pathCap). Returns false if too long.
private func joinPath(_ dir: UnsafePointer<CChar>, _ dirLen: Int,
                      _ name: UnsafePointer<UInt8>, _ nameLen: Int,
                      _ out: UnsafeMutablePointer<CChar>) -> Bool {
    if dirLen + 1 + nameLen + 1 > pathCap { return false }
    var o = 0
    var i = 0
    while i < dirLen { out[o] = dir[i]; o += 1; i += 1 }
    out[o] = 0x2F; o += 1                    // '/'
    i = 0
    while i < nameLen { out[o] = CChar(bitPattern: name[i]); o += 1; i += 1 }
    out[o] = 0
    return true
}

private func listDir(_ path: UnsafePointer<CChar>, long: Bool) -> Int32 {
    let fd = swiftos_open(path, oRdOnly)
    if fd < 0 { swiftos_puts("ls: cannot open directory\n"); return 1 }
    let dirLen = cstrlen(path)

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

                if long {
                    var mode: UInt32 = 0, uid: UInt32 = 0, gid: UInt32 = 0, nlink: UInt32 = 0
                    var size: UInt = 0, mtime: UInt = 0
                    if joinPath(path, dirLen, namePtr, nameLen, pbase),
                       swiftos_stat(pbase, &mode, &uid, &gid, &nlink, &size, &mtime) == 0 {
                        printLongEntry(namePtr, nameLen, mode: mode, uid: uid, gid: gid,
                                       nlink: nlink, size: UInt64(size), mtime: UInt64(mtime))
                    } else {
                        putBytes(namePtr, nameLen); putc(0x0A)
                    }
                } else {
                    putBytes(namePtr, nameLen); putc(0x0A)
                }
                off += reclen
            }
        }
      }
    }
    _ = swiftos_close(fd)
    return 0
}

// ---- entry point -----------------------------------------------------------

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp
    var long = false
    var pathArg: UnsafePointer<CChar>? = nil

    if let argv = argv {
        var i = 1
        while i < Int(argc) {
            if let a = argv[i] {
                if a[0] == 0x2D && a[1] != 0 { // a flag like -l / -la
                    var k = 1
                    while a[k] != 0 { if a[k] == 0x6C { long = true }; k += 1 } // 'l'
                } else if pathArg == nil {
                    pathArg = UnsafePointer(a)
                }
            }
            i += 1
        }
    }

    // Default to the current directory.
    let dot: StaticString = "."
    let path: UnsafePointer<CChar> = pathArg
        ?? UnsafeRawPointer(dot.utf8Start).assumingMemoryBound(to: CChar.self)

    var mode: UInt32 = 0, uid: UInt32 = 0, gid: UInt32 = 0, nlink: UInt32 = 0
    var size: UInt = 0, mtime: UInt = 0
    if swiftos_stat(path, &mode, &uid, &gid, &nlink, &size, &mtime) != 0 {
        swiftos_puts("ls: cannot access path\n")
        return 1
    }

    if (mode & sIFMT) == sIFDIR {
        return listDir(path, long: long)
    }

    // A single (non-directory) path: print it directly.
    let pl = cstrlen(path)
    let pu = UnsafeRawPointer(path).assumingMemoryBound(to: UInt8.self)
    if long {
        printLongEntry(pu, pl, mode: mode, uid: uid, gid: gid, nlink: nlink,
                       size: UInt64(size), mtime: UInt64(mtime))
    } else {
        putBytes(pu, pl); putc(0x0A)
    }
    return 0
}
