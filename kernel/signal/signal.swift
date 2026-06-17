// SPDX-License-Identifier: Apache-2.0
// signal.swift — minimal per-process signal support.
//
// M7 scope: enough to make Ctrl-C interrupt a running command. The default
// action for an uncaught SIGINT is to terminate the process (exit status
// 128+signo); SIG_IGN is honored; NPM10 added custom handler delivery on
// syscall return via a kernel-built user signal frame and sigreturn.
//
// HC36 made *pending* signals per-process: a signal is now marked pending for a
// specific process slot (in process.swift's pPendingSignals) and delivered when
// that slot next returns to EL0. signalRaise() targets the running process (the
// console foreground, raised from the UART IRQ); signalRaiseSlot() targets an
// arbitrary slot (e.g. a PTY's foreground process, raised under the VFS lock).
// Dispositions/restorers remain process-global for now — correct while only one
// interactive process installs handlers at a time; per-process dispositions are
// recorded as future work in docs/NOTES.md. Asynchronous delivery while a
// process is blocked in EL1 still relies on the blocked syscall noticing a
// pending signal and returning (see the PTY read loops in vfs.swift).

let SIGINT: Int = 2
let SIGILL: Int = 4
let SIGTRAP: Int = 5
let SIGBUS: Int = 7
let SIGSEGV: Int = 11
let SIGPIPE: Int = 13
let SIGTERM: Int = 15
let SIGCHLD: Int = 17

let SIG_DFL: UInt = 0
let SIG_IGN: UInt = 1

private var dispositions = [UInt](repeating: 0, count: 32) // index = signo; SIG_DFL
private var restorers = [UInt](repeating: 0, count: 32)     // userspace sigreturn trampoline

func signalIsValid(_ sig: Int) -> Bool {
    sig > 0 && sig < dispositions.count
}

func signalReset() {
    for i in 0..<dispositions.count {
        dispositions[i] = SIG_DFL
        restorers[i] = 0
    }
}

/// Record a disposition (SIG_DFL / SIG_IGN / handler address). Returns the old one.
@discardableResult
func signalSetDisposition(_ sig: Int, _ handler: UInt, _ restorer: UInt = 0) -> UInt {
    guard signalIsValid(sig) else { return SIG_DFL }
    let old = dispositions[sig]
    dispositions[sig] = handler
    restorers[sig] = restorer
    return old
}

func signalDisposition(_ sig: Int) -> UInt {
    guard signalIsValid(sig) else { return SIG_DFL }
    return dispositions[sig]
}

func signalRestorer(_ sig: Int) -> UInt {
    guard signalIsValid(sig) else { return 0 }
    return restorers[sig]
}

/// True if any signal is pending for the running process.
func signalHasPending() -> Bool {
    let me = processCurrentSlot()
    return me >= 0 && processSignalHasPending(me)
}

/// True if a (deliverable) signal is pending for the running process. Blocked
/// syscalls (e.g. PTY reads) poll this to break out and let the syscall-return
/// path deliver the signal. Ignored signals are never marked pending, so any
/// pending bit here is deliverable.
func signalPendingForCurrent() -> Bool {
    signalHasPending()
}

/// Mark `sig` pending for `slot`, unless it is ignored. The signal is delivered
/// when that slot next returns to EL0.
func signalRaiseSlot(_ slot: Int, _ sig: Int) {
    guard signalIsValid(sig) else { return }
    if dispositions[sig] == SIG_IGN { return }
    processSignalMarkPending(slot, sig)
}

/// Mark a signal pending for the running process (e.g. console Ctrl-C from the
/// UART IRQ, where the foreground reader is the current process).
func signalRaise(_ sig: Int) {
    let me = processCurrentSlot()
    if me < 0 { return }
    signalRaiseSlot(me, sig)
}

private func signalDeliverPending(_ sig: Int, _ frame: UnsafeMutablePointer<UInt>?) {
    let me = processCurrentSlot()
    if me < 0 { return }
    if !processSignalIsPending(me, sig) { return }
    let disp = dispositions[sig]
    if disp == SIG_IGN {
        processSignalClearPending(me, sig)
        return
    }
    if disp != SIG_DFL {
        if let frame = frame, restorers[sig] != 0 {
            if processInstallSignalFrame(sig: sig, handler: disp, restorer: restorers[sig], frame: frame) {
                processSignalClearPending(me, sig)
                return
            }
        }
        // No safe frame/restorer yet: keep the signal pending until a syscall
        // return can install the handler frame.
        return
    }
    processSignalClearPending(me, sig)
    processTerminateBySignal(sig) // never returns
}

/// Deliver pending signals to the running process. Must be called with that
/// process on the CPU (e.g. from the IRQ handler after EOI). No frame is
/// available here, so custom handlers stay pending until the next syscall return.
func signalDeliverToForeground() {
    guard processIsActive() else { return }

    signalDeliverPending(SIGINT, nil)
    signalDeliverPending(SIGTERM, nil)
    signalDeliverPending(SIGPIPE, nil)
}

/// Deliver pending signals at a syscall-return safe point. Custom handlers are
/// installed by rewriting the trap frame to enter the registered handler at EL0.
func signalDeliverToCurrentFrame(_ frame: UnsafeMutablePointer<UInt>) {
    guard processIsActive() else { return }

    signalDeliverPending(SIGINT, frame)
    signalDeliverPending(SIGTERM, frame)
    signalDeliverPending(SIGPIPE, frame)
}
