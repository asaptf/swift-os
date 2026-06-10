// SPDX-License-Identifier: Apache-2.0
// pkghello.swift - tiny package overlay acceptance program.

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc
    _ = argv
    _ = envp
    swiftos_puts("pkghello: hello from package overlay\n")
    return 0
}
