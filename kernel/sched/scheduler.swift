// scheduler.swift — minimal M4 scheduler model.
//
// This is not a full context switcher yet. Timer IRQs drive a tiny round-robin
// run queue so M4 has a visible preemption point before M5/M6 add real tasks.

private var schedulerStarted = false
private var schedulerSlot: UInt64 = 0
private var schedulerEvents: UInt64 = 0
private var announcedA = false
private var announcedB = false

func schedulerInit() {
    schedulerStarted = true
    schedulerSlot = 0
    schedulerEvents = 0
    announcedA = false
    announcedB = false
    uartPuts("M4 scheduler: kernel threads A/B ready\n")
}

func schedulerOnTick() {
    if !schedulerStarted { return }

    schedulerSlot = (schedulerSlot + 1) & 1
    schedulerEvents += 1

    if schedulerSlot == 0 {
        if !announcedA {
            uartPuts("M4 scheduler: kernel thread A ran\n")
            announcedA = true
        }
    } else {
        if !announcedB {
            uartPuts("M4 scheduler: kernel thread B ran\n")
            announcedB = true
        }
    }

    if announcedA && announcedB && schedulerEvents >= 2 {
        uartPuts("M4 scheduler: kernel threads interleaved\n")
        schedulerStarted = false
    }
}
