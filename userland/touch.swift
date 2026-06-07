// SPDX-License-Identifier: Apache-2.0
// touch.swift — native Swift `/bin/touch` for swift-os.
//
// Creates each named file if absent (in the writable tmpfs). Note: swift-os has
// no utimes, so touching an existing file does not bump its mtime — touch here
// is "create if missing". The base FS is read-only.

private let oWrOnly: Int32 = 1
private let oCreat: Int32 = 0x40

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp
    guard let argv = argv, argc > 1 else {
        swiftos_puts("usage: touch FILE...\n")
        return 1
    }
    var status: Int32 = 0
    var i = 1
    while i < Int(argc) {
        if let p = argv[i] {
            let fd = swiftos_open(UnsafePointer(p), oWrOnly | oCreat)
            if fd < 0 {
                swiftos_puts("touch: cannot create file\n")
                status = 1
            } else {
                _ = swiftos_close(fd)
            }
        }
        i += 1
    }
    return status
}
