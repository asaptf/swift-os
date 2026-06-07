// SPDX-License-Identifier: Apache-2.0
// cat.swift — native Swift `/bin/cat` for swift-os.
//
// Concatenates files (or stdin when given no file arguments) to stdout, using
// the kernel open/read/write syscalls via the Swift userland bridge.

private let oRdOnly: Int32 = 0
private let chunk = 4096

// Copy everything from `fd` to stdout. Returns false on a read error.
private func catFd(_ fd: Int32) -> Bool {
    var ok = true
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: chunk) { buf in
        let base = buf.baseAddress!
        while true {
            let r = swiftos_read(fd, UnsafeMutableRawPointer(base), UInt(chunk))
            if r < 0 { ok = false; break }
            if r == 0 { break }
            var off = 0
            while off < Int(r) {
                let w = swiftos_write(1, UnsafeRawPointer(base + off), UInt(Int(r) - off))
                if w <= 0 { ok = false; break }
                off += Int(w)
            }
            if !ok { break }
        }
    }
    return ok
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp
    var status: Int32 = 0
    var sawFile = false

    if let argv = argv {
        var i = 1
        while i < Int(argc) {
            if let path = argv[i] {
                sawFile = true
                let fd = swiftos_open(UnsafePointer(path), oRdOnly)
                if fd < 0 {
                    swiftos_puts("cat: cannot open file\n")
                    status = 1
                } else {
                    if !catFd(fd) { status = 1 }
                    _ = swiftos_close(fd)
                }
            }
            i += 1
        }
    }

    if !sawFile {
        if !catFd(0) { status = 1 }   // no args: copy stdin
    }
    return status
}
