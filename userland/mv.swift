// mv.swift — native Swift `/bin/mv` for swift-os.
//
// Renames/moves SRC to DST within the writable tmpfs (kernel rename syscall).

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp
    guard let argv = argv, argc == 3, let src = argv[1], let dst = argv[2] else {
        swiftos_puts("usage: mv SRC DST\n")
        return 1
    }
    if swiftos_rename(UnsafePointer(src), UnsafePointer(dst)) != 0 {
        swiftos_puts("mv: cannot move\n")
        return 1
    }
    return 0
}
