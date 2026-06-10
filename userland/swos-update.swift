// SPDX-License-Identifier: Apache-2.0
// swos-update.swift — stage the attached update payload into the inactive A/B
// slot (swift-os, U1f-2b).
//
// Calls the capConsole-gated update_stage syscall (62): the kernel copies the
// read-only payload disk (a signed SWOSBASE image, attached alongside the update
// store) into the INACTIVE slot, marking it UNTRIED so it boots "on trial". The
// operator workflow is: swos-update -> swos-activate -> reboot; if the staged
// image is healthy it confirms (swos-confirm), otherwise U1d rolls back to the
// known-good slot. The copy moves bytes only — the staged image's own Ed25519
// signature is verified at the next boot's mount. Needs CAP_CONSOLE (a guest is
// refused).

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp

    let rc = swiftos_update_stage()
    if rc == 0 {
        swiftos_puts("swos-update: payload staged into the inactive slot; run swos-activate then reboot\n")
        return 0
    }
    if rc == -1 {
        swiftos_puts("swos-update: permission denied (need capConsole)\n")
    } else if rc == -19 {
        swiftos_puts("swos-update: not booted from an A/B update store, or no payload disk attached\n")
    } else if rc == -22 {
        swiftos_puts("swos-update: payload is not a signed v3 base image\n")
    } else if rc == -27 {
        swiftos_puts("swos-update: payload is too large for the inactive slot\n")
    } else {
        swiftos_puts("swos-update: failed to stage the payload\n")
    }
    return 1
}
