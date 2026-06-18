// SPDX-License-Identifier: Apache-2.0
// errno_test.swift — host unit test for kernel/errno.swift (QW6).
//
// Compiled with the host Swift toolchain against the pure, dependency-free
// Errno enum the kernel links (no MMIO/syscalls/heap), then run with no
// arguments. It pins the exact numeric raw value of every case — these values
// ARE the syscall ABI (frame[0] = errno.rawValue) and must never drift — and
// checks the .code boundary form. Mirrors tests/handle_test.swift's style.

import Foundation

@main
struct ErrnoTest {
    static var failed = false

    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failed = true
        }
    }

    static func main() {
        // ---- 1. Exact raw values (ABI — POSIX errno, negated) ---------------
        check(Errno.perm.rawValue == -1, "EPERM == -1")
        check(Errno.noEntry.rawValue == -2, "ENOENT == -2")
        check(Errno.srch.rawValue == -3, "ESRCH == -3")
        check(Errno.intr.rawValue == -4, "EINTR == -4")
        check(Errno.io.rawValue == -5, "EIO == -5")
        check(Errno.badFD.rawValue == -9, "EBADF == -9")
        check(Errno.child.rawValue == -10, "ECHILD == -10")
        check(Errno.again.rawValue == -11, "EAGAIN == -11")
        check(Errno.noMem.rawValue == -12, "ENOMEM == -12")
        check(Errno.access.rawValue == -13, "EACCES == -13")
        check(Errno.fault.rawValue == -14, "EFAULT == -14")
        check(Errno.busy.rawValue == -16, "EBUSY == -16")
        check(Errno.exists.rawValue == -17, "EEXIST == -17")
        check(Errno.noDev.rawValue == -19, "ENODEV == -19")
        check(Errno.notDir.rawValue == -20, "ENOTDIR == -20")
        check(Errno.isDir.rawValue == -21, "EISDIR == -21")
        check(Errno.invalid.rawValue == -22, "EINVAL == -22")
        check(Errno.manyFiles.rawValue == -24, "EMFILE == -24")
        check(Errno.fileTooBig.rawValue == -27, "EFBIG == -27")
        check(Errno.noSpace.rawValue == -28, "ENOSPC == -28")
        check(Errno.readOnly.rawValue == -30, "EROFS == -30")
        check(Errno.pipe.rawValue == -32, "EPIPE == -32")
        check(Errno.noSys.rawValue == -38, "ENOSYS == -38")
        check(Errno.notEmpty.rawValue == -39, "ENOTEMPTY == -39")
        check(Errno.addrInUse.rawValue == -98, "EADDRINUSE == -98")
        check(Errno.netDown.rawValue == -100, "ENETDOWN == -100")
        check(Errno.hostUnreach.rawValue == -101, "EHOSTUNREACH == -101")

        // ---- 2. .code is the Int boundary form written to frame[0] ----------
        check(Errno.invalid.code == -22, "Errno.invalid.code == -22 (boundary Int)")
        check(Errno.noSys.code == -38, "Errno.noSys.code == -38 (boundary Int)")
        check(Errno.netDown.code == -100, "Errno.netDown.code == -100 (boundary Int)")
        check(Errno.again.code == Int(Errno.again.rawValue),
              ".code equals Int(rawValue) for every case")

        // ---- 3. All raw values are distinct (no two errnos collide) ---------
        let all: [Errno] = [
            .perm, .noEntry, .srch, .intr, .io, .badFD, .child, .again, .noMem,
            .access, .fault, .busy, .exists, .noDev, .notDir, .isDir, .invalid,
            .manyFiles, .fileTooBig, .noSpace, .readOnly, .pipe, .noSys,
            .notEmpty, .addrInUse, .netDown, .hostUnreach,
        ]
        check(Set(all.map { $0.rawValue }).count == all.count,
              "every Errno case has a distinct raw value")
        check(all.allSatisfy { $0.rawValue < 0 }, "every Errno raw value is negative")

        if failed {
            FileHandle.standardError.write(Data("errno_test: FAILURES\n".utf8))
            exit(1)
        }
        print("errno_test: OK")
    }
}
