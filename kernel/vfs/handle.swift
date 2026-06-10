// SPDX-License-Identifier: Apache-2.0
// handle.swift — the typed handle vocabulary (C1).
//
// A handle is a small, copyable descriptor that names a kernel object and
// carries the rights its holder has on that object. C1 generalizes the fd
// table in vfs.swift into a handle table keyed on these types; later milestones
// add more non-fd object kinds (vmo, cell, …) as HandleKind cases. See
// docs/CAPABILITIES.md §2.
//
// This file is deliberately dependency-free (no vnodes/sockets/uart/process), so
// the host unit test (tests/handle_test.swift) can compile it stand-alone.

// One per kind of kernel-managed object behind a handle. 1:1 with the old
// fdKind* constants in vfs.swift: none/tty/file/pipe/socket, with the former
// fdKindVNode folding into .file (directories keep using .file too).
// .endpoint is the C4 IPC object; .device is the C5 opaque device-ownership
// grant used by restartable driver services.
enum HandleKind: UInt8 { case none, tty, file, pipe, socket, endpoint, device }

// Per-handle, per-kind rights — a typed bitset checked per *handle*, not per
// *process*. read/write are used today; the rest are reserved for later
// milestones (C3+) and kept defined so their bit positions stay stable.
struct Rights: OptionSet {
    let rawValue: UInt32
    static let read      = Rights(rawValue: 1 << 0)
    static let write     = Rights(rawValue: 1 << 1)
    static let execute   = Rights(rawValue: 1 << 2)
    static let map       = Rights(rawValue: 1 << 3)
    static let duplicate = Rights(rawValue: 1 << 4)
    static let transfer  = Rights(rawValue: 1 << 5)
    static let getattr   = Rights(rawValue: 1 << 6)
    static let setattr   = Rights(rawValue: 1 << 7)
}

// How a new process's handle table is seeded from its parent (C2). `all` is the
// permissive fork case (copy every in-use handle); `stdioOnly` is the
// compatibility spawn default (just fds 0/1/2); `explicit` starts empty and
// installs only the caller-provided HandleSpec entries. See docs/CAPABILITIES.md §3.
enum HandleInheritance { case all, stdioOnly, explicit }

// One explicit inherited handle for C2 spawn-with-handles: duplicate sourceFD from
// the parent into targetFD in the child, attenuating rights to rightsMask. flags
// currently only carries close-on-exec for the child slot; object-scoped policy is
// deliberately left for C3+.
struct HandleSpec {
    var sourceFD: Int32
    var targetFD: Int32
    var rightsMask: UInt32
    var flags: UInt32

    init(sourceFD: Int32 = -1, targetFD: Int32 = -1,
         rightsMask: UInt32 = 0, flags: UInt32 = 0) {
        self.sourceFD = sourceFD
        self.targetFD = targetFD
        self.rightsMask = rightsMask
        self.flags = flags
    }
}

let handleSpecSize = 16
let handleSpecFlagCloexec: UInt32 = 1 << 0

func handleInheritanceCopiesFD(_ inherit: HandleInheritance, fd: Int) -> Bool {
    if fd < 0 { return false }
    switch inherit {
    case .all:
        return true
    case .stdioOnly:
        return fd < 3
    case .explicit:
        return false
    }
}

// One entry in a process's handle table. C1 keeps the POSIX fd namespace as the
// observable view of this table: `object` is still the shared OpenDescription
// index used by vfs.swift, while `kind`, `rights`, and `cloexec` are properties
// of the individual handle slot.
struct HandleEntry {
    var inUse = false
    var kind: HandleKind = .none
    var object = -1
    var rights = Rights()
    var cloexec = false

    init(inUse: Bool = false, kind: HandleKind = .none, object: Int = -1,
         rights: Rights = Rights(), cloexec: Bool = false) {
        self.inUse = inUse
        self.kind = kind
        self.object = object
        self.rights = rights
        self.cloexec = cloexec
    }
}

// Build the read/write rights for a freshly minted handle. Kept dependency-free:
// the O_* flag constants live in vfs.swift, which computes these two bools.
func rights(read: Bool, write: Bool) -> Rights {
    var r = Rights()
    if read  { r.insert(.read) }
    if write { r.insert(.write) }
    return r
}

// Attenuation: restrict `r` to at most `mask`. Restrict-only — the intersection
// can never add a right the source did not already hold.
func attenuate(_ r: Rights, to mask: Rights) -> Rights { r.intersection(mask) }

func hasRights(_ held: Rights, _ required: Rights) -> Bool {
    held.isSuperset(of: required)
}
