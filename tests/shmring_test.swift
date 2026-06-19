// SPDX-License-Identifier: Apache-2.0
// shmring_test.swift — host unit test for the sans-IO SPSC ring in
// kernel/ipc/shmring.swift (LA3 step 1).
//
// The ring is the data-plane primitive a userland network service (and the
// Node.js / AI data paths) will map and drive without a syscall per record. This
// test runs the ring entirely on the host — no kernel, no QEMU — and pins:
//   * empty / full edge behaviour,
//   * length-prefixed variable-size records round-trip byte-for-byte,
//   * free-space and available accounting,
//   * the publish discipline (a reserved-but-uncommitted record is invisible to
//     the consumer until commit advances the cursor), and
//   * wraparound across the masked boundary, including the pad-marker path.
//
// Built with -D SHMRING_HOST so the cursor accessors are plain loads/stores
// (single-threaded; program order is enough).
//
//   compiled as:  swiftc -D SHMRING_HOST tests/shmring_test.swift kernel/ipc/shmring.swift

import Foundation

var failures = 0
func check(_ cond: Bool, _ what: String) {
    if cond { print("ok: \(what)") }
    else { failures += 1; FileHandle.standardError.write(Data("FAIL: \(what)\n".utf8)) }
}

// Write one record carrying `bytes` via reserve/commit. Returns false if it did
// not fit. Asserts the publish discipline: the record stays invisible between
// reserve and commit.
func produce(_ region: UnsafeMutableRawPointer, _ bytes: [UInt8], assertHidden: Bool = false) -> Bool {
    let len = UInt32(bytes.count)
    guard let dst = shmRingReserve(region, len) else { return false }
    bytes.withUnsafeBytes { src in
        if src.count > 0 { dst.copyMemory(from: src.baseAddress!, byteCount: src.count) }
    }
    if assertHidden {
        var l: UInt32 = 0
        check(shmRingPeek(region, &l) == nil, "reserved-but-uncommitted record is invisible to the consumer")
    }
    shmRingCommit(region, len)
    return true
}

// Consume one record into a Swift array via peek/release. Returns nil if empty.
func consume(_ region: UnsafeMutableRawPointer) -> [UInt8]? {
    var len: UInt32 = 0
    guard let src = shmRingPeek(region, &len) else { return nil }
    var out = [UInt8](repeating: 0, count: Int(len))
    if len > 0 {
        out.withUnsafeMutableBytes { dst in
            dst.baseAddress!.copyMemory(from: src, byteCount: Int(len))
        }
    }
    shmRingRelease(region)
    return out
}

func pattern(_ seed: Int, _ n: Int) -> [UInt8] {
    var a = [UInt8](repeating: 0, count: n)
    for i in 0..<n { a[i] = UInt8((seed &* 31 &+ i &* 7 &+ 13) & 0xff) }
    return a
}

@main
struct ShmRingTest {
    static func main() {
        // Region: 192-byte header + 256-byte payload => capacity 256.
        let total = shmRingHeaderBytes + 256
        let region = UnsafeMutableRawPointer.allocate(byteCount: total, alignment: 64)
        defer { region.deallocate() }
        region.initializeMemory(as: UInt8.self, repeating: 0, count: total)

        // ---- init / header --------------------------------------------------
        check(shmRingInit(region: region, bytes: total), "init succeeds on a sufficiently large region")
        check(shmRingValid(region), "header validates after init")
        check(shmRingCapacity(region) == 256, "capacity is the floor power of two (256)")
        check(shmRingAvailable(region) == 0, "fresh ring has nothing available")
        check(shmRingFreeSpace(region) == 256, "fresh ring free space == capacity")

        // Too-small region rejected; capacity stays a power of two.
        let tiny = UnsafeMutableRawPointer.allocate(byteCount: shmRingHeaderBytes + 8, alignment: 64)
        defer { tiny.deallocate() }
        check(!shmRingInit(region: tiny, bytes: shmRingHeaderBytes + 8), "too-small region rejected")

        // ---- empty edge -----------------------------------------------------
        var l: UInt32 = 0
        check(shmRingPeek(region, &l) == nil, "peek on empty ring returns nil")
        consumeIsNil(region)

        // ---- publish discipline + single record round-trip ------------------
        let r0 = pattern(1, 10)
        check(produce(region, r0, assertHidden: true), "10-byte record reserved+committed")
        // slot = 4 (header) + roundUp4(10)=12 => 16 bytes outstanding.
        check(shmRingAvailable(region) == 16, "available reflects framed slot size (16)")
        check(shmRingFreeSpace(region) == 240, "free space drops by the slot size")
        let g0 = consume(region)
        check(g0 != nil && g0! == r0, "10-byte record round-trips byte-for-byte")
        check(shmRingAvailable(region) == 0, "ring empty again after release")
        check(shmRingFreeSpace(region) == 256, "free space restored after release")

        // ---- variable-size records, FIFO order ------------------------------
        let sizes = [0, 1, 4, 5, 7, 31, 32, 40]
        var sent: [[UInt8]] = []
        for (i, s) in sizes.enumerated() {
            let rec = pattern(100 + i, s)
            if produce(region, rec) { sent.append(rec) }
        }
        var idx = 0
        while let got = consume(region) {
            check(got == sent[idx], "variable record \(idx) (\(sent[idx].count) bytes) round-trips in order")
            idx += 1
        }
        check(idx == sent.count, "every committed record was read back exactly once")

        // ---- full edge ------------------------------------------------------
        // A record larger than capacity can never be reserved.
        check(shmRingReserve(region, 300) == nil, "record larger than capacity is rejected")
        // Fill until reserve fails; the ring must refuse rather than overrun.
        var filled = 0
        while produce(region, pattern(filled, 50)) { filled += 1 }
        check(filled > 0, "filled the ring with several 50-byte records")
        check(shmRingReserve(region, 50) == nil, "reserve fails when the ring is full")
        check(shmRingFreeSpace(region) < 54, "free space below one full slot when full")
        // Drain it.
        var drained = 0
        while let got = consume(region) {
            check(got == pattern(drained, 50), "fill record \(drained) round-trips")
            drained += 1
        }
        check(drained == filled, "drained exactly what was filled")
        check(shmRingFreeSpace(region) == 256, "free space fully restored after drain")

        // ---- explicit wraparound + pad marker -------------------------------
        // Re-init so the tail starts at 0 (a 200-byte record only fits from an
        // aligned start — see the size bound in shmring.swift).
        check(shmRingInit(region: region, bytes: total), "re-init resets cursors for the wrap case")
        // 200-byte payload (slot 204) at pos 0 advances tail to 204; draining
        // moves head to 204. The next 200-byte record cannot fit in the 52-byte
        // tail fragment, so the producer writes a pad marker and lays the record
        // at offset 0 — the consumer must transparently skip the pad.
        let w0 = pattern(7000, 200)
        check(produce(region, w0), "first 200-byte record (no wrap)")
        check(consume(region)! == w0, "first 200-byte record round-trips")
        let w1 = pattern(8000, 200)
        check(produce(region, w1), "second 200-byte record forces a wrap (pad marker)")
        let gw1 = consume(region)
        check(gw1 != nil && gw1! == w1, "wrapped 200-byte record round-trips across the boundary")
        check(shmRingAvailable(region) == 0, "ring empty after the wrap exchange")

        // ---- sustained wrap churn, keeping depth 2 --------------------------
        // Many crossings with the consumer one record behind the producer, so the
        // wrap pad lands while head != 0 (the general case).
        var q: [[UInt8]] = []
        for iter in 0..<400 {
            let rec = pattern(iter, (iter % 37) + 1)
            if produce(region, rec) { q.append(rec) }
            if q.count >= 2 {
                let got = consume(region)
                check(got != nil && got! == q.removeFirst(), "churn record round-trips (iter \(iter))")
            }
        }
        while let got = consume(region) {
            check(got == q.removeFirst(), "churn drain record round-trips")
        }
        check(q.isEmpty, "every churn record accounted for")

        if failures == 0 {
            print("SHMRING UNIT OK: SPSC ring edges, framing, accounting, wraparound")
        } else {
            FileHandle.standardError.write(Data("shmring_test: \(failures) failure(s)\n".utf8))
            exit(1)
        }
    }

    static func consumeIsNil(_ region: UnsafeMutableRawPointer) {
        check(consume(region) == nil, "consume on empty ring returns nil")
    }
}
