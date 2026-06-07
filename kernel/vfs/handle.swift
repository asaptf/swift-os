// SPDX-License-Identifier: Apache-2.0
// handle.swift — the typed handle vocabulary (C1).
//
// A handle is a small, copyable descriptor that names a kernel object and
// carries the rights its holder has on that object. C1 generalizes the fd
// table in vfs.swift into a handle table keyed on these types; later milestones
// add the non-fd object kinds (ipcEndpoint, vmo, device, …) as more HandleKind
// cases. See docs/CAPABILITIES.md §2.
//
// This file is deliberately dependency-free (no vnodes/sockets/uart/process), so
// the host unit test (tests/handle_test.swift) can compile it stand-alone.

// One per kind of kernel-managed object behind a handle. 1:1 with the old
// fdKind* constants in vfs.swift: none/tty/file/pipe/socket, with the former
// fdKindVNode folding into .file (directories keep using .file too).
enum HandleKind: UInt8 { case none, tty, file, pipe, socket }

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
