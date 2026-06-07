// SPDX-License-Identifier: Apache-2.0
// pwd.swift — native Swift `/bin/pwd` for swift-os.
//
// Prints the current working directory (kernel getcwd syscall via the bridge).

private let pathCap = 256

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp
    var status: Int32 = 0
    withUnsafeTemporaryAllocation(of: CChar.self, capacity: pathCap) { buf in
        let base = buf.baseAddress!
        let n = swiftos_getcwd(base, UInt(pathCap))
        if n <= 0 {
            swiftos_puts("pwd: cannot determine current directory\n")
            status = 1
        } else {
            _ = swiftos_write(1, UnsafeRawPointer(base), UInt(n))
            swiftos_putc(0x0A)
        }
    }
    return status
}
