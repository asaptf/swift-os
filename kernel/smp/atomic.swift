// SPDX-License-Identifier: Apache-2.0
// atomic.swift — minimal SMP barrier/atomic shims (S0b).
//
// These are tiny Swift names over C bridge inlines in io.h. They intentionally
// expose only the operations needed by the first SMP hardening passes; PMM,
// VFS refcounts, and scheduler state can grow this vocabulary when they adopt it.

@inline(__always)
func smpMemoryBarrier() {
    smp_dmb_ish()
}

@inline(__always)
func smpLoadBarrier() {
    smp_dmb_ishld()
}

@inline(__always)
func smpStoreBarrier() {
    smp_dmb_ishst()
}

@inline(__always)
func smpAtomicLoad(_ p: UnsafeMutablePointer<UInt64>) -> UInt64 {
    smp_atomic_load_u64(p)
}

@inline(__always)
func smpAtomicStore(_ p: UnsafeMutablePointer<UInt64>, _ value: UInt64) {
    smp_atomic_store_u64(p, value)
}

@inline(__always)
func smpAtomicFetchAdd(_ p: UnsafeMutablePointer<UInt64>, _ value: UInt64) -> UInt64 {
    smp_atomic_fetch_add_u64(p, value)
}

@inline(__always)
func smpAtomicCompareExchange(_ p: UnsafeMutablePointer<UInt64>,
                              expected: inout UInt64,
                              desired: UInt64) -> Bool {
    smp_atomic_compare_exchange_u64(p, &expected, desired)
}

func smpAtomicSelfTest() -> Bool {
    var wordStorage: UInt64 = 0

    return withUnsafeMutablePointer(to: &wordStorage) { word in
        smpAtomicStore(word, 1)
        smpStoreBarrier()
        smpLoadBarrier()
        if smpAtomicLoad(word) != 1 { return false }

        let old = smpAtomicFetchAdd(word, 4)
        if old != 1 || smpAtomicLoad(word) != 5 { return false }

        var expected: UInt64 = 5
        if !smpAtomicCompareExchange(word, expected: &expected, desired: 9) { return false }
        if expected != 5 || smpAtomicLoad(word) != 9 { return false }

        expected = 5
        if smpAtomicCompareExchange(word, expected: &expected, desired: 11) { return false }
        if expected != 9 || smpAtomicLoad(word) != 9 { return false }

        smpMemoryBarrier()
        return true
    }
}
