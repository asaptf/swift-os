// SPDX-License-Identifier: Apache-2.0
// wc.swift — native Swift `/bin/wc` for swift-os.
//
// Counts lines, words, and bytes of each file argument and prints
// "L W C name". With no file argument it reads standard input.

private let oRdOnly: Int32 = 0
private let bufCap = 4096

private func putUInt(_ value: UInt64, width: Int) {
    var digits = [UInt8](repeating: 0, count: 20)
    var n = 0
    var v = value
    repeat { digits[n] = 0x30 + UInt8(v % 10); v /= 10; n += 1 } while v > 0
    var pad = width - n
    while pad > 0 { swiftos_putc(0x20); pad -= 1 }
    while n > 0 { n -= 1; swiftos_putc(digits[n]) }
}

private func isSpace(_ c: UInt8) -> Bool {
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0B || c == 0x0C
}

// Count (lines, words, bytes) of an open fd.
private func countFd(_ fd: Int32) -> (UInt64, UInt64, UInt64) {
    var lines: UInt64 = 0, words: UInt64 = 0, bytes: UInt64 = 0
    var inWord = false
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: bufCap) { buf in
        let base = buf.baseAddress!
        while true {
            let r = swiftos_read(fd, UnsafeMutableRawPointer(base), UInt(bufCap))
            if r <= 0 { break }
            for i in 0..<Int(r) {
                let c = base[i]
                bytes += 1
                if c == 0x0A { lines += 1 }
                if isSpace(c) { inWord = false }
                else if !inWord { inWord = true; words += 1 }
            }
        }
    }
    return (lines, words, bytes)
}

private func report(_ l: UInt64, _ w: UInt64, _ c: UInt64, name: UnsafePointer<CChar>?, nameLen: Int) {
    putUInt(l, width: 7); swiftos_putc(0x20)
    putUInt(w, width: 7); swiftos_putc(0x20)
    putUInt(c, width: 7)
    if let name = name {
        swiftos_putc(0x20)
        let p = UnsafeRawPointer(name).assumingMemoryBound(to: UInt8.self)
        for i in 0..<nameLen { swiftos_putc(p[i]) }
    }
    swiftos_putc(0x0A)
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp
    if argc <= 1 || argv == nil {
        let (l, w, c) = countFd(0)   // stdin
        report(l, w, c, name: nil, nameLen: 0)
        return 0
    }
    var status: Int32 = 0
    var i = 1
    while i < Int(argc) {
        if let p = argv![i] {
            let fd = swiftos_open(UnsafePointer(p), oRdOnly)
            if fd < 0 {
                swiftos_puts("wc: cannot open file\n")
                status = 1
            } else {
                let (l, w, c) = countFd(fd)
                _ = swiftos_close(fd)
                var nl = 0
                while p[nl] != 0 { nl += 1 }
                report(l, w, c, name: p, nameLen: nl)
            }
        }
        i += 1
    }
    return status
}
