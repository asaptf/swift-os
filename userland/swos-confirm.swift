// SPDX-License-Identifier: Apache-2.0
// swos-confirm.swift — mark the active A/B update slot healthy (swift-os, U1c).
//
// Calls the capConsole-gated update_confirm syscall (65): on success the booted
// slot is recorded CONFIRMED in the SWOSBOOT manifest, so it stops accruing boot
// attempts and is never rolled back to the fallback. An operator runs this after
// verifying a freshly activated system image is healthy. Needs CAP_CONSOLE (the
// boot/admin context), so an ordinary/guest principal is refused.

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp

    let rc = swiftos_update_confirm()
    if rc == 0 {
        swiftos_puts("swos-confirm: active slot confirmed healthy\n")
        return 0
    }
    if rc == -1 {
        swiftos_puts("swos-confirm: permission denied (need capConsole)\n")
    } else if rc == -19 {
        swiftos_puts("swos-confirm: not booted from an A/B update store\n")
    } else {
        swiftos_puts("swos-confirm: failed to confirm slot\n")
    }
    return 1
}
