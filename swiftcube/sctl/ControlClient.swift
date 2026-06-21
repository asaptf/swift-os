// SPDX-License-Identifier: Apache-2.0
// ControlClient.swift — the transport seam the `sctl` command layer talks to (SC9a).
//
// The CLI's command dispatch, validation, and output formatting (Command.swift) are written
// against this one small interface, never against a socket. That is what keeps the whole command
// layer testable host-side independent of transport: the acceptance test (case 2) drives it over a
// `StoreControlClient` backed by an in-process cubestore (the milestone's "fake control client"),
// while the host CLI binary drives it over a real mTLS channel to `sctld`.
//
// The five operations map one-to-one onto the SC2 control RPCs (put / range / casPut) plus a
// delete — every `sctl` verb is expressible as KV reads/writes over cubestore, which is the whole
// point of the etcd-style design. `range(prefix:)` lists a subtree; `casPut` is the
// compare-and-set used to bump a revision without clobbering a concurrent writer.
//
// Class-bound (`AnyObject`) so it monomorphizes to a single existential under Embedded Swift, like
// the `ProbeProber` / `CellSupervisor` seams — the in-process implementation links into both the
// host CLI and (for `sctld`'s own embedded use) the daemon. Foundation-free.
//
// Transport note (surfaced, not hidden): the SC2 RPC set has put/range/casPut but NO delete
// opcode, and `sctld`'s production accept-loop is itself a seam (it runs a self-test on-device, not
// a server loop yet — see control/FORMAT.md). So the real over-the-wire `WireControlClient` — and
// a delete RPC to back `sctl delete` remotely — land with the SC9b multi-node QEMU harness that can
// actually exercise them end to end. SC9a ships the seam + the in-process client it is tested on.

/// One key/value/revision triple returned by a read.
struct ControlKV: Equatable {
    var key: [UInt8]
    var value: [UInt8]
    var modRevision: Revision
}

protocol ControlClient: AnyObject {
    /// Every entry whose key starts with `prefix`, in key order.
    func range(prefix: [UInt8]) -> [ControlKV]

    /// The single entry at `key`, or nil if absent.
    func get(_ key: [UInt8]) -> ControlKV?

    /// Unconditional write. Returns the committed revision.
    @discardableResult
    func put(_ key: [UInt8], _ value: [UInt8]) -> Revision

    /// Compare-and-set: write iff the key's current modRevision equals `expect`, or — when
    /// `expect == nil` — iff the key is absent. Returns whether the write committed.
    @discardableResult
    func casPut(_ key: [UInt8], _ value: [UInt8], expect: Revision?) -> Bool

    /// Remove a key. Returns whether the key existed (so a verb can report "not found").
    @discardableResult
    func delete(_ key: [UInt8]) -> Bool
}
