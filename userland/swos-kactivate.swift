// SPDX-License-Identifier: Apache-2.0
// swos-kactivate.swift — flip the active kernel slot for the next boot
// (swift-os, U1g-5d).
//
// Calls the capConsole-gated kernel_activate syscall (69): the kernel updates
// the loader-managed \EFI\swift-os\kernel-state file so the next boot tries the
// OTHER kernel slot. The signed kernel-boot manifest still authenticates slot
// hashes; active selection is mutable boot-state. Operator flow: swos-kstage
// (write the inactive slot) -> swos-kactivate -> reboot. Needs CAP_CONSOLE.

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp

    let rc = swiftos_kernel_activate()
    if rc == 0 {
        swiftos_puts("swos-kactivate: inactive kernel slot activated; reboot to use it\n")
        return 0
    }
    if rc == -1 {
        swiftos_puts("swos-kactivate: permission denied (need capConsole)\n")
    } else if rc == -19 {
        swiftos_puts("swos-kactivate: no ESP/GPT boot disk reachable\n")
    } else if rc == -2 {
        swiftos_puts("swos-kactivate: kernel-boot or kernel-state not found on the ESP\n")
    } else if rc == -22 {
        swiftos_puts("swos-kactivate: kernel-state is invalid or active slot is unknown\n")
    } else {
        swiftos_puts("swos-kactivate: failed to activate the inactive slot\n")
    }
    return 1
}
