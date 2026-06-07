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
// — which is all a single-process threading runtime needs. The compare-and-block
// is done with IRQs masked so the load of *uaddr and the state transition to
// "blocked, waiting on this addr" cannot race a concurrent FUTEX_WAKE on another
// (here: preempted) thread.

let futexWait = 0
let futexWake = 1

private let maxFutexWaiters = 16

// Parallel arrays: a waiter entry is (process slot, watched user VA).
private var futexSlot = [Int](repeating: -1, count: maxFutexWaiters)
private var futexAddr = [UInt](repeating: 0, count: maxFutexWaiters)

/// futex(uaddr, op, val). Returns 0 (WAIT woke / value mismatch) or the number
/// of threads woken (WAKE); negative on error.
func futexOp(uaddrVA: UInt, op: Int, val: UInt) -> Int {
    if op == futexWait {
        return futexWaitOn(uaddrVA, expected: UInt32(truncatingIfNeeded: val))
    }
    if op == futexWake {
        return futexWakeOn(uaddrVA, count: Int(bitPattern: val))
    }
    return -22 // EINVAL
}

private func futexWaitOn(_ uaddrVA: UInt, expected: UInt32) -> Int {
    // Validate the 4-byte user word lives in mapped, user-owned memory.
    guard let p = userReadableBuffer(uaddrVA, 4) else { return -22 }
    let word = UnsafeRawPointer(p)

    let daif = irq_save()
    // Compare under the IRQ mask: if it already differs, do not block (the wake
    // we would have waited for has effectively already happened).
    if word.load(as: UInt32.self) != expected {
        irq_restore(daif)
        return 0
    }
    // Record this thread as a waiter AND mark it blocked, all under the IRQ
    // mask. The mask is essential: it closes the lost-wakeup window between the
    // *uaddr compare and parking ourselves — a concurrent FUTEX_WAKE on a
    // preempted sibling can't run here, so it cannot mark us ready before we are
    // actually parked. processBlockOnFutex then switches away (the scheduler
    // runs masked) and returns once a later WAKE has marked us ready again.
    let slot = processCurrentSlot()
    if slot < 0 { irq_restore(daif); return -22 }
    var idx = -1
    for i in 0..<maxFutexWaiters where futexSlot[i] < 0 { idx = i; break }
    if idx < 0 { irq_restore(daif); return -11 } // EAGAIN: queue full
    futexSlot[idx] = slot
    futexAddr[idx] = uaddrVA
    processBlockOnFutex() // marks us blocked + yields; resumes when woken
    irq_restore(daif)
    return 0
}

private func futexWakeOn(_ uaddrVA: UInt, count: Int) -> Int {
    if count <= 0 { return 0 }
    let daif = irq_save()
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
    irq_restore(daif)
    return woken
}

/// Drop any futex wait records for a slot that is exiting, so a stale entry can
/// never wake (or be counted against) a reused slot.
func futexForgetSlot(_ slot: Int) {
    for i in 0..<maxFutexWaiters where futexSlot[i] == slot {
        futexSlot[i] = -1
        futexAddr[i] = 0
    }
}
