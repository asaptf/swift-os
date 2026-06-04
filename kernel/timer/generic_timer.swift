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

func timerHandleTick() {
    systemTicks += 1

    uartPuts("tick ")
    uartPutUInt(systemTicks)
    uartPuts("\n")

    schedulerOnTick()
    timerScheduleNext()
}
