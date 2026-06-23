// SPDX-License-Identifier: Apache-2.0
// generic_timer.swift — ARM generic physical timer.

let physicalTimerIrq: UInt32 = 30

private var timerIntervalTicks: UInt64 = 0
private(set) var systemTicks: UInt64 = 0
// Scheduler tick rate (Hz); published so /bin/top can convert ticks ↔ seconds.
private(set) var timerHz: UInt32 = 0

func timerInit(ticksPerSecond: UInt64) {
    let frequency = read_cntfrq_el0()
    timerHz = UInt32(truncatingIfNeeded: ticksPerSecond)
    timerIntervalTicks = frequency / ticksPerSecond
    if timerIntervalTicks == 0 {
        timerIntervalTicks = 1
    }

    timerInitCurrentCpu()
}

func timerInitCurrentCpu() {
    if timerIntervalTicks == 0 {
        let frequency = read_cntfrq_el0()
        timerIntervalTicks = frequency / 100
        if timerIntervalTicks == 0 { timerIntervalTicks = 1 }
    }
    gicEnableInterrupt(physicalTimerIrq)
    timerScheduleNext()
}

func timerScheduleNext() {
    write_cntp_tval_el0(timerIntervalTicks)
    write_cntp_ctl_el0(1) // ENABLE=1, IMASK=0.
}

/// Current wall-clock time in seconds since the Unix epoch, read from the PL031
/// RTC data register (QEMU initializes it to the host time). Returns 0 when no
/// RTC base is known (e.g. the VirtualBox board), so callers degrade to "no
/// clock" rather than faulting.
func rtcNow() -> UInt64 {
    let base = platform.rtcBase
    if base == 0 { return 0 }
    return UInt64(mmio_read32(base))
}

func timerHandleTick() {
    systemTicks += 1
    smpRecordTimerTickForCurrentCpu()
    // Per-tick logging is silenced (it spammed the console once we run at a high
    // tick rate for preemption). systemTicks remains available for accounting.
    //
    // NOTE: do NOT drive netPump() from here. Pumping the NIC from the timer IRQ
    // passed every QEMU/TCG check but corrupted virtio-net on the real Ampere
    // Altra/KVM box (networking died: ping loss, sshd accept-loop). The net
    // stack is driven from socket syscalls only.

    // Rearm the timer. Rescheduling is driven from irqHandler AFTER the GIC EOI,
    // so a context switch never strands an active interrupt at the controller.
    timerScheduleNext()
}

/// Monotonic tick counter. Published for the logger (L0+) and for lightweight
/// in-kernel accounting (e.g. /bin/top). Safe to read from any EL1 context
/// once the timer has been initialised.
func timerGetTicks() -> UInt64 { systemTicks }
