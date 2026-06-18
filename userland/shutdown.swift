// SPDX-License-Identifier: Apache-2.0
// shutdown.swift — power the machine off (swift-os).
//
// Calls the capConsole-gated reboot syscall (90, SWIFTOS_POWER_OFF): the kernel
// flushes /data (sync) and issues PSCI SYSTEM_OFF, which powers the machine down
// (under QEMU `virt` this makes the emulator exit). On success this never returns.
// Needs CAP_CONSOLE (the boot/admin context), so an ordinary/guest principal is
// refused. Use /bin/reboot for a warm restart.

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp

    swiftos_puts("shutdown: powering off...\n")
    let rc = swiftos_poweroff() // only returns on failure
    if rc == -1 {
        swiftos_puts("shutdown: permission denied (need capConsole)\n")
    } else if rc == -38 {
        swiftos_puts("shutdown: no PSCI conduit; cannot power off\n")
    } else {
        swiftos_puts("shutdown: failed to power off\n")
    }
    return 1
}
