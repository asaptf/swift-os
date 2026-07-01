// SPDX-License-Identifier: Apache-2.0
// futex.swift — minimal fast userspace mutex primitive (rt-a).
//
// A futex lets a userland threading runtime block and wake threads keyed by a
// user virtual address, without a syscall on the uncontended path. We implement
// the two operations a thread runtime needs to bootstrap a lock/condvar:
//
//   op = FUTEX_WAIT (0): if *uaddr == val, block the calling thread on uaddr
//                        until another thread wakes it. If *uaddr != val,
//                        return immediately (the value already changed).
//   op = FUTEX_WAKE (1): wake up to `val` threads waiting on uaddr; returns the
//                        number actually woken.
//
// The wait queue is keyed by the user VA. Because every thread of a process
// shares one address space (thread_create), a VA is a stable, process-local key
// — which is all a single-process threading runtime needs. S5e protects the
// table with a real spinlock so FUTEX_WAIT compare-and-block and FUTEX_WAKE can
// run from different scheduler CPUs without a lost wakeup.

let futexWait = 0
let futexWake = 1

// Sized to the visible process-slot count: at most one thread per slot can be
// parked in futex_wait at any instant, so the table can never legitimately
// overflow. PT3a grows this table whenever process slots grow.
private var maxFutexWaiters = kInitialProcessSlots

// Parallel arrays: a waiter entry is (process slot, watched user VA).
private var futexSlot: UnsafeMutablePointer<Int>! = nil
private var futexAddr: UnsafeMutablePointer<UInt>! = nil
private var futexLockWord: UInt64 = 0
private var futexLockAcquireCount: UInt64 = 0
private var futexLockContentionCount: UInt64 = 0

private func futexAtomicLoad(_ value: inout UInt64) -> UInt64 {
    withUnsafeMutablePointer(to: &value) { smpAtomicLoad($0) }
}

private func futexLock() -> UInt64 {
    let daif = irq_save()
    var contended = false
    while true {
        var expected: UInt64 = 0
        let acquired = withUnsafeMutablePointer(to: &futexLockWord) { word in
            smpAtomicCompareExchange(word, expected: &expected, desired: 1)
        }
        if acquired {
            if contended {
                withUnsafeMutablePointer(to: &futexLockContentionCount) { count in
                    _ = smpAtomicFetchAdd(count, 1)
                }
            }
            withUnsafeMutablePointer(to: &futexLockAcquireCount) { count in
                _ = smpAtomicFetchAdd(count, 1)
            }
            smpMemoryBarrier()
            return daif
        }
        contended = true
        smpLoadBarrier()
    }
}

private func futexUnlock(_ daif: UInt64) {
    smpMemoryBarrier()
    withUnsafeMutablePointer(to: &futexLockWord) { word in
        smpAtomicStore(word, 0)
    }
    irq_restore(daif)
}

private func futexGrowTable<T>(_ old: UnsafeMutablePointer<T>?,
                               oldCount: Int,
                               newCount: Int,
                               defaultValue: T) -> UnsafeMutablePointer<T>? {
    if newCount <= 0 { return nil }
    let bytes = MemoryLayout<T>.stride * newCount
    guard let raw = swiftos_kernel_alloc(UInt(bytes), 16) else { return nil }
    let next = raw.bindMemory(to: T.self, capacity: newCount)
    var i = 0
    if let oldTable = old {
        while i < oldCount {
            next[i] = oldTable[i]
            i += 1
        }
    }
    while i < newCount {
        next[i] = defaultValue
        i += 1
    }
    return next
}

func futexEnsureWaiterCapacity(_ requestedCapacity: Int) -> Bool {
    let daif = futexLock()
    defer { futexUnlock(daif) }

    if futexSlot != nil && requestedCapacity <= maxFutexWaiters { return true }
    let oldCapacity = futexSlot == nil ? 0 : maxFutexWaiters
    let newCapacity = requestedCapacity > maxFutexWaiters ? requestedCapacity : maxFutexWaiters
    guard let nextSlot = futexGrowTable(futexSlot,
                                        oldCount: oldCapacity,
                                        newCount: newCapacity,
                                        defaultValue: -1),
          let nextAddr = futexGrowTable(futexAddr,
                                        oldCount: oldCapacity,
                                        newCount: newCapacity,
                                        defaultValue: UInt(0)) else {
        return false
    }
    futexSlot = nextSlot
    futexAddr = nextAddr
    maxFutexWaiters = newCapacity
    return true
}

func futexS5eLockAcquireCount() -> UInt64 {
    futexAtomicLoad(&futexLockAcquireCount)
}

func futexS5eLockContentionCount() -> UInt64 {
    futexAtomicLoad(&futexLockContentionCount)
}

func futexS5eLockBoundaryHeldSelfTest() -> Bool {
    futexAtomicLoad(&futexLockWord) == 0 && futexS5eLockAcquireCount() != 0
}

func futexS5eWaitTableIdleSelfTest() -> Bool {
    if futexAtomicLoad(&futexLockWord) != 0 { return false }
    if futexSlot == nil || futexAddr == nil { return false }
    for i in 0..<maxFutexWaiters {
        if futexSlot[i] != -1 || futexAddr[i] != 0 { return false }
    }
    return true
}

/// futex(uaddr, op, val). Returns 0 (WAIT woke / value mismatch) or the number
/// of threads woken (WAKE); negative on error.
func futexOp(uaddrVA: UInt, op: Int, val: UInt) -> Int {
    if op == futexWait {
        return futexWaitOn(uaddrVA, expected: UInt32(truncatingIfNeeded: val))
    }
    if op == futexWake {
        return futexWakeOn(uaddrVA, count: Int(bitPattern: val))
    }
    return Errno.invalid.code // EINVAL
}

private func futexWaitOn(_ uaddrVA: UInt, expected: UInt32) -> Int {
    // Validate the 4-byte user word lives in mapped, user-owned memory.
    guard let p = userReadableBuffer(uaddrVA, 4) else { return Errno.invalid.code }
    let word = UnsafeRawPointer(p)

    let daif = futexLock()
    // Compare under the futex lock: if it already differs, do not block (the
    // wake we would have waited for has effectively already happened).
    if word.load(as: UInt32.self) != expected {
        futexUnlock(daif)
        return 0
    }
    // Record this thread as a waiter AND mark it blocked under the same lock.
    // Yield happens after unlock so wakeups on other CPUs can take the lock and
    // make this slot runnable.
    let slot = processCurrentSlot()
    if slot < 0 {
        futexUnlock(daif)
        return Errno.invalid.code
    }
    var idx = -1
    for i in 0..<maxFutexWaiters where futexSlot[i] < 0 { idx = i; break }
    if idx < 0 {
        futexUnlock(daif)
        return Errno.again.code // EAGAIN: queue full
    }
    futexSlot[idx] = slot
    futexAddr[idx] = uaddrVA
    if !processPrepareBlockOnFutex() {
        futexSlot[idx] = -1
        futexAddr[idx] = 0
        futexUnlock(daif)
        return Errno.invalid.code
    }
    futexUnlock(daif)
    processYieldAfterPreparedFutexBlock()
    return 0
}

private func futexWakeOn(_ uaddrVA: UInt, count: Int) -> Int {
    if count <= 0 { return 0 }
    let daif = futexLock()
    var woken = 0
    var i = 0
    while i < maxFutexWaiters && woken < count {
        if futexSlot[i] >= 0 && futexAddr[i] == uaddrVA {
            let slot = futexSlot[i]
            futexSlot[i] = -1
            futexAddr[i] = 0
            processWakeFromFutex(slot)
            woken += 1
        }
        i += 1
    }
    futexUnlock(daif)
    return woken
}

/// Drop any futex wait records for a slot that is exiting, so a stale entry can
/// never wake (or be counted against) a reused slot.
func futexForgetSlot(_ slot: Int) {
    let daif = futexLock()
    for i in 0..<maxFutexWaiters where futexSlot[i] == slot {
        futexSlot[i] = -1
        futexAddr[i] = 0
    }
    futexUnlock(daif)
}
