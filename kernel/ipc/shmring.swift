// SPDX-License-Identifier: Apache-2.0
// shmring.swift — sans-IO single-producer/single-consumer shared-memory ring.
//
// LA3 step 1. This is the protocol core for the shared-memory data path that an
// eventual userland network service (and the Node.js / AI data planes) map and
// drive directly, without a syscall per record. Like the net core in kernel/net,
// it performs NO I/O and owns NO memory: every entry point operates on a
// caller-provided raw region (a page the channel layer maps/shares separately),
// so the exact same file compiles and runs in three places —
//   * the kernel (channel setup; default build, real SMP barriers),
//   * a host unit test (-D SHMRING_HOST; single-threaded, plain accesses), and
//   * an Embedded-Swift userland program (-D SHMRING_USER; SEQ_CST atomics).
//
// Layout of one ring inside its region (little-endian, byte offsets):
//   0   magic     UInt32  ("SHMR")
//   4   version   UInt32
//   8   capacity  UInt32  (power-of-two payload byte count, derived at init)
//   64  head      UInt32  (consumer-owned monotonic byte cursor; own cache line)
//   128 tail      UInt32  (producer-owned monotonic byte cursor; own cache line)
//   192 data[capacity]
// head/tail sit on separate 64-byte lines so a producer on one CPU and a
// consumer on another never ping-pong the same line. Cursors are free-running
// UInt32 counters; the physical position is `cursor & (capacity-1)` (kfifo
// style). Outstanding bytes = tail &- head, always < capacity by invariant.
//
// Records are length-prefixed and 4-byte aligned: each slot is
//   [UInt32 len][len payload bytes][pad to 4]
// A record never straddles the physical end of the data area, so reserve/peek
// can hand back ONE contiguous pointer (true zero-copy). When a record would
// not fit before the end, the producer writes a pad marker (len == 0xFFFFFFFF)
// at the tail fragment and lays the record down at offset 0; the consumer
// derives the same skip and steps over it. Keeping every advance 4-aligned
// guarantees the 4-byte header itself never straddles the boundary.
//
// SPSC correctness comes entirely from the cursor publish/consume ordering, not
// from locks: the producer writes the payload + header, then publishes `tail`
// with release ordering; the consumer reads `tail` with acquire ordering before
// touching the payload. No reflection, no existentials, no heap, allocation-free.
//
// Size bound: a record's framed slot is `4 + roundUp4(len)` and a wrap can burn
// up to `slot` bytes of pad, so a record is *guaranteed* fittable in an empty
// ring only while `slot <= capacity/2` (i.e. len <= capacity/2 - 4). Larger
// records still succeed when the tail happens to be near a wrap boundary, but
// reserve will refuse (return nil) rather than overrun when it cannot place one;
// callers must handle that. Datagram payloads are far below this bound.

// "SHMR"
let shmRingMagic: UInt32 = 0x53484D52
let shmRingVersion: UInt32 = 1

// Header geometry. head and tail each occupy their own 64-byte cache line.
let shmRingHeaderBytes: Int = 192
private let offMagic = 0
private let offVersion = 4
private let offCapacity = 8
private let offHead = 64
private let offTail = 128

// A record whose stored length equals this is not a record but a "skip to the
// next physical wrap boundary" marker. No real payload can be this large
// (reserve rejects len >= capacity), so the value is unambiguous.
private let shmRingPadMarker: UInt32 = 0xFFFF_FFFF

// Smallest capacity we will accept; comfortably larger than one record header.
private let shmRingMinCapacity: UInt32 = 64

// --- cursor publish/consume ordering ----------------------------------------
// The cursor accessors are the ONLY place memory ordering is enforced. They are
// the single line that differs across the three build flavours; everything else
// in this file is plain arithmetic over the caller's region.
#if SHMRING_HOST
// Host unit test: single-threaded, so program order is enough — plain accesses.
@inline(__always) private func shmRingLoadCursor(_ p: UnsafeRawPointer) -> UInt32 {
    p.load(as: UInt32.self)
}
@inline(__always) private func shmRingStoreCursor(_ p: UnsafeMutableRawPointer, _ v: UInt32) {
    p.storeBytes(of: v, as: UInt32.self)
}
#elseif SHMRING_USER
// Userland (cross-process, possibly cross-CPU): SEQ_CST atomics on the 32-bit
// cursor word emit LDAR/STLR on aarch64, giving the acquire/release ordering
// SPSC needs. The C bridge declares these (userland/lib/swift_user.h).
@inline(__always) private func shmRingLoadCursor(_ p: UnsafeRawPointer) -> UInt32 {
    swiftos_atomic_load(UnsafeMutablePointer(mutating: p.assumingMemoryBound(to: UInt32.self)))
}
@inline(__always) private func shmRingStoreCursor(_ p: UnsafeMutableRawPointer, _ v: UInt32) {
    swiftos_atomic_store(p.assumingMemoryBound(to: UInt32.self), v)
}
#else
// Kernel: the same SMP barriers socket.swift uses. Acquire = load then
// load-barrier; release = store-barrier then store.
@inline(__always) private func shmRingLoadCursor(_ p: UnsafeRawPointer) -> UInt32 {
    let v = p.load(as: UInt32.self)
    smpLoadBarrier()
    return v
}
@inline(__always) private func shmRingStoreCursor(_ p: UnsafeMutableRawPointer, _ v: UInt32) {
    smpStoreBarrier()
    p.storeBytes(of: v, as: UInt32.self)
}
#endif

@inline(__always) private func shmRingRoundUp4(_ n: UInt32) -> UInt32 {
    (n &+ 3) & ~UInt32(3)
}

@inline(__always) private func shmRingIsPowerOfTwo(_ n: UInt32) -> Bool {
    n != 0 && (n & (n &- 1)) == 0
}

// Largest power of two <= n (n >= 1). Returns 0 for n == 0.
private func shmRingFloorPow2(_ n: UInt32) -> UInt32 {
    if n == 0 { return 0 }
    var p: UInt32 = 1
    while p <= n / 2 { p <<= 1 }
    return p
}

@inline(__always) private func shmRingDataBase(_ region: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
    region.advanced(by: shmRingHeaderBytes)
}

@inline(__always) private func shmRingLoadU32(_ base: UnsafeRawPointer, _ off: UInt32) -> UInt32 {
    base.load(fromByteOffset: Int(off), as: UInt32.self)
}

@inline(__always) private func shmRingStoreU32(_ base: UnsafeMutableRawPointer, _ off: UInt32, _ v: UInt32) {
    base.storeBytes(of: v, toByteOffset: Int(off), as: UInt32.self)
}

/// Initialize a ring at the start of `region`, spanning `bytes` total bytes
/// (header + data). The usable payload capacity is the largest power of two that
/// fits in `bytes - headerBytes`. Returns false if the region is too small.
@discardableResult
func shmRingInit(region: UnsafeMutableRawPointer, bytes: Int) -> Bool {
    if bytes < shmRingHeaderBytes + Int(shmRingMinCapacity) { return false }
    let availInt = bytes - shmRingHeaderBytes
    // Clamp before narrowing so a huge region can't overflow the UInt32 cursor space.
    let avail = availInt > Int(UInt32.max >> 1) ? (UInt32.max >> 1) : UInt32(availInt)
    let cap = shmRingFloorPow2(avail)
    if cap < shmRingMinCapacity { return false }
    region.storeBytes(of: shmRingMagic, toByteOffset: offMagic, as: UInt32.self)
    region.storeBytes(of: shmRingVersion, toByteOffset: offVersion, as: UInt32.self)
    region.storeBytes(of: cap, toByteOffset: offCapacity, as: UInt32.self)
    shmRingStoreCursor(region.advanced(by: offHead), 0)
    shmRingStoreCursor(region.advanced(by: offTail), 0)
    return true
}

/// True if `region` holds a well-formed ring header (magic/version/pow2 cap).
func shmRingValid(_ region: UnsafeRawPointer) -> Bool {
    if region.load(fromByteOffset: offMagic, as: UInt32.self) != shmRingMagic { return false }
    if region.load(fromByteOffset: offVersion, as: UInt32.self) != shmRingVersion { return false }
    let cap = region.load(fromByteOffset: offCapacity, as: UInt32.self)
    return shmRingIsPowerOfTwo(cap) && cap >= shmRingMinCapacity
}

@inline(__always) func shmRingCapacity(_ region: UnsafeRawPointer) -> UInt32 {
    region.load(fromByteOffset: offCapacity, as: UInt32.self)
}

/// Bytes currently committed and not yet released (consumer-visible payload +
/// framing + any pad). Reads both cursors with acquire ordering so it is correct
/// called from either side.
func shmRingAvailable(_ region: UnsafeRawPointer) -> UInt32 {
    let tail = shmRingLoadCursor(region.advanced(by: offTail))
    let head = shmRingLoadCursor(region.advanced(by: offHead))
    return tail &- head
}

/// Bytes the producer may still consume (capacity minus outstanding).
func shmRingFreeSpace(_ region: UnsafeRawPointer) -> UInt32 {
    let cap = shmRingCapacity(region)
    return cap &- shmRingAvailable(region)
}

// Where a record of `len` payload bytes lands given the current `tail`.
// `advance` is the total cursor delta (record slot + any wrap pad). `ok` is
// false when the record can never fit (len too big) — distinct from "doesn't
// fit right now", which the caller decides by comparing `advance` to free space.
private struct ShmRingPlacement {
    var payloadPhys: UInt32   // physical byte offset of the payload in the data area
    var headerPhys: UInt32    // physical byte offset of the record's length prefix
    var padPhys: UInt32       // physical offset of the pad marker (only if wrap)
    var wrap: Bool
    var advance: UInt32       // total cursor advance for tail
    var ok: Bool
}

private func shmRingPlace(tail: UInt32, len: UInt32, capacity: UInt32) -> ShmRingPlacement {
    var pl = ShmRingPlacement(payloadPhys: 0, headerPhys: 0, padPhys: 0,
                              wrap: false, advance: 0, ok: false)
    // A real length must be representable and the whole slot must fit in an empty
    // ring; reject the pad sentinel and anything that can never fit.
    if len >= shmRingPadMarker { return pl }
    let slot = 4 &+ shmRingRoundUp4(len)              // header + padded payload
    if slot > capacity { return pl }
    let mask = capacity &- 1
    let pos = tail & mask                             // 4-aligned write position
    let contig = capacity &- pos                      // bytes to the physical end (mult of 4, >= 4)
    if slot > contig {
        // Wrap: pad the tail fragment, lay the record down at offset 0.
        if contig &+ slot > capacity { return pl }    // cannot fit even when empty at this pos
        pl.wrap = true
        pl.padPhys = pos
        pl.headerPhys = 0
        pl.payloadPhys = 4
        pl.advance = contig &+ slot
    } else {
        pl.headerPhys = pos
        pl.payloadPhys = pos &+ 4
        pl.advance = slot
    }
    pl.ok = true
    return pl
}

/// Producer: reserve space for one record of `len` payload bytes. On success
/// returns a pointer INTO the shared region where the producer writes exactly
/// `len` bytes; the record is not visible to the consumer until shmRingCommit.
/// Returns nil if `len` is invalid or the record does not fit right now.
func shmRingReserve(_ region: UnsafeMutableRawPointer, _ len: UInt32) -> UnsafeMutableRawPointer? {
    let cap = shmRingCapacity(region)
    let tail = shmRingLoadCursor(region.advanced(by: offTail))   // producer owns tail
    let pl = shmRingPlace(tail: tail, len: len, capacity: cap)
    if !pl.ok { return nil }
    if pl.advance > shmRingFreeSpace(region) { return nil }
    return shmRingDataBase(region).advanced(by: Int(pl.payloadPhys))
}

/// Producer: publish the record reserved for `len` payload bytes (the same `len`
/// passed to the matching shmRingReserve, after the payload has been written).
/// Writes the framing then publishes `tail` with release ordering.
func shmRingCommit(_ region: UnsafeMutableRawPointer, _ len: UInt32) {
    let cap = shmRingCapacity(region)
    let tail = shmRingLoadCursor(region.advanced(by: offTail))
    let pl = shmRingPlace(tail: tail, len: len, capacity: cap)
    if !pl.ok { return }
    let data = shmRingDataBase(region)
    if pl.wrap {
        shmRingStoreU32(data, pl.padPhys, shmRingPadMarker)
    }
    shmRingStoreU32(data, pl.headerPhys, len)
    // Release: the store-barrier inside shmRingStoreCursor orders the framing and
    // the caller's payload writes ahead of the published tail.
    shmRingStoreCursor(region.advanced(by: offTail), tail &+ pl.advance)
}

// Resolve the record at the consumer's current head: its payload offset, length,
// and the cursor advance to step over it (including any wrap pad). Caller must
// have established head != tail (non-empty) first.
private func shmRingConsume(_ region: UnsafeRawPointer, head: UInt32, capacity: UInt32)
    -> (payloadPhys: UInt32, len: UInt32, advance: UInt32) {
    let data = shmRingDataBase(UnsafeMutableRawPointer(mutating: region))
    let mask = capacity &- 1
    let pos = head & mask
    let hdr = shmRingLoadU32(data, pos)
    if hdr == shmRingPadMarker {
        let skip = capacity &- pos                 // step over the padded tail fragment
        let len = shmRingLoadU32(data, 0)          // real record starts at offset 0
        return (4, len, skip &+ 4 &+ shmRingRoundUp4(len))
    }
    return (pos &+ 4, hdr, 4 &+ shmRingRoundUp4(hdr))
}

/// Consumer: look at the next record without consuming it. On success returns a
/// pointer to its payload inside the shared region and writes the payload length
/// to `outLen`. Returns nil if the ring is empty. The acquire load of `tail`
/// happens before any payload byte is read, so a committed record is fully
/// visible here.
func shmRingPeek(_ region: UnsafeRawPointer, _ outLen: UnsafeMutablePointer<UInt32>) -> UnsafeRawPointer? {
    let tail = shmRingLoadCursor(region.advanced(by: offTail))   // acquire
    let head = shmRingLoadCursor(region.advanced(by: offHead))
    if head == tail { return nil }
    let cap = shmRingCapacity(region)
    let c = shmRingConsume(region, head: head, capacity: cap)
    outLen.pointee = c.len
    return UnsafeRawPointer(shmRingDataBase(UnsafeMutableRawPointer(mutating: region)).advanced(by: Int(c.payloadPhys)))
}

/// Consumer: release the record returned by the most recent shmRingPeek,
/// advancing `head` with release ordering so the producer can reclaim the space.
/// No-op if the ring is empty.
func shmRingRelease(_ region: UnsafeMutableRawPointer) {
    let tail = shmRingLoadCursor(region.advanced(by: offTail))
    let head = shmRingLoadCursor(region.advanced(by: offHead))
    if head == tail { return }
    let cap = shmRingCapacity(region)
    let c = shmRingConsume(region, head: head, capacity: cap)
    shmRingStoreCursor(region.advanced(by: offHead), head &+ c.advance)
}
