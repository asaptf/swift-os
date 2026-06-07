// threadsdemo.swift — native Swift `/bin/threadsdemo` for swift-os (rt-a demo).
//
// Spawns two EL0 threads that share this process's address space. Each thread
// increments a SHARED counter N times under a futex-based mutex; the main thread
// waits (also via a futex) for both to finish, then prints the final value,
// which must equal 2N. This exercises the rt-a kernel primitives end to end:
//   - thread_create (syscall 46): a sibling EL0 thread sharing TTBR0;
//   - futex (syscall 47): WAIT/WAKE used both for the lock and for the join.
//
// The lock is the classic 3-state futex mutex (Drepper, "Futexes Are Tricky"):
//   0 = unlocked, 1 = locked (no known waiters), 2 = locked (possible waiters).
// Atomic CAS/swap come from the C bridge (LL/SC the Swift layer can't express).

private let iterations: UInt = 2000

// All globals live in the single shared address space, so both threads and the
// main thread see the same words — that is the whole point of thread_create.
private var lockWord: UInt32 = 0   // futex mutex state (0/1/2)
private var counter: UInt = 0      // the shared counter we prove is race-free
private var doneCount: UInt32 = 0  // join futex: workers bump it to 2

// Fixed per-thread stacks (BSS, shared address space). 16-aligned; the kernel
// gets the TOP (stacks grow down). 32 KiB each is ample for this leaf work.
private let stackBytes = 32 * 1024
private var stack0 = [UInt8](repeating: 0, count: stackBytes)
private var stack1 = [UInt8](repeating: 0, count: stackBytes)

private func printUInt(_ v: UInt) {
    if v >= 10 { printUInt(v / 10) }
    swiftos_putc(UInt8(0x30 + (v % 10)))
}

// ---- futex mutex -----------------------------------------------------------

private func lockAcquire() {
    withUnsafeMutablePointer(to: &lockWord) { p in
        // Fast path: 0 -> 1 uncontended.
        var c = swiftos_atomic_cas(p, 0, 1)
        if c == 0 { return }
        // Contended: ensure the word reads 2 (locked, waiters) and sleep on it.
        repeat {
            if c == 2 || swiftos_atomic_cas(p, 1, 2) != 0 {
                _ = swiftos_futex(p, SWIFTOS_FUTEX_WAIT, 2)
            }
            c = swiftos_atomic_cas(p, 0, 2)
        } while c != 0
    }
}

private func lockRelease() {
    withUnsafeMutablePointer(to: &lockWord) { p in
        // If we were in state 2, there may be waiters to wake.
        if swiftos_atomic_swap(p, 0) == 2 {
            _ = swiftos_futex(p, SWIFTOS_FUTEX_WAKE, 1)
        }
    }
}

// ---- worker thread ---------------------------------------------------------

// One worker: bump the shared counter `iterations` times under the lock, then
// signal completion through the join futex. @convention(c) so its address is a
// plain function pointer we can hand to thread_create.
@_cdecl("threadsdemo_worker")
func worker(_ arg: UInt) {
    for _ in 0..<iterations {
        lockAcquire()
        counter += 1
        lockRelease()
    }
    // Join handoff: atomically record this worker as done and wake the waiter.
    withUnsafeMutablePointer(to: &doneCount) { p in
        _ = swiftos_atomic_add(p, 1)
        _ = swiftos_futex(p, SWIFTOS_FUTEX_WAKE, 1)
    }
    swiftos_thread_exit()
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp

    let entry = UInt(bitPattern: unsafeBitCast(worker as (@convention(c) (UInt) -> Void),
                                               to: UnsafeRawPointer.self))

    let top0 = stack0.withUnsafeMutableBytes { UInt(bitPattern: $0.baseAddress) + UInt($0.count) }
    let top1 = stack1.withUnsafeMutableBytes { UInt(bitPattern: $0.baseAddress) + UInt($0.count) }

    let t0 = swiftos_thread_create(entry, 0, top0 & ~UInt(15))
    let t1 = swiftos_thread_create(entry, 1, top1 & ~UInt(15))
    if t0 < 0 || t1 < 0 {
        swiftos_puts("threadsdemo: thread_create failed\n")
        return 1
    }

    // Join: wait until both workers have signalled completion.
    withUnsafeMutablePointer(to: &doneCount) { p in
        while true {
            let cur = swiftos_atomic_load(p)
            if cur >= 2 { break }
            // Block while doneCount is still `cur`; a worker's WAKE re-runs us.
            _ = swiftos_futex(p, SWIFTOS_FUTEX_WAIT, cur)
        }
    }

    swiftos_puts("threadsdemo: counter=")
    printUInt(counter)
    swiftos_putc(0x0A)
    return 0
}
