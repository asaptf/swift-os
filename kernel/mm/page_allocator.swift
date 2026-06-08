// SPDX-License-Identifier: Apache-2.0
// page_allocator.swift — physical frame allocator (PMM).
//
// A bitmap allocator over a contiguous physical range, one bit per 4 KiB frame
// (0 = free, 1 = used). Pure logic: it operates on a caller-provided region and
// a caller-provided bitmap buffer, so the exact same code runs in the kernel
// (over real RAM) and in host unit tests (over a heap buffer).
//
// Linear first-fit with a rotating hint. O(n) worst case; fine for bring-up.
// A free-list / buddy refinement is future work (see docs/ARCHITECTURE.md).
//
// Copy-on-write fork needs per-frame sharing, so each frame can carry a
// reference count alongside its allocation bit. The count is a caller-provided
// UInt16 table (one entry per frame), wired exactly like the bitmap so this pure
// allocator still runs both in the kernel and in host tests. A fresh allocation
// starts at count 1; sharing bumps it; COW teardown drops it and only raw-frees
// the frame when the last reference is gone.

struct PageAllocator {
    static let pageSize: UInt = 4096

    let base: UInt                          // physical address of frame 0 (page-aligned)
    let pageCount: Int
    private let bitmap: UnsafeMutablePointer<UInt64>
    private let refs: UnsafeMutablePointer<UInt16>?
    private var hint: Int                   // where the next search starts
    private(set) var freePages: Int

    /// `bitmap` must point to at least `(pageCount + 63) / 64` words of storage.
    /// `refs`, when supplied, must point to at least `pageCount` UInt16 entries.
    init(base: UInt, pageCount: Int, bitmap: UnsafeMutablePointer<UInt64>,
         refs: UnsafeMutablePointer<UInt16>? = nil) {
        self.base = base
        self.pageCount = pageCount
        self.bitmap = bitmap
        self.refs = refs
        self.hint = 0
        self.freePages = pageCount
        let words = (pageCount + 63) / 64
        for i in 0..<words { bitmap[i] = 0 }
        if let refs = refs {
            for i in 0..<pageCount { refs[i] = 0 }
        }
    }

    @inline(__always) private func test(_ i: Int) -> Bool {
        (bitmap[i >> 6] >> UInt64(i & 63)) & 1 != 0
    }
    @inline(__always) private func set(_ i: Int) {
        bitmap[i >> 6] |= (UInt64(1) << UInt64(i & 63))
    }
    @inline(__always) private func clear(_ i: Int) {
        bitmap[i >> 6] &= ~(UInt64(1) << UInt64(i & 63))
    }

    @inline(__always) func address(ofFrame i: Int) -> UInt {
        base + UInt(i) * Self.pageSize
    }
    @inline(__always) func frame(ofAddress addr: UInt) -> Int {
        Int((addr - base) / Self.pageSize)
    }

    /// Allocate one frame. Returns its physical address, or nil if full.
    mutating func allocate() -> UInt? {
        if freePages == 0 { return nil }
        for step in 0..<pageCount {
            let i = (hint + step) % pageCount
            if !test(i) {
                set(i)
                refs?[i] = 1
                freePages -= 1
                hint = (i + 1) % pageCount
                return address(ofFrame: i)
            }
        }
        return nil
    }

    /// Allocate `count` physically contiguous frames. Returns the base address.
    mutating func allocateContiguous(_ count: Int) -> UInt? {
        if count <= 0 || count > freePages { return nil }
        var start = 0
        while start + count <= pageCount {
            var run = 0
            while run < count && !test(start + run) { run += 1 }
            if run == count {
                for k in 0..<count {
                    set(start + k)
                    refs?[start + k] = 1
                }
                freePages -= count
                hint = (start + count) % pageCount
                return address(ofFrame: start)
            }
            // Skip past the blocking used frame.
            start += run + 1
        }
        return nil
    }

    /// Free a single frame unconditionally. This is the raw reclaim primitive:
    /// shared user frames must first go through `unref()` and call this only on
    /// the last drop. Idempotent over invalid/already-free addresses.
    mutating func free(_ addr: UInt) {
        guard addr >= base && (addr - base) % Self.pageSize == 0 else { return }
        let i = frame(ofAddress: addr)
        guard i >= 0 && i < pageCount && test(i) else { return }
        clear(i)
        refs?[i] = 0
        freePages += 1
        if i < hint { hint = i }
    }

    /// Increment a frame's reference count because another owner now shares it.
    mutating func ref(_ addr: UInt) {
        guard let refs = refs else { return }
        guard addr >= base && (addr - base) % Self.pageSize == 0 else { return }
        let i = frame(ofAddress: addr)
        guard i >= 0 && i < pageCount && test(i) else { return }
        if refs[i] != UInt16.max { refs[i] += 1 }
    }

    /// Drop one reference. Returns true when the caller should raw-free the frame.
    /// The allocation bit is left set so a still-shared frame remains live.
    mutating func unref(_ addr: UInt) -> Bool {
        guard let refs = refs else { return true }
        guard addr >= base && (addr - base) % Self.pageSize == 0 else { return false }
        let i = frame(ofAddress: addr)
        guard i >= 0 && i < pageCount && test(i) else { return false }
        if refs[i] <= 1 {
            refs[i] = 0
            return true
        }
        refs[i] -= 1
        return false
    }

    /// Current reference count of a frame, or 0 for free/out-of-range/untracked.
    func refcount(_ addr: UInt) -> Int {
        guard let refs = refs else { return 0 }
        guard addr >= base && (addr - base) % Self.pageSize == 0 else { return 0 }
        let i = frame(ofAddress: addr)
        guard i >= 0 && i < pageCount && test(i) else { return 0 }
        return Int(refs[i])
    }

    /// Mark a sub-range [base, base + count*pageSize) as used (e.g. the bitmap
    /// itself, or the kernel heap arena). Idempotent over already-used frames.
    mutating func reserve(base resBase: UInt, count: Int) {
        guard resBase >= base && count > 0 else { return }
        let first = frame(ofAddress: resBase)
        for k in 0..<count {
            let i = first + k
            guard i >= 0 && i < pageCount else { continue }
            if !test(i) {
                set(i)
                refs?[i] = 1
                freePages -= 1
            }
        }
    }
}
