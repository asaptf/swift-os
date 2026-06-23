// SPDX-License-Identifier: Apache-2.0
// shmringprobe.swift — LA3 in-QEMU acceptance probe for the shared-memory ring.
//
// Creates a full-duplex shared-memory channel (SYS_SHMRING_CREATE), forks, and
// both sides map it (SYS_SHMRING_MAP) into their own address space. The parent
// streams variable-size records into ring0; the child consumes them from ring0
// and echoes each back into ring1; the parent verifies every echo. Each record
// crosses through the mapped pages with NO syscall in the reserve/commit/peek/
// release path (the only control is the shared cursors), and the payload is
// materialized once on each side — no double copy, no per-record context switch.
//
// The producer and consumer apply backpressure to each other (reserve returns
// nil when full), so the run exercises the ring near-full and across many wrap
// boundaries. Prints "SHMRING OK:" when every record round-trips, or a FAIL
// marker otherwise; tests/shmring_test.sh greps for them.
//
// The same sans-IO ring core (kernel/ipc/shmring.swift) drives both sides, built
// here with -D SHMRING_USER so the cursor accessors use SEQ_CST atomics for
// cross-process / cross-CPU acquire/release ordering.

private let channelPages: UInt = 2          // -> two 4 KiB ring regions
private let pageBytes: UInt = 4096
private let ringHalfBytes: Int = Int(channelPages * pageBytes / 2)   // ring0 @ +0, ring1 @ +ringHalfBytes
private let recordCount = 64
private let spinLimit = 5_000_000           // bail rather than hang if the peer dies

private func putUInt(_ value: UInt) {
    if value == 0 { swiftos_putc(0x30); return }
    var digits = [UInt8](repeating: 0, count: 20)
    var n = value
    var count = 0
    while n > 0 { digits[count] = UInt8(0x30 + Int(n % 10)); n /= 10; count += 1 }
    while count > 0 { count -= 1; swiftos_putc(digits[count]) }
}

// Deterministic payload: length 1..200, content a function of the record index
// so the consumer can verify both the framing and the bytes.
private func recLen(_ i: Int) -> Int { (i % 200) + 1 }

@inline(__always) private func recByte(_ seed: Int, _ i: Int) -> UInt8 {
    UInt8((seed &* 31 &+ i &* 7 &+ 13) & 0xff)
}

private func fillRecord(_ p: UnsafeMutableRawPointer, _ seed: Int, _ n: Int) {
    var i = 0
    while i < n { p.storeBytes(of: recByte(seed, i), toByteOffset: i, as: UInt8.self); i += 1 }
}

private func verifyRecord(_ p: UnsafeRawPointer, _ seed: Int, _ n: Int) -> Bool {
    var i = 0
    while i < n {
        if p.load(fromByteOffset: i, as: UInt8.self) != recByte(seed, i) { return false }
        i += 1
    }
    return true
}

private func copyBytes(_ dst: UnsafeMutableRawPointer, _ src: UnsafeRawPointer, _ n: Int) {
    var i = 0
    while i < n { dst.storeBytes(of: src.load(fromByteOffset: i, as: UInt8.self), toByteOffset: i, as: UInt8.self); i += 1 }
}

// Child: drain ring0, echo each record into ring1, verifying content. Both rings
// can back-pressure, so we never drop a peeked ring0 record until its echo lands
// in ring1. Returns the process exit status (0 on success) — main _exits with it.
private func runChild(_ ring0: UnsafeMutableRawPointer, _ ring1: UnsafeMutableRawPointer) -> Int32 {
    var done = 0
    var spins = 0
    while done < recordCount {
        var len: UInt32 = 0
        guard let src = shmRingPeek(ring0, &len) else {
            spins += 1
            if spins > spinLimit { swiftos_puts("SHMRING FAIL: child timed out waiting for ring0\n"); return 1 }
            swiftos_nanosleep(0, 0)
            continue
        }
        let n = Int(len)
        if !verifyRecord(src, done, n) {
            swiftos_puts("SHMRING FAIL: child saw corrupt record\n"); return 1
        }
        // Echo into ring1; if it is full, keep the ring0 record and retry.
        guard let dst = shmRingReserve(ring1, len) else {
            spins += 1
            if spins > spinLimit { swiftos_puts("SHMRING FAIL: child timed out on ring1\n"); return 1 }
            swiftos_nanosleep(0, 0)
            continue
        }
        copyBytes(dst, src, n)
        shmRingCommit(ring1, len)
        shmRingRelease(ring0)
        done += 1
        spins = 0
    }
    return 0
}

// Parent: produce all records into ring0 while draining echoes from ring1, then
// confirm every echo matched. Returns true on success.
private func runParent(_ ring0: UnsafeMutableRawPointer, _ ring1: UnsafeMutableRawPointer) -> Bool {
    var produced = 0
    var acked = 0
    var spins = 0
    while acked < recordCount {
        var progressed = false
        if produced < recordCount {
            let n = recLen(produced)
            if let dst = shmRingReserve(ring0, UInt32(n)) {
                fillRecord(dst, produced, n)
                shmRingCommit(ring0, UInt32(n))
                produced += 1
                progressed = true
            }
        }
        var len: UInt32 = 0
        if let src = shmRingPeek(ring1, &len) {
            let n = Int(len)
            if n != recLen(acked) || !verifyRecord(src, acked, n) {
                swiftos_puts("SHMRING FAIL: parent echo mismatch\n")
                return false
            }
            shmRingRelease(ring1)
            acked += 1
            progressed = true
        }
        if !progressed {
            spins += 1
            if spins > spinLimit { swiftos_puts("SHMRING FAIL: parent timed out\n"); return false }
            swiftos_nanosleep(0, 0)
        } else {
            spins = 0
        }
    }
    return true
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp

    let id = swiftos_shmring_create(UInt(channelPages))   // long -> Int
    if id < 0 {
        swiftos_puts("SHMRING FAIL: shmring_create errno ")
        putUInt(UInt(-id)); swiftos_putc(0x0a)
        return 1
    }
    let cid = Int32(id)

    let pid = swiftos_fork()   // int -> Int32
    if pid < 0 {
        swiftos_puts("SHMRING FAIL: fork failed\n")
        _ = swiftos_shmring_close(cid)
        return 1
    }

    // Each side maps the channel by id into its OWN address space (mapping after
    // the fork, so the pages are genuinely shared, not COW-split).
    let va = swiftos_shmring_map(cid)   // long -> Int (base VA, or negative errno)
    if va <= 0 {
        swiftos_puts("SHMRING FAIL: shmring_map failed\n")
        if pid != 0 { _ = swiftos_shmring_close(cid) }
        return 1
    }
    let ring0 = UnsafeMutableRawPointer(bitPattern: va)!
    let ring1 = UnsafeMutableRawPointer(bitPattern: va + ringHalfBytes)!

    if pid == 0 {
        return runChild(ring0, ring1)   // crt0 _exits with this status
    }

    let ok = runParent(ring0, ring1)
    var status: Int32 = 0
    _ = swiftos_waitpid(pid, &status)
    _ = swiftos_shmring_close(cid)

    let childOk = ((status >> 8) & 0xff) == 0
    if ok && childOk {
        swiftos_puts("SHMRING OK: ")
        putUInt(UInt(recordCount))
        swiftos_puts(" records round-tripped full-duplex via mapped pages, no per-record syscall\n")
        return 0
    }
    swiftos_puts("SHMRING FAIL: round-trip incomplete\n")
    return 1
}
