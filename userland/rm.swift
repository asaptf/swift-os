// rm.swift — native Swift `/bin/rm` for swift-os.
//
// Removes each named file (unlink) from the writable tmpfs. Files only; there is
// no recursive `-r` (directory removal is rmdir, on empty dirs).

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp
    guard let argv = argv, argc > 1 else {
        swiftos_puts("usage: rm FILE...\n")
        return 1
    }
    var status: Int32 = 0
    var i = 1
    while i < Int(argc) {
        if let p = argv[i], swiftos_unlink(UnsafePointer(p)) != 0 {
            swiftos_puts("rm: cannot remove file\n")
            status = 1
        }
        i += 1
    }
    return status
}
