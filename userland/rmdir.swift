// rmdir.swift — native Swift `/bin/rmdir` for swift-os.
//
// Removes each named (empty) directory from the writable tmpfs.

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp
    guard let argv = argv, argc > 1 else {
        swiftos_puts("usage: rmdir DIR...\n")
        return 1
    }
    var status: Int32 = 0
    var i = 1
    while i < Int(argc) {
        if let p = argv[i], swiftos_rmdir(UnsafePointer(p)) != 0 {
            swiftos_puts("rmdir: cannot remove directory\n")
            status = 1
        }
        i += 1
    }
    return status
}
