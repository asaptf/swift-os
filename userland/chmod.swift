// SPDX-License-Identifier: Apache-2.0
// chmod.swift — native Swift `/bin/chmod` for swift-os.
//
// Usage: chmod OCTAL FILE...   (e.g. chmod 600 /tmp/f)
// Changes permission bits on tmpfs files (the base FS is read-only).

private func parseOctal(_ p: UnsafePointer<CChar>) -> (UInt32, Bool) {
    var v: UInt32 = 0
    var i = 0
    if p[0] == 0 { return (0, false) }
    while p[i] != 0 {
        let c = p[i]
        if c < 0x30 || c > 0x37 { return (0, false) } // not an octal digit
        v = v * 8 + UInt32(c - 0x30)
        i += 1
    }
    return (v, true)
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp
    guard let argv = argv, argc >= 3, let modeArg = argv[1] else {
        swiftos_puts("usage: chmod OCTAL FILE...\n")
        return 1
    }
    let (mode, okMode) = parseOctal(UnsafePointer(modeArg))
    if !okMode {
        swiftos_puts("chmod: invalid mode (octal only)\n")
        return 1
    }
    var status: Int32 = 0
    var i = 2
    while i < Int(argc) {
        if let p = argv[i], swiftos_chmod(UnsafePointer(p), mode) != 0 {
            swiftos_puts("chmod: cannot change mode\n")
            status = 1
        }
        i += 1
    }
    return status
}
