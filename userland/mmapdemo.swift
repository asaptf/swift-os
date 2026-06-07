// SPDX-License-Identifier: Apache-2.0
// mmapdemo.swift — native Swift `/bin/mmapdemo` for swift-os (Track B demo).
//
// Exercises the mmap/munmap/mprotect syscalls and the W^X invariant end to end:
//
//   B1 — anonymous mmap: map a writable buffer, fill it with a byte pattern,
//        read it back (and confirm a fresh anonymous page reads as 0 first),
//        then munmap it.
//
//   B2 — mprotect + W^X, the JIT pattern: mmap a page RW, write a tiny AArch64
//        function into it (`mov w0,#42; ret`), mprotect the page RW -> RX, then
//        call it through a function pointer and check it returns 42. Finally
//        assert the two things W^X must forbid: mmap RWX fails, and mprotect to
//        RWX on a live mapping fails.
//
// Each check prints a single `mmapdemo: <TAG> ...` line the test script greps.

private let PROT_R = Int32(SWIFTOS_PROT_READ)
private let PROT_W = Int32(SWIFTOS_PROT_WRITE)
private let PROT_X = Int32(SWIFTOS_PROT_EXEC)

private func say(_ s: StaticString) {
    s.withUTF8Buffer { b in _ = swiftos_write(1, b.baseAddress, UInt(b.count)) }
}

private func printUInt(_ v: UInt) {
    if v >= 10 { printUInt(v / 10) }
    swiftos_putc(UInt8(0x30 + (v % 10)))
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

// ---- B2: the JIT pattern + W^X --------------------------------------------

// `mov w0, #42 ; ret`, little-endian AArch64 (4 bytes each).
private let jitCode: [UInt8] = [0x40, 0x05, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6]

private func b2JitAndWx() -> Bool {
    var ok = true

    // 1) mmap RW, write the function bytes.
    let len: UInt = 4096
    let base = swiftos_mmap(len, PROT_R | PROT_W)
    if base == 0 {
        say("mmapdemo: B2-FAIL mmap RW returned 0\n")
        return false
    }
    let code = UnsafeMutablePointer<UInt8>(bitPattern: UInt(base))!
    for i in 0..<jitCode.count { code[i] = jitCode[i] }

    // 2) mprotect RW -> RX. This must succeed (W^X allows RX).
    if swiftos_mprotect(base, len, PROT_R | PROT_X) != 0 {
        say("mmapdemo: B2-FAIL mprotect RW->RX rejected\n")
        _ = swiftos_munmap(base, len)
        return false
    }

    // 3) Call the freshly-executable code through a function pointer.
    let fn = unsafeBitCast(UnsafeRawPointer(bitPattern: UInt(base))!,
                           to: (@convention(c) () -> Int32).self)
    let r = fn()
    if r == 42 {
        say("mmapdemo: B2-OK jit RW->RX call returned 42\n")
    } else {
        say("mmapdemo: B2-FAIL jit call returned ")
        printUInt(UInt(bitPattern: Int(r)))
        swiftos_putc(0x0A)
        ok = false
    }

    // 4) W^X: mprotect of a live mapping to RWX must fail.
    if swiftos_mprotect(base, len, PROT_R | PROT_W | PROT_X) == 0 {
        say("mmapdemo: B2-FAIL mprotect ->RWX was allowed (W^X breach)\n")
        ok = false
    } else {
        say("mmapdemo: WX-OK mprotect ->RWX rejected\n")
    }

    _ = swiftos_munmap(base, len)

    // 5) W^X: mmap RWX must fail (return 0, no mapping handed out).
    let rwx = swiftos_mmap(len, PROT_R | PROT_W | PROT_X)
    if rwx != 0 {
        say("mmapdemo: B2-FAIL mmap RWX was allowed (W^X breach)\n")
        _ = swiftos_munmap(rwx, len)
        ok = false
    } else {
        say("mmapdemo: WX-OK mmap RWX rejected\n")
    }

    return ok
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp
    var ok = b1AnonMmap()
    if !b2JitAndWx() { ok = false }
    say(ok ? "mmapdemo: ALL-OK\n" : "mmapdemo: FAILED\n")
    return ok ? 0 : 1
}
