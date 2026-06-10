// SPDX-License-Identifier: Apache-2.0
// swos-activate.swift — promote the inactive A/B slot (swift-os, U1e).
//
// Calls the capConsole-gated update_activate syscall (61): the inactive slot
// becomes active for the next boot (the current slot becomes the fallback), and
// the newly-activated slot boots "on trial" — UNTRIED with its attempt counter
// reset, so U1d's attempt-based rollback returns to the fallback if it never
// gets confirmed. An operator runs this after staging a new image into the
// inactive slot, then reboots. Needs CAP_CONSOLE (so a guest is refused).

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp

    let rc = swiftos_update_activate()
    if rc == 0 {
        swiftos_puts("swos-activate: inactive slot activated (on trial); reboot to use it\n")
        return 0
    }
    if rc == -1 {
        swiftos_puts("swos-activate: permission denied (need capConsole)\n")
    } else if rc == -19 {
        swiftos_puts("swos-activate: not booted from an A/B update store\n")
    } else if rc == -2 {
        swiftos_puts("swos-activate: no inactive slot to activate\n")
    } else {
        swiftos_puts("swos-activate: failed to activate the inactive slot\n")
    }
    return 1
}
