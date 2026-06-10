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

// ---- I6: munmap of a file-backed mapping drops its demand-page VMA ---------
// The mmap cursor hands a munmap'd bottom region back to the next mmap, so a
// stale file VMA would demand-fill the NEW mapping from the OLD file's disk
// extent. Regression: map /etc/motd, munmap, map /etc/hostname into the reused
// VA — the content must be hostname's. Then recycle mmap_file+munmap more times
// than the per-process VMA table has slots (8) to prove slots are freed.

private func readPrefix(_ path: StaticString, _ out: UnsafeMutablePointer<UInt8>, _ n: Int) -> Int {
    let cpath = UnsafeRawPointer(path.utf8Start).assumingMemoryBound(to: CChar.self)
    let fd = swiftos_open(cpath, 0)
    if fd < 0 { return -1 }
    let r = swiftos_read(fd, out, UInt(n))
    _ = swiftos_close(fd)
    return Int(r)
}

private func mmapFile(_ path: StaticString) -> (UInt, UInt) {
    let cpath = UnsafeRawPointer(path.utf8Start).assumingMemoryBound(to: CChar.self)
    var mode: UInt32 = 0, uid: UInt32 = 0, gid: UInt32 = 0, nlink: UInt32 = 0
    var size: UInt = 0, mtime: UInt = 0
    if swiftos_stat(cpath, &mode, &uid, &gid, &nlink, &size, &mtime) != 0 { return (0, 0) }
    let fd = swiftos_open(cpath, 0)
    if fd < 0 { return (0, 0) }
    let base = swiftos_mmap_file(fd, size, PROT_R)
    _ = swiftos_close(fd)
    return (base, size)
}

private func i6FileMunmap() -> Bool {
    var expect = [UInt8](repeating: 0, count: 8)
    var ok = true

    // 1) motd via mmap_file matches motd via read().
    let motdLen = readPrefix("/etc/motd", &expect, 8)
    if motdLen <= 0 { say("mmapdemo: I6-FAIL cannot read /etc/motd\n"); return false }
    let (mBase, mSize) = mmapFile("/etc/motd")
    if mBase == 0 { say("mmapdemo: I6-FAIL mmap_file(/etc/motd) failed\n"); return false }
    let mPtr = UnsafePointer<UInt8>(bitPattern: UInt(mBase))!
    for i in 0..<motdLen where mPtr[i] != expect[i] { ok = false }
    if !ok { say("mmapdemo: I6-FAIL mmap_file content != read content\n"); return false }
    _ = swiftos_munmap(mBase, mSize)

    // 2) hostname mapped into the recycled VA must show hostname bytes, not
    //    stale motd bytes demand-filled through a surviving VMA.
    let hostLen = readPrefix("/etc/hostname", &expect, 8)
    if hostLen <= 0 { say("mmapdemo: I6-FAIL cannot read /etc/hostname\n"); return false }
    let (hBase, hSize) = mmapFile("/etc/hostname")
    if hBase == 0 { say("mmapdemo: I6-FAIL mmap_file(/etc/hostname) failed\n"); return false }
    let hPtr = UnsafePointer<UInt8>(bitPattern: UInt(hBase))!
    for i in 0..<hostLen where hPtr[i] != expect[i] { ok = false }
    _ = swiftos_munmap(hBase, hSize)
    if !ok { say("mmapdemo: I6-FAIL stale VMA served old file content\n"); return false }
    say("mmapdemo: I6-OK file munmap drops stale VMA\n")

    // 3) Slot recycling: more map/unmap cycles than the 8-slot VMA table.
    var cycles = 0
    while cycles < 12 {
        let (base, size) = mmapFile("/etc/motd")
        if base == 0 {
            say("mmapdemo: I6-FAIL vma slots exhausted at cycle ")
            printUInt(UInt(cycles)); say("\n")
            return false
        }
        // Touch the first byte so the mapping actually demand-faults.
        if UnsafePointer<UInt8>(bitPattern: UInt(base))![0] == 0xFF { say("") }
        _ = swiftos_munmap(base, size)
        cycles += 1
    }
    say("mmapdemo: I6-OK file vma slots recycled\n")
    return true
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp
    var ok = b1AnonMmap()
    if !b2JitAndWx() { ok = false }
    if !i6FileMunmap() { ok = false }
    say(ok ? "mmapdemo: ALL-OK\n" : "mmapdemo: FAILED\n")
    return ok ? 0 : 1
}
