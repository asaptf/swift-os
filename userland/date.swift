// date.swift — native Swift `/bin/date` for swift-os.
//
// Prints the current UTC wall-clock time read from the PL031 RTC (via the
// time() syscall). No timezones or formatting flags — just a fixed ISO-ish
// "YYYY-MM-DD HH:MM:SS UTC".

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp
    let t = swiftos_time()
    if t == 0 {
        swiftos_puts("date: no clock\n")
        return 1
    }
    withUnsafeTemporaryAllocation(of: CChar.self, capacity: 24) { buf in
        let p = buf.baseAddress!
        swiftos_fmt_time(t, p)
        swiftos_puts(p)
    }
    swiftos_puts(" UTC\n")
    return 0
}
