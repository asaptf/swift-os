// SPDX-License-Identifier: Apache-2.0
// VolumeManager.swift — slet's node-local persistent-volume authority (SC8).
//
// The manager is the node's SOLE local authority for its volumes (SWIFTCUBE_DESIGN §7). It
// owns three things the milestone turns on, all host-testable without C6:
//
//   1. PROVISIONING + BINDING — create the datafs subtree for a `(app, ordinal)` volume and
//      record `/volumes/<id>` bound to THIS node. The scheduler reads that binding to PIN
//      the replica here thereafter (the sticky half of "node-local sticky").
//   2. SINGLE-WRITER FENCING — at most one live Cell generation may mount a volume at a
//      time. `acquire` (the reconciler's pre-create hook) is refused while a prior holder
//      is still mounted; `fence` (the supervisor's teardown hook) releases it. Because
//      there is no atomic kernel destroy-Cell op (CAPABILITIES §5.3), this serialization is
//      slet's duty — no overlap, ever (case 5).
//   3. FENCING TOKEN — a monotonic generation in the record, bumped on each (re)bind. A
//      mount presenting a STALE token is refused (case 6), so a partitioned controller that
//      rebinds the volume elsewhere cannot let two nodes write it.
//
// RETAIN: a routine teardown (`fence`) RETAINS the data (the default) — it only releases
// the mount, never deletes. Deletion is explicit (`delete`), so a reschedule/restart never
// loses data (SWIFTCUBE_DESIGN §7). QUOTA: datafs has no per-subtree quota, so `sizeBytes`
// is best-effort accounting recorded in the record, never enforced — surfaced honestly.
//
// Conforms to `VolumeFence` + `VolumeMounter` (CellSupervisor.swift) so the reconciler
// drives it through those seams. Foundation-free; the single-mount table is a small array
// (one entry per volume this node hosts), matching the Dictionary-free idiom of the loop.

/// The outcome of a low-level `mount`. A clean split so a caller (and a test) can tell a
/// single-writer conflict from a stale-token refusal from a provisioning gap.
enum VolumeMountResult: Equatable {
    case granted(token: UInt64)        // this Cell now holds the single writer
    case alreadyMounted(holder: String) // another live generation holds it (no overlap)
    case staleToken(current: UInt64)   // presented token < the record's — refused (fencing)
    case unbound                       // no /volumes/<id> binding for this node
    case ioError(reason: String)       // datafs refused the durable write
}

final class VolumeManager: VolumeFence, VolumeMounter {
    let node: String
    let store: StoreClient
    let datafs: VolumeStore

    /// The node-local single-writer table: at most one holder per volume. A volume absent
    /// here is unmounted (free for the next acquire). Small linear scans, like the loop.
    private struct Mount: Equatable { var volumeId: String; var cellId: String; var token: UInt64 }
    private var mounts: [Mount] = []

    /// Audit trail for the acceptance test: every (volumeId, granted?) the manager decided,
    /// so a test can assert that two writers were never simultaneously granted.
    private(set) var maxConcurrentByVolume: [(volumeId: String, peak: Int)] = []

    init(node: String, store: StoreClient, datafs: VolumeStore) {
        self.node = node; self.store = store; self.datafs = datafs
    }

    // MARK: - Record store helpers (read / CAS-write /volumes/<id>)

    func record(_ volumeId: String) -> VolumeRecord? {
        guard let e = store.get(VolumeKeys.volume(volumeId)) else { return nil }
        return VolumeRecord.decode(e.value)
    }

    /// Write `rec` to `/volumes/<id>`, CAS so a stale follower cannot clobber a fresher
    /// record. Read-then-CAS with one retry (the node is the sole authority, so contention
    /// is rare). Returns true on commit.
    @discardableResult
    private func putRecord(_ rec: VolumeRecord) -> Bool {
        let key = VolumeKeys.volume(rec.volumeId)
        let val = rec.encode()
        let cur = store.get(key)
        if store.putCAS(key: key, value: val, expect: cur?.modRevision) != nil { return true }
        // CAS miss: re-read and retry once against the latest revision.
        let again = store.get(key)
        return store.putCAS(key: key, value: val, expect: again?.modRevision) != nil
    }

    // MARK: - Provisioning + binding (case 1)

    /// Provision the datafs subtree for `(app, ordinal)` and bind the volume to THIS node,
    /// writing `/volumes/<id>`. Idempotent: re-binding our own volume re-attaches to the
    /// surviving subtree and KEEPS the fencing token; binding a volume currently recorded to
    /// ANOTHER node is a (re)bind that BUMPS the token (the partition/move path). Returns the
    /// committed record, or nil if datafs refused the subtree.
    @discardableResult
    func provisionAndBind(app: String, ordinal: UInt32, name: String, mountPath: String,
                          sizeBytes: UInt64 = 0, retain: RetainPolicy = .retain) -> VolumeRecord? {
        let volumeId = VolumeId.make(app: app, ordinal: ordinal)
        if case .failed(let why) = datafs.provision(volumeId: volumeId) {
            _ = why
            return nil
        }
        let path = datafs.path(volumeId: volumeId)

        if let existing = record(volumeId) {
            if existing.node == node {
                // Re-attach to our own binding: keep token + retain; refresh path/state.
                var rec = existing
                rec.path = path
                rec.state = (holderIndex(volumeId) != nil) ? .mounted : .bound
                putRecord(rec)
                return rec
            }
            // Rebind to this node: a new fencing generation invalidates the old holder.
            var rec = existing
            rec.node = node
            rec.path = path
            rec.fencingToken = existing.fencingToken &+ 1
            rec.state = .bound
            putRecord(rec)
            return rec
        }

        // First bind: token starts at 1, state bound, retain/size from the request.
        let rec = VolumeRecord(volumeId: volumeId, name: name, app: app, ordinal: ordinal,
                               node: node, path: path, sizeBytes: sizeBytes, mountPath: mountPath,
                               state: .bound, retain: retain, fencingToken: 1)
        putRecord(rec)
        return rec
    }

    // MARK: - Single-writer mount / unmount (cases 5, 6)

    /// Acquire the single writer for `volumeId` on behalf of `cellId`, presenting `token`.
    /// Refused if another generation already holds it (no overlap) or `token` is stale
    /// (< the record's fencing token). Idempotent for the same holder.
    @discardableResult
    func mount(volumeId: String, cellId: String, token: UInt64) -> VolumeMountResult {
        guard let rec = record(volumeId) else { return .unbound }
        // Single-writer: a different live holder blocks the mount entirely.
        if let i = holderIndex(volumeId) {
            if mounts[i].cellId == cellId { return .granted(token: mounts[i].token) }  // idempotent
            return .alreadyMounted(holder: mounts[i].cellId)
        }
        // Fencing token: a mount older than the current bind generation is refused.
        if token < rec.fencingToken { return .staleToken(current: rec.fencingToken) }
        guard datafs.exists(volumeId: volumeId) else { return .unbound }

        mounts.append(Mount(volumeId: volumeId, cellId: cellId, token: token))
        noteConcurrency(volumeId)
        var updated = rec; updated.state = .mounted; updated.fencingToken = token
        putRecord(updated)
        return .granted(token: token)
    }

    /// Release the single writer iff `cellId` is the current holder (idempotent otherwise).
    /// The record returns to `released` (data RETAINED) — never deleted on a routine path.
    func unmount(volumeId: String, cellId: String) {
        guard let i = holderIndex(volumeId), mounts[i].cellId == cellId else { return }
        mounts.remove(at: i)
        if var rec = record(volumeId) { rec.state = .released; putRecord(rec) }
    }

    // MARK: - VolumeMounter (the reconciler's pre-create hook)

    /// Provision-if-needed, bind-if-unbound, then acquire the single writer for the volume
    /// the given Cell owns. True ⇒ the Cell may be created; false ⇒ defer (held/stale).
    func acquire(cellId: String, volume: VolumeMount) -> Bool {
        guard let id = VolumeId.fromCellId(cellId) else {
            // A non-SwiftCube cellId: fall back to the manifest name as the id, unbound.
            return tryMount(volumeId: volume.name, cellId: cellId)
        }
        let volumeId = VolumeId.make(app: id.app, ordinal: id.ordinal)
        // Bind on first sight (retain-by-default; size is best-effort, datafs has no quota).
        if record(volumeId) == nil {
            _ = provisionAndBind(app: id.app, ordinal: id.ordinal, name: volume.name,
                                 mountPath: volume.mountPath, sizeBytes: volume.sizeBytes,
                                 retain: .retain)
        }
        return tryMount(volumeId: volumeId, cellId: cellId)
    }

    /// Mount with the record's CURRENT token (the live generation is never stale against
    /// itself); returns whether the single writer was granted.
    private func tryMount(volumeId: String, cellId: String) -> Bool {
        let tok = record(volumeId)?.fencingToken ?? 1
        if case .granted = mount(volumeId: volumeId, cellId: cellId, token: tok) { return true }
        return false
    }

    // MARK: - VolumeFence (the supervisor's teardown hook)

    /// Invoked by `destroy` BEFORE the Cell's volume handle is released: the old writer is
    /// gone, so release the single mount. RETAINS the data (routine teardown never deletes).
    func fence(cellId: String, volume: VolumeMount) {
        let volumeId = VolumeId.forCellId(cellId) ?? volume.name
        unmount(volumeId: volumeId, cellId: cellId)
    }

    // MARK: - Explicit delete (case 7)

    /// Explicitly remove a volume and its data (the `Delete` retain policy / an operator
    /// action). Refused while still mounted — a live writer must be fenced first. Returns
    /// true once the subtree is gone and the record tombstoned.
    @discardableResult
    func delete(volumeId: String) -> Bool {
        if holderIndex(volumeId) != nil { return false }   // never delete under a live writer
        if case .failed = datafs.remove(volumeId: volumeId) { return false }
        if var rec = record(volumeId) {
            rec.state = .deleted
            putRecord(rec)
        }
        return true
    }

    // MARK: - Introspection (tests / observability)

    func isMounted(_ volumeId: String) -> Bool { holderIndex(volumeId) != nil }
    func holder(_ volumeId: String) -> String? {
        guard let i = holderIndex(volumeId) else { return nil }
        return mounts[i].cellId
    }
    /// Peak simultaneous holders the manager ever granted for a volume (must stay ≤ 1).
    func peakConcurrency(_ volumeId: String) -> Int {
        for e in maxConcurrentByVolume where e.volumeId == volumeId { return e.peak }
        return 0
    }

    // MARK: - Helpers

    private func holderIndex(_ volumeId: String) -> Int? {
        for i in 0..<mounts.count where mounts[i].volumeId == volumeId { return i }
        return nil
    }
    private func noteConcurrency(_ volumeId: String) {
        let live = mounts.filter { $0.volumeId == volumeId }.count
        for i in 0..<maxConcurrentByVolume.count where maxConcurrentByVolume[i].volumeId == volumeId {
            if live > maxConcurrentByVolume[i].peak { maxConcurrentByVolume[i].peak = live }
            return
        }
        maxConcurrentByVolume.append((volumeId: volumeId, peak: live))
    }
}
