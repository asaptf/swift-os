// SPDX-License-Identifier: Apache-2.0
// swos-kstage.swift — stage the active kernel image into the inactive ESP slot
// (swift-os, U1g-4c).
//
// Calls the capConsole-gated kernel_stage syscall (68): the kernel copies the
// ACTIVE kernel slot's image (kernelA.bin / kernelB.bin) into the INACTIVE slot
// on the EFI System Partition, in place, and verifies it. This is the write side
// of runtime kernel staging — the on-disk groundwork before a signed manifest is
// written to flip the active slot (the loader still boots the active slot until
// then). Needs CAP_CONSOLE (a guest is refused).

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp

    let rc = swiftos_kernel_stage()
    if rc == 0 {
        swiftos_puts("swos-kstage: active kernel image staged into the inactive ESP slot (verified)\n")
        return 0
    }
    if rc == -1 {
        swiftos_puts("swos-kstage: permission denied (need capConsole)\n")
    } else if rc == -19 {
        swiftos_puts("swos-kstage: no ESP/GPT boot disk reachable\n")
    } else if rc == -2 {
        swiftos_puts("swos-kstage: kernel slot files not found on the ESP\n")
    } else if rc == -22 {
        swiftos_puts("swos-kstage: kernel slots are not the same size, or the manifest is invalid\n")
    } else {
        swiftos_puts("swos-kstage: failed to stage the inactive slot\n")
    }
    return 1
}
