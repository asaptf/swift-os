// SPDX-License-Identifier: Apache-2.0
// VolumeStore.swift — the datafs durability seam for persistent volumes, Foundation-free.
//
// This isolates the volume MANAGER (provisioning / binding / fencing — all host-testable)
// from the datafs MEDIUM (the dedicated virtio-blk `/data` tier with honest fsync). It is
// the SC8 analogue of cubestore's `AppendLog`/`SnapshotStore` seam: the manager only ever
// names a `volumeId` and hands across already-built byte blobs; the sink does the I/O.
//
// Two bindings sit behind it (the SC3 FakeCellSupervisor / NetProbe split):
//   • HostDirVolumeStore — a host directory standing in for datafs, with a real POSIX
//     fsync (the "honest fsync" durability model). Test-only; uses Foundation.
//   • DatafsVolumeStore — the on-device binding over the swiftos file syscalls
//     (open/write/fsync/mkdir/unlink), compiled into the `slet` ELF. Exercised on-device
//     once datafs + C6 are reachable (the QEMU gate, deferred like SC3).
//
// QUOTA: datafs is a small inode-table + block-bitmap FS with NO per-subtree quota. So
// `size` is BEST-EFFORT accounting only — the store reports `usedBytes` for observability
// but enforces nothing. The manager surfaces this gap honestly rather than faking a limit.

/// The result of a durable write — distinguishes a medium failure from success so the
/// manager can refuse to mark a volume durable when the disk did not accept the bytes.
enum VolumeIOResult: Equatable {
    case ok
    case failed(reason: String)
}

/// A node-local persistent-volume medium (datafs `/data`). Every mutating call carries
/// honest durability where it claims to: `provision` and `writeFile` must reach stable
/// storage (fsync) before returning `.ok`, so a crash after a successful return cannot
/// lose the subtree's existence or a flushed file.
protocol VolumeStore: AnyObject {
    /// The absolute datafs path a volume occupies (e.g. `/data/volumes/<id>`). Pure —
    /// names the location without touching the disk.
    func path(volumeId: String) -> String

    /// Create the volume subtree (idempotent — provisioning an existing volume is a no-op
    /// success, which is how a restart re-attaches to surviving data). Durable on `.ok`.
    func provision(volumeId: String) -> VolumeIOResult

    /// Whether the volume subtree already exists on the medium. After a reboot this is
    /// what proves "/data survived": the subtree (and its files) are still present.
    func exists(volumeId: String) -> Bool

    /// Durably write a file inside the volume (honest fsync of the file AND its parent so
    /// the name is stable). `.ok` ⇒ it survives a crash.
    func writeFile(volumeId: String, name: String, bytes: Bytes) -> VolumeIOResult

    /// Read a file previously written inside the volume, or nil if absent.
    func readFile(volumeId: String, name: String) -> Bytes?

    /// Best-effort used-byte accounting. datafs has NO quota, so this is informational
    /// only (observability), never an enforcement gate. 0 if the volume is absent.
    func usedBytes(volumeId: String) -> UInt64

    /// Remove the volume subtree and everything under it. Only an explicit `Delete`
    /// retain policy reaches this — a routine teardown never does.
    func remove(volumeId: String) -> VolumeIOResult
}
