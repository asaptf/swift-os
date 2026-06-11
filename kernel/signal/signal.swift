// SPDX-License-Identifier: Apache-2.0
// signal.swift — minimal signal support for the foreground process.
//
// M7 scope: enough to make Ctrl-C interrupt a running command. Pending signals
// are tracked for the single foreground EL0 process; delivery happens at a safe
// point. The default action for an uncaught SIGINT is to terminate the process
// (exit status 128+signo), which is exactly "Ctrl-C interrupts the command".
// SIG_IGN is honored. NPM10 adds custom handler delivery on syscall return via
// a kernel-built user signal frame and sigreturn; asynchronous delivery while a
// process is blocked in EL1 remains a later slice.

let SIGINT: Int = 2
let SIGSEGV: Int = 11
let SIGPIPE: Int = 13
let SIGTERM: Int = 15
let SIGCHLD: Int = 17

let SIG_DFL: UInt = 0
let SIG_IGN: UInt = 1

private var pendingMask: UInt32 = 0
private var dispositions = [UInt](repeating: 0, count: 32) // index = signo; SIG_DFL
private var restorers = [UInt](repeating: 0, count: 32)     // userspace sigreturn trampoline

func signalIsValid(_ sig: Int) -> Bool {
    sig > 0 && sig < dispositions.count
}

func signalReset() {
    pendingMask = 0
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

/// True if any signal is pending for the foreground process.
func signalHasPending() -> Bool {
    return pendingMask != 0
}

/// Mark a signal pending for the foreground process (called from IRQ context).
func signalRaise(_ sig: Int) {
    guard signalIsValid(sig) else { return }
    pendingMask |= (UInt32(1) << UInt32(sig))
}

private func signalDeliverPending(_ sig: Int, _ frame: UnsafeMutablePointer<UInt>?) {
    let bit = UInt32(1) << UInt32(sig)
    if (pendingMask & bit) == 0 { return }
    let disp = dispositions[sig]
    if disp == SIG_IGN {
        pendingMask &= ~bit
        return
    }
    if disp != SIG_DFL {
        if let frame = frame, restorers[sig] != 0 {
            if processInstallSignalFrame(sig: sig, handler: disp, restorer: restorers[sig], frame: frame) {
                pendingMask &= ~bit
                return
            }
        }
        // No safe frame/restorer yet: keep the signal pending until a syscall
        // return can install the handler frame.
        return
    }
    pendingMask &= ~bit
    processTerminateBySignal(sig) // never returns
}

/// Deliver pending signals to the running foreground process. Must be called
/// with the foreground process on the CPU (e.g. from the IRQ handler after EOI).
func signalDeliverToForeground() {
    guard processIsActive() else {
        pendingMask = 0
        return
    }

    signalDeliverPending(SIGINT, nil)
    signalDeliverPending(SIGTERM, nil)
    signalDeliverPending(SIGPIPE, nil)
}

/// Deliver pending signals at a syscall-return safe point. Custom handlers are
/// installed by rewriting the trap frame to enter the registered handler at EL0.
func signalDeliverToCurrentFrame(_ frame: UnsafeMutablePointer<UInt>) {
    guard processIsActive() else {
        pendingMask = 0
        return
    }

    signalDeliverPending(SIGINT, frame)
    signalDeliverPending(SIGTERM, frame)
    signalDeliverPending(SIGPIPE, frame)
}
