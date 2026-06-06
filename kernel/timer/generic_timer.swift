// generic_timer.swift — ARM generic physical timer.

let physicalTimerIrq: UInt32 = 30

private var timerIntervalTicks: UInt64 = 0
private(set) var systemTicks: UInt64 = 0

func timerInit(ticksPerSecond: UInt64) {
    let frequency = read_cntfrq_el0()
    timerIntervalTicks = frequency / ticksPerSecond
    if timerIntervalTicks == 0 {
        timerIntervalTicks = 1
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
    // Per-tick logging is silenced (it spammed the console once we run at a high
    // tick rate for preemption). systemTicks remains available for accounting.

    // Rearm the timer. Rescheduling is driven from irqHandler AFTER the GIC EOI,
    // so a context switch never strands an active interrupt at the controller.
    timerScheduleNext()
}
