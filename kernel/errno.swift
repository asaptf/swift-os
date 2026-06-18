// SPDX-License-Identifier: Apache-2.0
// errno.swift — the single kernel errno table. One raw-value enum, Int32-backed.
//
// SwiftOS keeps typed errors *inside* the kernel and flattens to a plain Int at
// the syscall boundary (frame[0] = errno.rawValue). No throws/Result crosses the
// trap (see docs/ARCHITECTURE.md). Raw values are POSIX-compatible and MUST stay
// numerically identical to the previous per-subsystem constants — they are ABI.
//
// Raw-value enums carry no witness/existential cost in Embedded Swift: `.rawValue`
// is a plain integer load and `.code` is an allocation-free @inline(__always) Int,
// safe on hot paths. Keep this file dependency-free (no MMIO/syscall/heap) so the
// host unit test (tests/errno_test.swift) can compile it standalone.

enum Errno: Int32 {
    case perm        = -1    // EPERM         operation not permitted
    case noEntry     = -2    // ENOENT        no such file or directory
    case srch        = -3    // ESRCH         no such process
    case intr        = -4    // EINTR         interrupted
    case io          = -5    // EIO           I/O error
    case badFD       = -9    // EBADF         bad file descriptor
    case child       = -10   // ECHILD        no child processes
    case again       = -11   // EAGAIN        try again / would block
    case noMem       = -12   // ENOMEM        out of memory
    case access      = -13   // EACCES        permission denied
    case fault       = -14   // EFAULT        bad address
    case busy        = -16   // EBUSY         device or resource busy
    case exists      = -17   // EEXIST        already exists
    case noDev       = -19   // ENODEV        no such device
    case notDir      = -20   // ENOTDIR       not a directory
    case isDir       = -21   // EISDIR        is a directory
    case invalid     = -22   // EINVAL        invalid argument
    case manyFiles   = -24   // EMFILE        too many open files
    case fileTooBig  = -27   // EFBIG         file too large
    case noSpace     = -28   // ENOSPC        no space left on device
    case readOnly    = -30   // EROFS         read-only filesystem
    case pipe        = -32   // EPIPE         broken pipe
    case noSys       = -38   // ENOSYS        function not implemented
    case notEmpty    = -39   // ENOTEMPTY     directory not empty
    case addrInUse   = -98   // EADDRINUSE    address already in use
    case netDown     = -100  // ENETDOWN      network is down
    case hostUnreach = -101  // EHOSTUNREACH  no route to host
}

extension Errno {
    /// The boundary representation: a plain Int errno for frame[0].
    @inline(__always)
    var code: Int { Int(rawValue) }
}
