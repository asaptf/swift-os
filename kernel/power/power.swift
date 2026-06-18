// SPDX-License-Identifier: Apache-2.0
// power.swift — system power control: reboot, power-off, and panic auto-reboot.
//
// All paths funnel through PSCI (the same conduit S1 uses for CPU_ON), dispatched
// per the firmware-discovered method in `platform.psciMethod`. On QEMU `virt`
// PSCI is reached via HVC; SYSTEM_RESET reboots the machine and SYSTEM_OFF makes
// QEMU exit. Both PSCI functions only ever return on failure (a negative error
// in x0), so a return means the firmware refused and we surface it / halt.
//
// The panic auto-reboot is deliberately self-contained: it polls the architected
// counter (CNTPCT_EL0) instead of relying on the timer interrupt, because a
// kernel panic is taken with IRQs masked (DAIF set on exception entry) and the
// kernel may be in a broken state. Per the project's logging policy it does NOT
// touch the disk — a faulted kernel must not write to /data — it just records to
// the in-RAM klog ring + UART and resets.

// PSCI v0.2 function IDs (SMC32 calling convention; valid on AArch64 too).
private let psciSystemOff: UInt64 = 0x8400_0008
private let psciSystemReset: UInt64 = 0x8400_0009

// reboot(command) syscall selectors (must match userland/lib/syscall.h).
let powerCmdReset: UInt = 0   // PSCI SYSTEM_RESET — warm reboot
let powerCmdOff: UInt = 1     // PSCI SYSTEM_OFF   — power off / QEMU exit

/// Issue a PSCI call with no arguments via the firmware-discovered conduit.
/// Returns the PSCI status (negative on error); does not return on success.
@discardableResult
private func powerInvoke(_ functionId: UInt64) -> Int64 {
    if platform.psciMethod == platformPsciMethodHvc {
        return psci_call0_hvc(functionId)
    }
    if platform.psciMethod == platformPsciMethodSmc {
        return psci_call0_smc(functionId)
    }
    return -2 // PSCI_NOT_SUPPORTED: no conduit discovered.
}

/// Flush every writable filesystem to media, then reboot. Returns a negative
/// errno only if PSCI is unavailable or refuses the request (it does not return
/// on success — the machine resets).
@discardableResult
func powerReset() -> Int {
    klog(.warn, "power", "system reboot requested")
    _ = vfsSyncAll() // honest fsync of /data before the reset
    if platform.psciMethod == platformPsciMethodNone {
        klog(.error, "power", "no PSCI conduit; cannot reboot")
        return -38 // ENOSYS
    }
    klog(.warn, "power", "issuing PSCI SYSTEM_RESET")
    uartPuts("power: rebooting now\n")
    let rc = powerInvoke(psciSystemReset)
    klog(.error, "power", "PSCI SYSTEM_RESET refused", UInt64(bitPattern: rc))
    return -5 // EIO — only reached if the firmware refused
}

/// Flush filesystems and power the machine off (QEMU exits). Same return contract
/// as powerReset.
@discardableResult
func powerOff() -> Int {
    klog(.warn, "power", "system power-off requested")
    _ = vfsSyncAll()
    if platform.psciMethod == platformPsciMethodNone {
        klog(.error, "power", "no PSCI conduit; cannot power off")
        return -38 // ENOSYS
    }
    klog(.warn, "power", "issuing PSCI SYSTEM_OFF")
    uartPuts("power: powering off now\n")
    let rc = powerInvoke(psciSystemOff)
    klog(.error, "power", "PSCI SYSTEM_OFF refused", UInt64(bitPattern: rc))
    return -5 // EIO
}

/// Syscall backing (SYS_REBOOT, 90). Gated on capConsole — only the boot/admin
/// context may power-cycle the machine. `command` selects reset vs power-off.
func powerControl(command: UInt) -> Int {
    if (processCurrentCaps() & capConsole) == 0 { return -1 } // EPERM
    let pid = UInt64(truncatingIfNeeded: processCurrentPid())
    switch command {
    case powerCmdReset:
        klog(.warn, "power", "reboot via syscall", pid)
        return powerReset()
    case powerCmdOff:
        klog(.warn, "power", "poweroff via syscall", pid)
        return powerOff()
    default:
        return -22 // EINVAL
    }
}

/// Reboot triggered by Ctrl+Alt+Del on a hardware keyboard. Runs in IRQ context
/// (the keyboard is drained from the timer tick), so it relies on the polled
/// virtio-blk path inside vfsSyncAll being safe to call with IRQs masked.
func powerCtrlAltDelReboot() {
    klog(.warn, "power", "Ctrl+Alt+Del — rebooting")
    uartPuts("power: Ctrl+Alt+Del — rebooting\n")
    _ = powerReset()
}

/// Busy-wait `count` counter ticks using the architected counter. Safe with IRQs
/// masked (the panic path); no dependence on the timer interrupt.
private func busyWaitTicks(_ count: UInt64) {
    let start = read_cntpct_el0()
    while read_cntpct_el0() &- start < count {}
}

/// Panic auto-reboot: print a per-second countdown to the console, then reset.
/// Called from the EL1 fault handler so a wedged server recovers on its own.
/// Never returns (it resets, or halts if PSCI is unavailable).
func panicReboot(seconds: UInt64) -> Never {
    let frequency = read_cntfrq_el0()
    if frequency == 0 || platform.psciMethod == platformPsciMethodNone {
        // No timebase or no PSCI conduit: we cannot count down or reset. Halt.
        uartPuts("panic: auto-reboot unavailable (no PSCI/timebase); halting\n")
        klog(.panic, "power", "panic auto-reboot unavailable; halting")
        while true { wfi() }
    }

    klog(.panic, "power", "kernel panic — auto-reboot countdown", seconds)
    var remaining = seconds
    while remaining > 0 {
        uartPuts("panic: rebooting in ")
        uartPutUInt(remaining)
        uartPuts(" s\n")
        busyWaitTicks(frequency) // one second
        remaining -= 1
    }

    uartPuts("panic: countdown elapsed — resetting\n")
    klog(.panic, "power", "panic countdown elapsed — PSCI SYSTEM_RESET")
    _ = powerInvoke(psciSystemReset)
    // Reset only returns on failure; nothing left to do but halt.
    uartPuts("panic: PSCI SYSTEM_RESET returned; halting\n")
    while true { wfi() }
}
