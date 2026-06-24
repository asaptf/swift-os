// SPDX-License-Identifier: Apache-2.0
// cellchild.swift — the workload a C6b cell supervisor launches into a cell.
//
// Deliberately tiny: announce liveness on stdout, then block on a read of fd 0
// (the pipe read-end the supervisor handed it) until the supervisor releases the
// barrier by closing the pipe (EOF). While it blocks it is a live process charged
// to its cell's accounting domain — which is exactly what the supervisor measures
// via cell_stat. No timing assumptions: the supervisor controls when it exits.

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp
    swiftos_puts("CELLCHILD: alive in cell\n")
    var byte: UInt8 = 0
    _ = swiftos_read(0, &byte, 1) // blocks until the supervisor closes the pipe (EOF)
    return 0
}
