// SPDX-License-Identifier: Apache-2.0
// signal.swift — minimal signal support for the foreground process.
//
// M7 scope: enough to make Ctrl-C interrupt a running command. Pending signals
// are tracked for the single foreground EL0 process; delivery happens at a safe
// point (from the IRQ handler, after the GIC EOI). The default action for an
// uncaught SIGINT is to terminate the process (exit status 128+signo), which is
// exactly "Ctrl-C interrupts the command". SIG_IGN is honored. Custom handler
// delivery (signal frames / sigreturn) is future work — see docs/NOTES.md.

let SIGINT: Int = 2
let SIGPIPE: Int = 13
let SIGTERM: Int = 15
let SIGCHLD: Int = 17

let SIG_DFL: UInt = 0
let SIG_IGN: UInt = 1

private var pendingMask: UInt32 = 0
private var dispositions = [UInt](repeating: 0, count: 32) // index = signo; SIG_DFL

func signalIsValid(_ sig: Int) -> Bool {
    sig > 0 && sig < dispositions.count
}

func signalReset() {
    pendingMask = 0
    for i in 0..<dispositions.count { dispositions[i] = SIG_DFL }
}

/// Record a disposition (SIG_DFL / SIG_IGN / handler address). Returns the old one.
@discardableResult
func signalSetDisposition(_ sig: Int, _ handler: UInt) -> UInt {
    guard signalIsValid(sig) else { return SIG_DFL }
    let old = dispositions[sig]
    dispositions[sig] = handler
    return old
}

func signalDisposition(_ sig: Int) -> UInt {
    guard signalIsValid(sig) else { return SIG_DFL }
    return dispositions[sig]
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

private func signalDeliverPending(_ sig: Int) {
    let bit = UInt32(1) << UInt32(sig)
    if (pendingMask & bit) == 0 { return }
    pendingMask &= ~bit
    let disp = dispositions[sig]
    if disp == SIG_IGN {
        return
    }
    // SIG_DFL (and, for now, any custom handler) terminates the process.
    processTerminateBySignal(sig) // never returns
}

/// Deliver pending signals to the running foreground process. Must be called
/// with the foreground process on the CPU (e.g. from the IRQ handler after EOI).
func signalDeliverToForeground() {
    guard processIsActive() else {
        pendingMask = 0
        return
    }

    signalDeliverPending(SIGINT)
    signalDeliverPending(SIGTERM)
    signalDeliverPending(SIGPIPE)
}
