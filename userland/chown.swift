// chown.swift — native Swift `/bin/chown` for swift-os.
//
// Usage: chown UID FILE...   (numeric principal id, e.g. chown 2 /tmp/f)
// Changes the owning principal of tmpfs files (the base FS is read-only). swift-os
// principals are small numbers (1=root, 2=user, …); name lookup is not supported.

private func parseUInt(_ p: UnsafePointer<CChar>) -> (UInt32, Bool) {
    var v: UInt32 = 0
    var i = 0
    if p[0] == 0 { return (0, false) }
    while p[i] != 0 {
        let c = p[i]
        if c < 0x30 || c > 0x39 { return (0, false) }
        v = v * 10 + UInt32(c - 0x30)
        i += 1
    }
    return (v, true)
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp
    guard let argv = argv, argc >= 3, let ownerArg = argv[1] else {
        swiftos_puts("usage: chown UID FILE...\n")
        return 1
    }
    let (owner, okOwner) = parseUInt(UnsafePointer(ownerArg))
    if !okOwner {
        swiftos_puts("chown: invalid owner (numeric principal id only)\n")
        return 1
    }
    var status: Int32 = 0
    var i = 2
    while i < Int(argc) {
        if let p = argv[i], swiftos_chown(UnsafePointer(p), owner) != 0 {
            swiftos_puts("chown: cannot change owner\n")
            status = 1
        }
        i += 1
    }
    return status
}
