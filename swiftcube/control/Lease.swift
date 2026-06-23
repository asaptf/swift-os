// SPDX-License-Identifier: Apache-2.0
// Lease.swift — TTL liveness leases + the leader-gated reaper (SC2).
//
// A lease is a TTL-bound liveness token keyed to a node (etcd's lease model, kept
// minimal). Stored at /leases/<id> it carries an absolute `expiry` (clock
// seconds) and the list of keys "attached" to it — for SC2 that is the node's own
// /nodes/<id> key. A heartbeat renews the lease by CAS-extending its expiry; when
// the lease expires, the reaper deletes the lease *and* every attached key in one
// atomic batch, which fans a delete event out to watchers.
//
// Built on SC1's compareAndApply so renewals and reaps are race-free: a renew
// only commits if the lease still exists at the revision the renewer read, and
// the reaper only deletes a lease it still observes as expired. The reaper is
// LEADER-GATED (a single actor) so that, once multiple controllers exist
// (SC2b/Raft), exactly one performs reaping — trivially correct with one
// controller today. Foundation-free; times come from the injected CubeClock.

struct LeaseRecord: Equatable {
    var ttlSeconds: UInt64
    var expiry: UInt64              // clock seconds; lease is dead once now > expiry
    var attachedKeys: [Bytes]       // keys deleted with the lease on expiry

    func encode() -> Bytes {
        var w = ByteWriter()
        w.u8(1)
        w.u64(ttlSeconds)
        w.u64(expiry)
        w.u32(UInt32(attachedKeys.count))
        for k in attachedKeys { w.blob(k) }
        return w.bytes
    }

    static func decode(_ bytes: Bytes) -> LeaseRecord? {
        var r = ByteReader(bytes)
        guard let ver = r.u8(), ver == 1,
              let ttl = r.u64(), let exp = r.u64(), let n = r.u32() else { return nil }
        var keys: [Bytes] = []
        var i: UInt32 = 0
        while i < n { guard let k = r.blob() else { return nil }; keys.append(k); i += 1 }
        return LeaseRecord(ttlSeconds: ttl, expiry: exp, attachedKeys: keys)
    }
}

/// Manages lease grant/renew and the expiry reaper over cubestore.
struct LeaseManager<Log: AppendLog, Snap: SnapshotStore> {
    let store: CubeStore<Log, Snap>
    let clock: CubeClock

    /// Grant (or replace) a lease for `id` with `ttlSeconds`, attaching `keys`.
    /// Returns the lease's expiry. This is the write that, together with the node
    /// put, makes a node "appear".
    @discardableResult
    func grant(id: String, ttlSeconds: UInt64, attachedKeys: [Bytes]) -> UInt64 {
        let expiry = clock.nowSeconds() &+ ttlSeconds
        let rec = LeaseRecord(ttlSeconds: ttlSeconds, expiry: expiry, attachedKeys: attachedKeys)
        store.apply([.put(key: CubeKeys.lease(id), value: rec.encode())])
        return expiry
    }

    /// Renew a lease (heartbeat): CAS-extend its expiry to now+ttl. Fails if the
    /// lease no longer exists (already reaped) or was concurrently modified.
    /// Returns the new expiry on success, nil on failure.
    @discardableResult
    func renew(id: String) -> UInt64? {
        let key = CubeKeys.lease(id)
        guard let entry = store.get(key), var rec = LeaseRecord.decode(entry.value) else { return nil }
        rec.expiry = clock.nowSeconds() &+ rec.ttlSeconds
        let res = store.compareAndApply(conditions: [.modRevisionEquals(key: key, entry.modRevision)],
                                        [.put(key: key, value: rec.encode())])
        return res.committed ? rec.expiry : nil
    }

    /// Whether a lease currently exists and is unexpired.
    func isAlive(id: String) -> Bool {
        guard let entry = store.get(CubeKeys.lease(id)), let rec = LeaseRecord.decode(entry.value)
        else { return false }
        return clock.nowSeconds() <= rec.expiry
    }

    /// One reaper pass: delete every expired lease and its attached keys. Returns
    /// the lease ids reaped. LEADER-GATED by the caller (Controller) — do not call
    /// from a follower. Each lease is removed under a CAS on its modRevision, so a
    /// renewal that landed since the scan wins and the lease survives.
    @discardableResult
    func reapExpired() -> [String] {
        let now = clock.nowSeconds()
        var reaped: [String] = []
        for entry in store.prefix(CubeKeys.leasesPrefix) {
            guard let rec = LeaseRecord.decode(entry.value) else { continue }
            if now <= rec.expiry { continue }                  // still alive
            guard let id = CubeKeys.suffix(entry.key, under: CubeKeys.leasesPrefix) else { continue }
            var batch: [Op] = [.delete(key: entry.key)]
            for k in rec.attachedKeys { batch.append(.delete(key: k)) }
            let res = store.compareAndApply(
                conditions: [.modRevisionEquals(key: entry.key, entry.modRevision)], batch)
            if res.committed { reaped.append(id) }
        }
        return reaped
    }
}
