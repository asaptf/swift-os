// echo.swift — native Swift `/bin/echo` for swift-os.
//
// Prints its arguments separated by single spaces, followed by a newline.
// Supports `-n` (suppress the trailing newline). Minimal by design (no escape
// interpretation); enough to replace the busybox echo applet for /bin/echo.

private func cstrlen(_ p: UnsafePointer<CChar>) -> Int {
    var n = 0
    while p[n] != 0 { n += 1 }
    return n
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp
    guard let argv = argv else { swiftos_putc(0x0A); return 0 }

    var i = 1
    var newline = true
    // Leading -n suppresses the trailing newline.
    if i < Int(argc), let a = argv[i], a[0] == 0x2D, a[1] == 0x6E, a[2] == 0 {
        newline = false
        i += 1
    }

    var first = true
    while i < Int(argc) {
        if let a = argv[i] {
            if !first { swiftos_putc(0x20) } // space between args
            _ = swiftos_write(1, UnsafeRawPointer(a), UInt(cstrlen(a)))
            first = false
        }
        i += 1
    }
    if newline { swiftos_putc(0x0A) }
    return 0
}
