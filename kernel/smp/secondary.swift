// SPDX-License-Identifier: Apache-2.0
// secondary.swift - S1 secondary CPU release and early-online checks.

func smpSecondaryParkSelfTest() -> Bool {
    if smp_secondary_mailbox_count() != UInt64(smpMaxCpuCount()) { return false }
    if smp_secondary_mailbox_stride() != 64 { return false }
    if (smp_secondary_mailbox_base() & 0x3F) != 0 { return false }

    var cpu: UInt32 = 0
    while cpu < smpMaxCpuCount() {
        if smp_secondary_release_flag_load(cpu) != 0 { return false }
        if smp_secondary_release_entry_load(cpu) != 0 { return false }
        if smp_secondary_release_stack_load(cpu) != 0 { return false }
        if smp_secondary_release_argument_load(cpu) != 0 { return false }
        cpu += 1
    }

    if smp_secondary_release_flag_load(smpMaxCpuCount()) != UInt64.max { return false }
    smpLoadBarrier()
    return true
}

private func smpPsciCpuOn(_ targetCpu: UInt32, entry: UInt, context: UInt) -> Int64 {
    let fn = UInt64(platform.psciCpuOn)
    let target = UInt64(targetCpu)
    let ep = UInt64(entry)
    let ctx = UInt64(context)
    if platform.psciMethod == platformPsciMethodHvc {
        return psci_cpu_on_hvc(fn, target, ep, ctx)
    }
    if platform.psciMethod == platformPsciMethodSmc {
        return psci_cpu_on_smc(fn, target, ep, ctx)
    }
    return -1
}

private func smpReleaseSecondary(_ cpu: UInt32, entry: UInt) -> Bool {
    let stack = UInt(smp_secondary_stack_top(cpu))
    if stack == 0 { return false }
    if (stack & 0xF) != 0 { return false }

    smp_secondary_prepare_release(cpu, entry, stack, UInt(cpu))
    cpu_sev()

    _ = smpPsciCpuOn(cpu, entry: entry, context: UInt(cpu))
    cpu_sev()

    // QEMU direct `-kernel` paths may already have a secondary parked in our
    // mailbox loop. In all cases, the acceptance signal is the observed
    // online+heartbeat state, not the immediate firmware return value.
    return true
}

private func smpAllDiscoveredCpusReady() -> Bool {
    var i: UInt32 = 0
    while i < platform.cpuCount {
        let cpu = platformCpuAff0(i)
        if cpu >= smpMaxCpuCount() { return false }
        if !smpCpuInitialized(cpu) { return false }
        if !smpCpuOnline(cpu) { return false }
        if smpPerCpuTimerTicks(cpu) == 0 { return false }
        i += 1
    }
    return true
}

private func smpSecondariesRemainSchedulerIdle() -> Bool {
    var i: UInt32 = 1
    while i < platform.cpuCount {
        let cpu = platformCpuAff0(i)
        if cpu >= smpMaxCpuCount() { return false }
        if !smpPerCpuSchedulerIdle(cpu) { return false }
        i += 1
    }
    return true
}

private func smpLogS2ReadinessMarkers() {
    var i: UInt32 = 0
    while i < platform.cpuCount {
        let cpu = platformCpuAff0(i)
        // Detail is CPU id + 1 so CPU0 still has an explicit nonzero payload.
        klog(.info, "smp", "S2a OK: per-CPU timer heartbeat ready", UInt64(cpu) + 1)
        i += 1
    }
    klog(.info, "smp", "S2a OK: scheduler boundary held", UInt64(platform.cpuCount))
}

func smpS2ReadinessSelfTest() -> Bool {
    let primary = currentCpuId()
    if primary >= smpMaxCpuCount() { return false }
    if !smpCpuOnline(primary) { return false }
    if !smpPerCpuHasCurrentThread(primary) { return false }
    if !smpPerCpuProcessIdle(primary) { return false }

    var i: UInt32 = 0
    while i < platform.cpuCount {
        let cpu = platformCpuAff0(i)
        if cpu >= smpMaxCpuCount() { return false }
        if cpu != primary && !smpPerCpuSchedulerIdle(cpu) { return false }
        i += 1
    }
    return true
}

func smpBringupSecondaries() -> Bool {
    if platform.cpuCount == 0 { return false }
    if platform.cpuCount > smpMaxCpuCount() { return false }

    smpRecordTimerTickForCurrentCpu()
    smpMarkCurrentCpuOnline()

    if platform.cpuCount > 1 {
        if platform.psciCpuOn == 0 { return false }
        if platform.psciMethod != platformPsciMethodHvc &&
           platform.psciMethod != platformPsciMethodSmc {
            return false
        }

        let entry = UInt(smp_secondary_entry_addr())
        if entry == 0 { return false }

        var i: UInt32 = 1
        while i < platform.cpuCount {
            let cpu = platformCpuAff0(i)
            if cpu >= smpMaxCpuCount() { return false }
            if !platformCpuUsesPsci(i) { return false }
            if !smpReleaseSecondary(cpu, entry: entry) { return false }
            i += 1
        }
    }

    let start = read_cntpct_el0()
    var timeout = read_cntfrq_el0() * 2
    if timeout == 0 { timeout = 100_000_000 }
    while read_cntpct_el0() &- start < timeout {
        if smpAllDiscoveredCpusReady() {
            if !smpSecondariesRemainSchedulerIdle() { return false }
            smpLogS2ReadinessMarkers()
            var i: UInt32 = 0
            while i < platform.cpuCount {
                klog(.info, "smp", "S1 CPU online", UInt64(platformCpuAff0(i)))
                i += 1
            }
            klog(.info, "smp", "S1 OK: secondary CPUs online", UInt64(platform.cpuCount))
            return true
        }
    }

    return false
}

@_cdecl("smp_secondary_main")
func smpSecondaryMain(_ _: UInt) {
    disable_irq()
    if !smpEarlyInitCurrentCpu() {
        while true { wfi() }
    }
    gicInitCpuInterfaceForCurrentCpu()
    timerInitCurrentCpu()
    smpMarkCurrentCpuOnline()

    let cpu = currentCpuId()
    let startTicks = smpPerCpuTimerTicks(cpu)
    let startCounter = read_cntpct_el0()
    var timeout = read_cntfrq_el0() * 2
    if timeout == 0 { timeout = 100_000_000 }

    enable_irq()
    while smpPerCpuTimerTicks(cpu) < startTicks + 4 &&
          read_cntpct_el0() &- startCounter < timeout {
        wfi()
    }
    disable_irq()
    while true { wfi() }
}
