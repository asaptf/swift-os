// SPDX-License-Identifier: Apache-2.0
// reboot.swift — warm-reboot the machine (swift-os).
//
// Calls the capConsole-gated reboot syscall (90, SWIFTOS_POWER_RESET): the kernel
// flushes /data (sync) and issues PSCI SYSTEM_RESET. On success this never
// returns — the machine resets. Needs CAP_CONSOLE (the boot/admin context), so an
// ordinary/guest principal is refused.

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp

    swiftos_puts("reboot: rebooting...\n")
    let rc = swiftos_reboot() // only returns on failure
    if rc == -1 {
        swiftos_puts("reboot: permission denied (need capConsole)\n")
    } else if rc == -38 {
        swiftos_puts("reboot: no PSCI conduit; cannot reboot\n")
    } else {
        swiftos_puts("reboot: failed to reboot\n")
    }
    return 1
}
