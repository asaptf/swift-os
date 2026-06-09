// SPDX-License-Identifier: Apache-2.0
// secondary.swift - S0e checks for the parked secondary mailbox scaffold.

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
