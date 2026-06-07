// SPDX-License-Identifier: Apache-2.0
// handle_test.swift — host unit test for kernel/vfs/handle.swift (C1).
//
// Compiled with the host Swift toolchain against the pure, dependency-free
// handle vocabulary the kernel links (no MMIO/syscalls/heap), then run with no
// arguments. It asserts the Rights bitset algebra (superset, attenuation),
// the rights(read:write:) constructor the fd-as-handle path uses, and that the
// HandleKind cases are distinct. Mirrors tests/crypto_test.swift's style.

import Foundation

@main
struct HandleTest {
    static var failed = false

    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failed = true
        }
    }

    static func main() {
        // ---- 1. Rights superset --------------------------------------------
        check(Rights([.read, .write]).isSuperset(of: [.read]),
              "[read,write] is a superset of [read]")
        check(!Rights([.read]).isSuperset(of: [.read, .write]),
              "[read] is not a superset of [read,write]")

        // ---- 2. Attenuation is restrict-only -------------------------------
        check(attenuate([.read, .write], to: [.read]) == [.read],
              "attenuate([read,write], to: [read]) == [read]")
        check(attenuate([.read], to: [.read, .write]) == [.read],
              "attenuate([read], to: [read,write]) == [read] (cannot add)")

        // ---- 3. rights(read:write:) constructor ----------------------------
        check(rights(read: true, write: false) == [.read],
              "rights(read: true, write: false) == [read]")
        check(rights(read: false, write: true) == [.write],
              "rights(read: false, write: true) == [write]")
        check(rights(read: true, write: true) == [.read, .write],
              "rights(read: true, write: true) == [read,write]")

        // ---- 4. HandleKind cases are distinct ------------------------------
        check(HandleKind.file.rawValue != HandleKind.socket.rawValue,
              "HandleKind.file != .socket")
        check(HandleKind.none.rawValue != HandleKind.tty.rawValue,
              "HandleKind.none != .tty")
        check(HandleKind.pipe.rawValue != HandleKind.file.rawValue,
              "HandleKind.pipe != .file")

        if failed {
            FileHandle.standardError.write(Data("handle_test: FAILURES\n".utf8))
            exit(1)
        }
        print("handle_test: OK")
    }
}
