// SPDX-License-Identifier: Apache-2.0
//
// llama_matmul_pool.swift — LM2 multi-threaded matmul across SMP cores.
//
// Linked only into EL0 inference binaries (/bin/llm, /bin/llmd), not host unit
// tests. Installs parallel dispatch hooks on top of the pure row kernels in
// llama2.swift. Design constraints (docs/NOTES.md LM2):
//   - no closures across threads (C entry + fixed job fields);
//   - no per-matmul allocation (mmap stacks once + fixed job fields);
//   - serial path on host / single-core remains the llama2.swift default;
//   - row kernels keep LM1's explicit SIMD (llamaFDot / llamaQDotGroup).
//
// Worker model: long-lived EL0 threads sleep on a futex. Each matmul publishes
// a contiguous job, splits output rows into equal chunks (one per worker,
// including the calling thread as worker 0), wakes siblings, runs its own
// chunk, then joins. Only one matmul runs at a time (the forward pass is
// single-caller).

private let matmulPoolMaxWorkers = 8
private let matmulPoolStackBytes = 64 * 1024

// ---- job buffers (shared address space; one active matmul) -----------------

private var poolWorkerCount: Int = 0
private var poolStarted = false

private var jobKind: Int32 = 0   // 0 = f32, 1 = q8
private var jobN: Int32 = 0
private var jobD: Int32 = 0
private var jobGS: Int32 = 0
private var jobXout: UnsafeMutablePointer<Float>?
private var jobXinF: UnsafePointer<Float>?
private var jobWtF: UnsafePointer<Float>?
private var jobXq: UnsafePointer<Int8>?
private var jobXs: UnsafePointer<Float>?
private var jobWq: UnsafePointer<Int8>?
private var jobWs: UnsafePointer<Float>?

// Fixed per-worker row ranges — NOT a Swift Array (Array storage is not safe
// for concurrent multi-thread reads under Embedded Swift COW/refcounting).
private var jobRS0 = 0, jobRS1 = 0, jobRS2 = 0, jobRS3 = 0
private var jobRS4 = 0, jobRS5 = 0, jobRS6 = 0, jobRS7 = 0
private var jobRE0 = 0, jobRE1 = 0, jobRE2 = 0, jobRE3 = 0
private var jobRE4 = 0, jobRE5 = 0, jobRE6 = 0, jobRE7 = 0

private func setJobRange(_ w: Int, _ start: Int, _ end: Int) {
    switch w {
    case 0: jobRS0 = start; jobRE0 = end
    case 1: jobRS1 = start; jobRE1 = end
    case 2: jobRS2 = start; jobRE2 = end
    case 3: jobRS3 = start; jobRE3 = end
    case 4: jobRS4 = start; jobRE4 = end
    case 5: jobRS5 = start; jobRE5 = end
    case 6: jobRS6 = start; jobRE6 = end
    default: jobRS7 = start; jobRE7 = end
    }
}

private func jobRange(_ w: Int) -> (Int, Int) {
    switch w {
    case 0: return (jobRS0, jobRE0)
    case 1: return (jobRS1, jobRE1)
    case 2: return (jobRS2, jobRE2)
    case 3: return (jobRS3, jobRE3)
    case 4: return (jobRS4, jobRE4)
    case 5: return (jobRS5, jobRE5)
    case 6: return (jobRS6, jobRE6)
    default: return (jobRS7, jobRE7)
    }
}

// Futex handshake: phase 0 = idle, 1 = job ready. doneCount counts finished
// sibling workers (not including the calling thread).
private var jobPhase: UInt32 = 0
private var jobDone: UInt32 = 0

// Per-sibling stack base VAs from anonymous mmap (worker 0 = calling thread).
private var poolStackBase0: UInt = 0
private var poolStackBase1: UInt = 0
private var poolStackBase2: UInt = 0
private var poolStackBase3: UInt = 0
private var poolStackBase4: UInt = 0
private var poolStackBase5: UInt = 0
private var poolStackBase6: UInt = 0

private func setStackBase(_ worker: Int, _ base: UInt) {
    switch worker {
    case 1: poolStackBase0 = base
    case 2: poolStackBase1 = base
    case 3: poolStackBase2 = base
    case 4: poolStackBase3 = base
    case 5: poolStackBase4 = base
    case 6: poolStackBase5 = base
    default: poolStackBase6 = base
    }
}

private func stackTopFor(_ worker: Int) -> UInt {
    let base: UInt
    switch worker {
    case 1: base = poolStackBase0
    case 2: base = poolStackBase1
    case 3: base = poolStackBase2
    case 4: base = poolStackBase3
    case 5: base = poolStackBase4
    case 6: base = poolStackBase5
    default: base = poolStackBase6
    }
    if base == 0 { return 0 }
    return (base + UInt(matmulPoolStackBytes)) & ~UInt(15)
}

// ---- helpers ---------------------------------------------------------------

private func poolPutUInt(_ v: UInt) {
    if v >= 10 { poolPutUInt(v / 10) }
    swiftos_putc(UInt8(0x30 + (v % 10)))
}

private func runJobChunk(_ worker: Int) {
    let (start, end) = jobRange(worker)
    if start >= end { return }
    if jobKind == 0 {
        guard let xout = jobXout, let xin = jobXinF, let wt = jobWtF else { return }
        llamaMatmulF32Rows(xout, xin, wt, Int(jobN), start, end)
    } else {
        guard let xout = jobXout, let xq = jobXq, let xs = jobXs,
              let wq = jobWq, let ws = jobWs else { return }
        llamaQMatmulRows(xout, xq, xs, wq, ws, Int(jobN), Int(jobGS), start, end)
    }
}

@_cdecl("llama_matmul_pool_worker")
func llamaMatmulPoolWorker(_ arg: UInt) {
    let worker = Int(arg)   // 1..<poolWorkerCount
    // Single withUnsafe scope for the whole lifetime — avoid nested closures
    // that bloat the stack under Embedded Swift.
    withUnsafeMutablePointer(to: &jobPhase) { phase in
        withUnsafeMutablePointer(to: &jobDone) { done in
            while true {
                while swiftos_atomic_load(phase) != 1 {
                    _ = swiftos_futex(phase, SWIFTOS_FUTEX_WAIT, 0)
                }
                runJobChunk(worker)
                _ = swiftos_atomic_add(done, 1)
                _ = swiftos_futex(done, SWIFTOS_FUTEX_WAKE, 1)
                while swiftos_atomic_load(phase) != 0 {
                    _ = swiftos_futex(phase, SWIFTOS_FUTEX_WAIT, 1)
                }
            }
        }
    }
    // Unreachable: infinite loop above. Keep the exit for the type checker.
    // swiftos_thread_exit()
}

private func publishAndRun(workers: Int) {
    let d = Int(jobD)
    let chunk = (d + workers - 1) / workers
    var w = 0
    while w < workers {
        let start = w * chunk
        var end = start + chunk
        if end > d { end = d }
        if start > d {
            setJobRange(w, d, d)
        } else {
            setJobRange(w, start, end)
        }
        w += 1
    }

    withUnsafeMutablePointer(to: &jobDone) { done in
        _ = swiftos_atomic_swap(done, 0)
    }
    withUnsafeMutablePointer(to: &jobPhase) { phase in
        _ = swiftos_atomic_swap(phase, 1)
        _ = swiftos_futex(phase, SWIFTOS_FUTEX_WAKE, UInt32(workers))
    }

    runJobChunk(0)

    let need = UInt32(workers - 1)
    withUnsafeMutablePointer(to: &jobDone) { done in
        while true {
            let cur = swiftos_atomic_load(done)
            if cur >= need { break }
            _ = swiftos_futex(done, SWIFTOS_FUTEX_WAIT, cur)
        }
    }

    withUnsafeMutablePointer(to: &jobPhase) { phase in
        _ = swiftos_atomic_swap(phase, 0)
        _ = swiftos_futex(phase, SWIFTOS_FUTEX_WAKE, UInt32(workers))
    }
}

@_cdecl("llama_matmul_f32_parallel")
func llamaMatmulF32Parallel(_ xout: UnsafeMutablePointer<Float>,
                            _ xin: UnsafePointer<Float>,
                            _ wt: UnsafePointer<Float>,
                            _ n: Int32, _ d: Int32) {
    if !poolStarted || poolWorkerCount <= 1 || d <= 1 {
        llamaMatmulF32Rows(xout, xin, wt, Int(n), 0, Int(d))
        return
    }
    jobKind = 0
    jobN = n
    jobD = d
    jobXout = xout
    jobXinF = xin
    jobWtF = wt
    publishAndRun(workers: poolWorkerCount)
}

@_cdecl("llama_qmatmul_parallel")
func llamaQMatmulParallel(_ xout: UnsafeMutablePointer<Float>,
                          _ xq: UnsafePointer<Int8>, _ xs: UnsafePointer<Float>,
                          _ wq: UnsafePointer<Int8>, _ ws: UnsafePointer<Float>,
                          _ n: Int32, _ d: Int32, _ gs: Int32) {
    if !poolStarted || poolWorkerCount <= 1 || d <= 1 {
        llamaQMatmulRows(xout, xq, xs, wq, ws, Int(n), Int(gs), 0, Int(d))
        return
    }
    jobKind = 1
    jobN = n
    jobD = d
    jobGS = gs
    jobXout = xout
    jobXq = xq
    jobXs = xs
    jobWq = wq
    jobWs = ws
    publishAndRun(workers: poolWorkerCount)
}

/// Start a long-lived matmul worker pool sized for the machine and install the
/// parallel dispatch hooks. Safe to call once; subsequent calls are no-ops.
@discardableResult
func llamaMatmulPoolStart(requested: Int) -> Int {
    if poolStarted { return poolWorkerCount }

    var n = requested
    if n < 1 { n = 1 }
    if n > matmulPoolMaxWorkers { n = matmulPoolMaxWorkers }

    // Do not clamp to sysinfo alone: under some boot paths cpu_count lags the
    // online secondary set. Try starting `n` workers; thread_create / mmap
    // failures shrink the live pool.
    if n > matmulPoolMaxWorkers { n = matmulPoolMaxWorkers }

    poolWorkerCount = n
    if n <= 1 {
        poolStarted = true
        llamaMatmulF32Dispatch = nil
        llamaQMatmulDispatch = nil
        swiftos_puts("LM2: matmul pool workers=1 (serial)\n")
        return 1
    }

    let entry = UInt(bitPattern: unsafeBitCast(
        llamaMatmulPoolWorker as (@convention(c) (UInt) -> Void),
        to: UnsafeRawPointer.self))

    var w = 1
    while w < n {
        let base = swiftos_mmap(UInt(matmulPoolStackBytes),
                                Int32(SWIFTOS_PROT_READ | SWIFTOS_PROT_WRITE))
        if base == 0 {
            poolWorkerCount = w
            break
        }
        setStackBase(w, base)
        let top = stackTopFor(w)
        let tid = swiftos_thread_create(entry, UInt(w), top)
        if tid < 0 {
            poolWorkerCount = w
            break
        }
        w += 1
    }

    poolStarted = true
    if poolWorkerCount > 1 {
        llamaMatmulF32Dispatch = llamaMatmulF32Parallel
        llamaQMatmulDispatch = llamaQMatmulParallel
    }
    swiftos_puts("LM2: matmul pool workers=")
    poolPutUInt(UInt(poolWorkerCount))
    swiftos_puts("\n")
    return poolWorkerCount
}
