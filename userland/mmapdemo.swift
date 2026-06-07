// SPDX-License-Identifier: Apache-2.0
// mmapdemo.swift — native Swift `/bin/mmapdemo` for swift-os (Track B demo).
//
// B1 — anonymous mmap: map a writable buffer, confirm a fresh anonymous page
// reads as 0, fill it with a byte pattern across a page boundary, read it back,
// then munmap it. Each check prints a single `mmapdemo: <TAG> ...` line the test
// script greps. (B2 — mprotect + W^X — extends this demo in the next step.)

private let PROT_R = Int32(SWIFTOS_PROT_READ)
private let PROT_W = Int32(SWIFTOS_PROT_WRITE)

private func say(_ s: StaticString) {
    s.withUTF8Buffer { b in _ = swiftos_write(1, b.baseAddress, UInt(b.count)) }
}

// ---- B1: anonymous mmap read/write/zero -----------------------------------

private func b1AnonMmap() -> Bool {
    let len: UInt = 8192 // two pages, to cross a page boundary
    let base = swiftos_mmap(len, PROT_R | PROT_W)
    if base == 0 {
        say("mmapdemo: B1-FAIL mmap returned 0\n")
        return false
    }
    let buf = UnsafeMutablePointer<UInt8>(bitPattern: UInt(base))!

    // Anonymous memory must read as 0 before we touch it.
    var preZero = true
    for i in 0..<Int(len) where buf[i] != 0 { preZero = false; break }
    if !preZero {
        say("mmapdemo: B1-FAIL fresh mapping not zero-filled\n")
        _ = swiftos_munmap(base, len)
        return false
    }

    // Write a position-dependent pattern, then read it back.
    for i in 0..<Int(len) { buf[i] = UInt8((i * 37 + 11) & 0xff) }
    var ok = true
    for i in 0..<Int(len) where buf[i] != UInt8((i * 37 + 11) & 0xff) { ok = false; break }
    if !ok {
        say("mmapdemo: B1-FAIL pattern readback mismatch\n")
        _ = swiftos_munmap(base, len)
        return false
    }

    if swiftos_munmap(base, len) != 0 {
        say("mmapdemo: B1-FAIL munmap returned error\n")
        return false
    }
    say("mmapdemo: B1-OK anon mmap zero+write+read+munmap\n")
    return true
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp
    let ok = b1AnonMmap()
    say(ok ? "mmapdemo: ALL-OK\n" : "mmapdemo: FAILED\n")
    return ok ? 0 : 1
}
