// SPDX-License-Identifier: Apache-2.0
// swos-kconfirm.swift — mark the booted ESP kernel slot healthy (swift-os,
// U1g-5c).
//
// Calls the capConsole-gated kernel_confirm syscall (70): the kernel updates the
// loader-managed \EFI\swift-os\kernel-state file, marking the slot actually
// booted by the loader CONFIRMED and resetting its attempt counter. Run after a
// healthy UEFI kernel-slot trial boot. Needs CAP_CONSOLE.

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp

    let rc = swiftos_kernel_confirm()
    if rc == 0 {
        swiftos_puts("swos-kconfirm: booted kernel slot confirmed healthy\n")
        return 0
    }
    if rc == -1 {
        swiftos_puts("swos-kconfirm: permission denied (need capConsole)\n")
    } else if rc == -19 {
        swiftos_puts("swos-kconfirm: no ESP/GPT boot disk reachable\n")
    } else if rc == -2 {
        swiftos_puts("swos-kconfirm: kernel-state not found on the ESP\n")
    } else if rc == -22 {
        swiftos_puts("swos-kconfirm: kernel-state is invalid or has no booted slot\n")
    } else {
        swiftos_puts("swos-kconfirm: failed to confirm the booted kernel slot\n")
    }
    return 1
}
