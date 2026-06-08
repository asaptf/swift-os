// SPDX-License-Identifier: Apache-2.0
// scheduler.swift — real kernel-thread scheduler.
//
// Each thread has its own kernel stack (from the PMM) and a saved CPU context.
// Switching goes through cpu_switch_context (switch.S), which saves/restores
// callee-saved registers + sp + lr — so threads resume exactly where they left
// off, on their own stacks. This is a genuine context switch, not a model.
//
// Concurrency: the scheduler runs single-core with IRQs masked during a switch.
// - Preemption: the timer IRQ (IRQ already masked by hardware) calls schedule().
// - Cooperative: schedYield() masks IRQs around schedule().
// - Thread 0 is the bootstrap/idle context (kernel_main); it owns no crafted
//   stack — its context is captured on the first switch away from it.
//
// Re-enabling IRQs after a switch is implicit: preempted threads resume through
// the IRQ vector's `eret` (which restores PSTATE.I), and first-run threads
// unmask IRQs in thread_trampoline.

/// Saved callee-saved register file. Field order/size must match switch.S.
/// All fields are UInt64, so Swift preserves declaration order in memory.
struct CPUContext {
    var x19: UInt64 = 0
    var x20: UInt64 = 0
    var x21: UInt64 = 0
    var x22: UInt64 = 0
    var x23: UInt64 = 0
    var x24: UInt64 = 0
    var x25: UInt64 = 0
    var x26: UInt64 = 0
    var x27: UInt64 = 0
    var x28: UInt64 = 0
    var fp: UInt64 = 0
    var lr: UInt64 = 0
    var sp: UInt64 = 0
}

// Thread states.
private let stateFree: Int32 = 0
private let stateReady: Int32 = 1
private let stateRunning: Int32 = 2
private let stateDone: Int32 = 3

private let maxThreads = 4

// Contexts live in a stable, never-moved allocation so switch.S can hold raw
// pointers into them across switches.
private var contexts: UnsafeMutablePointer<CPUContext>! = nil
private var states = [Int32](repeating: stateFree, count: maxThreads)
private var stackBases = [UInt](repeating: 0, count: maxThreads)

private var currentThread = 0
private var threadCount = 0
private var schedulerReady = false

func schedulerInit() {
    let bytes = UInt(MemoryLayout<CPUContext>.stride * maxThreads)
    guard let raw = swiftos_kernel_alloc(bytes, 16) else {
        uartPuts("panic: scheduler context allocation failed\n")
        while true {}
    }
    contexts = raw.bindMemory(to: CPUContext.self, capacity: maxThreads)
    for i in 0..<maxThreads {
        contexts[i] = CPUContext()
        states[i] = stateFree
        stackBases[i] = 0
    }

    // Thread 0 = the current kernel_main / idle context.
    states[0] = stateRunning
    currentThread = 0
    threadCount = 1
    schedulerReady = true
    // L3 adoption: keep the old boot marker text, with maxThreads as detail.
    klog(.info, "sched", "M4.5 sched: scheduler online", UInt64(maxThreads))
}

/// Create a ready kernel thread that runs `entry(arg)`. Returns its id, or -1.
func threadCreate(_ entry: @convention(c) (UInt) -> Void, _ arg: UInt) -> Int {
    if threadCount >= maxThreads { return -1 }
    let slot = threadCount

    let stackPages = 2
    let stack = pmmAllocPages(stackPages)
    if stack == 0 { return -1 }
    let stackTop = stack + UInt(stackPages) * PageAllocator.pageSize

    var ctx = CPUContext()
    ctx.x19 = UInt64(unsafeBitCast(entry, to: UInt.self)) // entry function
    ctx.x20 = UInt64(arg)                                 // its argument
    ctx.lr = UInt64(thread_trampoline_addr())             // first-run lands here
    ctx.sp = UInt64(stackTop)
    contexts[slot] = ctx

    stackBases[slot] = stack
    states[slot] = stateReady
    threadCount += 1
    return slot
}

/// Pick the next runnable thread and switch to it. Assumes IRQs are masked.
private func schedule() {
    if !schedulerReady { return }
    let prev = currentThread

    // Prefer a ready/running non-idle thread, round-robin after `prev`.
    var next = -1
    for step in 1...maxThreads {
        let cand = (prev + step) % maxThreads
        if cand == 0 { continue }
        if states[cand] == stateReady || states[cand] == stateRunning {
            next = cand
            break
        }
    }
    // Fall back to the idle thread only if nothing else can run.
    if next == -1 && prev != 0 && states[0] != stateFree && states[0] != stateDone {
        next = 0
    }
    if next == -1 || next == prev { return }

    if states[prev] == stateRunning { states[prev] = stateReady }
    states[next] = stateRunning
    currentThread = next

    let base = UnsafeMutableRawPointer(contexts!)
    let stride = MemoryLayout<CPUContext>.stride
    cpu_switch_context(base.advanced(by: prev * stride),
                       base.advanced(by: next * stride))
}

/// Cooperatively yield the CPU to another runnable thread.
func schedYield() {
    if !schedulerReady { return }
    disable_irq()
    schedule()
    enable_irq()
}

/// Called from the timer IRQ (IRQs already masked) to drive preemption.
func schedulerTick() {
    schedule()
}

/// Thread entry returned: mark done and switch away for good.
@_cdecl("thread_exit")
func threadExit() {
    disable_irq()
    states[currentThread] = stateDone
    schedule()
    // The switch never returns to a done thread.
    while true { wfi() }
}

/// True once every spawned (non-idle) thread has finished.
func schedAllThreadsDone() -> Bool {
    for i in 1..<maxThreads where states[i] != stateFree {
        if states[i] != stateDone { return false }
    }
    return true
}
