// SPDX-License-Identifier: Apache-2.0
// uptime.swift — native Swift `/bin/uptime` for swift-os.
//
// Prints how long the system has been running, from SYS_SYSINFO uptime ticks
// (the same source as `/bin/top`). Format: "up [N day[s], ]H:MM:SS".

private func putUInt(_ value: UInt) {
    var divisor: UInt = 1
    while value / divisor >= 10 { divisor *= 10 }
    var rest = value
    while divisor > 0 {
        swiftos_putc(0x30 + UInt8(rest / divisor))
        rest %= divisor
        divisor /= 10
    }
}

private func put2(_ value: UInt) {
    if value < 10 { swiftos_putc(0x30) }
    putUInt(value)
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp

    if swiftos_sysinfo_refresh() != 0 {
        swiftos_puts("uptime: sysinfo failed\n")
        return 1
    }

    let ticks = swiftos_sys_uptime_ticks()
    let hz = UInt(swiftos_sys_hz())
    let secs = hz > 0 ? ticks / hz : 0
    let days = secs / 86400
    let hh = (secs % 86400) / 3600
    let mm = (secs % 3600) / 60
    let ss = secs % 60

    swiftos_puts("up ")
    if days > 0 {
        putUInt(days)
        if days == 1 {
            swiftos_puts(" day, ")
        } else {
            swiftos_puts(" days, ")
        }
    }
    putUInt(hh)
    swiftos_putc(0x3A) // ':'
    put2(mm)
    swiftos_putc(0x3A)
    put2(ss)
    swiftos_putc(0x0A)
    return 0
}
