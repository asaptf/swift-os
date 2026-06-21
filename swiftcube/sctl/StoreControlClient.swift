// SPDX-License-Identifier: Apache-2.0
// StoreControlClient.swift — an in-process ControlClient over a cubestore (SC9a).
//
// This is the concrete `ControlClient` the SC9a acceptance test drives (the "fake control client")
// and the same client an embedded/single-node `sctl --local <statedir>` uses against an on-disk
// cubestore — it is a real client, not a stub: every call maps straight onto the store's
// MVCC/CAS primitives. Generic over the cubestore durability seams, so it runs over the SC2 RAM
// store in host tests and a datafs/POSIX-file-backed store unchanged. Foundation-free.

final class StoreControlClient<Log: AppendLog, Snap: SnapshotStore>: ControlClient {
    let store: CubeStore<Log, Snap>
    init(store: CubeStore<Log, Snap>) { self.store = store }

    func range(prefix: [UInt8]) -> [ControlKV] {
        store.prefix(prefix).map { ControlKV(key: $0.key, value: $0.value, modRevision: $0.modRevision) }
    }

    func get(_ key: [UInt8]) -> ControlKV? {
        guard let e = store.get(key) else { return nil }
        return ControlKV(key: e.key, value: e.value, modRevision: e.modRevision)
    }

    @discardableResult
    func put(_ key: [UInt8], _ value: [UInt8]) -> Revision {
        store.apply([.put(key: key, value: value)])
    }

    @discardableResult
    func casPut(_ key: [UInt8], _ value: [UInt8], expect: Revision?) -> Bool {
        let cond: Cond = expect == nil ? .keyAbsent(key: key) : .modRevisionEquals(key: key, expect!)
        return store.compareAndApply(conditions: [cond], [.put(key: key, value: value)]).committed
    }

    @discardableResult
    func delete(_ key: [UInt8]) -> Bool {
        let existed = store.get(key) != nil
        if existed { _ = store.apply([.delete(key: key)]) }
        return existed
    }
}
