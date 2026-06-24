// SPDX-License-Identifier: Apache-2.0
// cellnschild.swift — the workload a C6c cell supervisor launches into a cell that
// is rooted at /www. It probes its own namespace and exits 0 only if the cell root
// confines it as expected:
//   * a file inside the root resolves (cwd is the cell root) — open("index.html");
//   * a path outside the root is refused — open("/etc/motd") must fail;
//   * the global root itself is unreachable — open("/") must fail.
// Each check prints a CELLNS marker; a violation prints CELLNS FAIL and exits 1 so
// the supervisor (and the boot test) sees it.

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp

    // Positive: a file inside the cell root resolves via the cell-rooted cwd.
    let inFd = swiftos_open("index.html", 0)
    if inFd < 0 {
        swiftos_puts("CELLNS FAIL: file inside the cell root was not readable\n")
        return 1
    }
    _ = swiftos_close(inFd)
    swiftos_puts("CELLNS: own root readable (index.html)\n")

    // Negative: a path outside the cell root must be refused.
    let escFd = swiftos_open("/etc/motd", 0)
    if escFd >= 0 {
        _ = swiftos_close(escFd)
        swiftos_puts("CELLNS FAIL: escaped cell root (/etc/motd opened)\n")
        return 1
    }
    swiftos_puts("CELLNS: escape blocked (/etc/motd denied)\n")

    // Negative: the global root is not a descendant of the cell root, so even "/"
    // is unreachable — the child resolves `/` within its own root.
    let rootFd = swiftos_open("/", 0)
    if rootFd >= 0 {
        _ = swiftos_close(rootFd)
        swiftos_puts("CELLNS FAIL: reached the global root\n")
        return 1
    }
    swiftos_puts("CELLNS: global root unreachable (/ denied)\n")
    return 0
}
