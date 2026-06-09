// SPDX-License-Identifier: Apache-2.0
// topology.swift - DTB-discovered CPU topology checks for S0f.

func smpTopologySelfTest() -> Bool {
    if platform.cpuCount == 0 { return false }
    if platform.cpuCount > smpMaxCpuCount() { return false }

    var i: UInt32 = 0
    while i < platform.cpuCount {
        let aff0 = platformCpuAff0(i)
        if aff0 == UInt32.max { return false }
        if aff0 >= smpMaxCpuCount() { return false }
        i += 1
    }

    return platformCpuAff0(0) == 0
}
