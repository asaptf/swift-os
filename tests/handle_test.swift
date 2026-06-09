// SPDX-License-Identifier: Apache-2.0
// handle_test.swift — host unit test for kernel/vfs/handle.swift (C1-C3).
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
        // ---- 1. Stable Rights bit positions --------------------------------
        check(Rights.read.rawValue == 1 << 0, "Rights.read bit is stable")
        check(Rights.write.rawValue == 1 << 1, "Rights.write bit is stable")
        check(Rights.execute.rawValue == 1 << 2, "Rights.execute bit is stable")
        check(Rights.map.rawValue == 1 << 3, "Rights.map bit is stable")
        check(Rights.duplicate.rawValue == 1 << 4, "Rights.duplicate bit is stable")
        check(Rights.transfer.rawValue == 1 << 5, "Rights.transfer bit is stable")
        check(Rights.getattr.rawValue == 1 << 6, "Rights.getattr bit is stable")
        check(Rights.setattr.rawValue == 1 << 7, "Rights.setattr bit is stable")

        // ---- 2. Rights superset --------------------------------------------
        check(Rights([.read, .write]).isSuperset(of: [.read]),
              "[read,write] is a superset of [read]")
        check(!Rights([.read]).isSuperset(of: [.read, .write]),
              "[read] is not a superset of [read,write]")
        check(hasRights([.read, .getattr], [.read]),
              "hasRights accepts a subset of held rights")
        check(!hasRights([.read], [.read, .getattr]),
              "hasRights rejects missing required rights")

        // ---- 3. Attenuation is restrict-only -------------------------------
        check(attenuate([.read, .write], to: [.read]) == [.read],
              "attenuate([read,write], to: [read]) == [read]")
        check(attenuate([.read], to: [.read, .write]) == [.read],
              "attenuate([read], to: [read,write]) == [read] (cannot add)")
        check(attenuate([.read, .duplicate], to: [.read, .transfer]) == [.read],
              "attenuate cannot add transfer while restricting duplicate")
        check(attenuate([.read, .write, .getattr], to: []) == [],
              "attenuate to an empty mask removes all rights")
        let allRights: Rights = [.read, .write, .execute, .map, .duplicate, .transfer, .getattr, .setattr]
        check(attenuate(allRights, to: allRights) == allRights,
              "attenuate to all rights preserves held rights")
        check(attenuate([.transfer], to: [.read, .write, .transfer]) == [.transfer],
              "attenuate preserves transfer when explicitly allowed")
        check(attenuate([.read], to: [.read, .write, .transfer]) == [.read],
              "attenuate cannot add endpoint write or transfer rights")

        // ---- 4. rights(read:write:) constructor ----------------------------
        check(rights(read: false, write: false) == [],
              "rights(read: false, write: false) == []")
        check(rights(read: true, write: false) == [.read],
              "rights(read: true, write: false) == [read]")
        check(rights(read: false, write: true) == [.write],
              "rights(read: false, write: true) == [write]")
        check(rights(read: true, write: true) == [.read, .write],
              "rights(read: true, write: true) == [read,write]")

        // ---- 5. HandleKind cases are distinct ------------------------------
        check(HandleKind.file.rawValue != HandleKind.socket.rawValue,
              "HandleKind.file != .socket")
        check(HandleKind.none.rawValue != HandleKind.tty.rawValue,
              "HandleKind.none != .tty")
        check(HandleKind.pipe.rawValue != HandleKind.file.rawValue,
              "HandleKind.pipe != .file")
        check(HandleKind.endpoint.rawValue != HandleKind.socket.rawValue,
              "HandleKind.endpoint != .socket")

        // ---- 6. C2 handle inheritance selector ------------------------------
        check(handleInheritanceCopiesFD(.all, fd: 0), ".all copies fd 0")
        check(handleInheritanceCopiesFD(.all, fd: 3), ".all copies fd 3")
        check(handleInheritanceCopiesFD(.all, fd: 31), ".all copies high fds")
        check(handleInheritanceCopiesFD(.stdioOnly, fd: 0), ".stdioOnly copies stdin")
        check(handleInheritanceCopiesFD(.stdioOnly, fd: 1), ".stdioOnly copies stdout")
        check(handleInheritanceCopiesFD(.stdioOnly, fd: 2), ".stdioOnly copies stderr")
        check(!handleInheritanceCopiesFD(.stdioOnly, fd: 3), ".stdioOnly drops fd 3")
        check(!handleInheritanceCopiesFD(.explicit, fd: 0), ".explicit does not copy implicit fd 0")
        check(!handleInheritanceCopiesFD(.explicit, fd: 3), ".explicit does not copy implicit fd 3")

        // ---- 7. C2 HandleSpec ABI vocabulary --------------------------------
        check(handleSpecSize == 16, "HandleSpec user ABI size is stable")
        check(handleSpecFlagCloexec == 1, "HandleSpec cloexec flag bit is stable")
        let spec = HandleSpec(sourceFD: 3, targetFD: 4,
                              rightsMask: Rights.read.rawValue | Rights.getattr.rawValue,
                              flags: handleSpecFlagCloexec)
        check(spec.sourceFD == 3 && spec.targetFD == 4, "HandleSpec records source and target fds")
        check(spec.rightsMask == (Rights.read.rawValue | Rights.getattr.rawValue),
              "HandleSpec records the rights mask")
        check(spec.flags == handleSpecFlagCloexec, "HandleSpec records flags")

        // ---- 8. HandleEntry is a typed fd slot ------------------------------
        let empty = HandleEntry()
        check(!empty.inUse && empty.kind == .none && empty.object == -1 &&
              empty.rights == [] && !empty.cloexec,
              "default HandleEntry is empty")

        let fd = HandleEntry(inUse: true, kind: .file, object: 7,
                             rights: [.read, .duplicate], cloexec: true)
        check(fd.inUse, "HandleEntry can be marked in use")
        check(fd.kind == .file, "HandleEntry records its kind")
        check(fd.object == 7, "HandleEntry records its object index")
        check(fd.rights == [.read, .duplicate], "HandleEntry records per-handle rights")
        check(fd.cloexec, "HandleEntry records close-on-exec per slot")

        // ---- 9. C4a endpoint handle vocabulary -------------------------------
        let sendEndpoint = HandleEntry(inUse: true, kind: .endpoint, object: 11,
                                       rights: [.write, .transfer])
        check(sendEndpoint.kind == .endpoint, "send endpoint is an endpoint handle")
        check(sendEndpoint.rights == [.write, .transfer],
              "send endpoint carries write+transfer rights")
        let recvEndpoint = HandleEntry(inUse: true, kind: .endpoint, object: 12,
                                       rights: [.read, .transfer])
        check(recvEndpoint.kind == .endpoint, "recv endpoint is an endpoint handle")
        check(recvEndpoint.rights == [.read, .transfer],
              "recv endpoint carries read+transfer rights")

        if failed {
            FileHandle.standardError.write(Data("handle_test: FAILURES\n".utf8))
            exit(1)
        }
        print("handle_test: OK")
    }
}
