// SPDX-License-Identifier: Apache-2.0
// mkdir.swift — native Swift `/bin/mkdir` for swift-os.
//
// Creates each named directory (in the writable tmpfs; the base is read-only).

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp
    guard let argv = argv, argc > 1 else {
        swiftos_puts("usage: mkdir DIR...\n")
        return 1
    }
    var status: Int32 = 0
    var i = 1
    while i < Int(argc) {
        if let p = argv[i], swiftos_mkdir(UnsafePointer(p)) != 0 {
            swiftos_puts("mkdir: cannot create directory\n")
            status = 1
        }
        i += 1
    }
    return status
}
