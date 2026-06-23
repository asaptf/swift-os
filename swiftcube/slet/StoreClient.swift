// SPDX-License-Identifier: Apache-2.0
// StoreClient.swift — the reconcile loop's view of cubestore, and its two bindings (SC3).
//
// The reconciler (Reconciler.swift) talks to cubestore through this narrow seam:
// range its assignments, CAS-write its statuses, and watch its assignment subtree for
// wakeups. Two implementations sit behind it:
//
//   • LocalStoreClient — an in-process CubeStore, used by the deterministic host
//     acceptance tests. No transport, no clock; exercises the full reconcile logic
//     (create/destroy/CAS/drift/idempotency/restart/policy/image) directly.
//   • AgentStoreClient — the production binding: the SC2 `Agent` over mTLS, using the
//     range/casPut RPCs and the resumable watch. Used by the reconnect case (8) to
//     prove the loop runs over the real SC2 control API and survives an mTLS reconnect
//     without churning healthy Cells.
//
// The reconciler is identical over both. Class-bound (`AnyObject`) for a single
// existential under Embedded Swift, like the other SwiftCube seams. Foundation-free.

protocol StoreClient: AnyObject {
    /// Live entries under `prefix`, each with its modRevision, in key order.
    func list(prefix: Bytes) -> [(key: Bytes, value: Bytes, modRevision: Revision)]

    /// The single live entry at `key`, or nil if absent.
    func get(_ key: Bytes) -> (value: Bytes, modRevision: Revision)?

    /// Compare-and-put: write iff the key's modRevision matches `expect` (`nil` ⇒
    /// require absent). Returns the new revision on success (== the key's new
    /// modRevision), or nil if the precondition failed.
    func putCAS(key: Bytes, value: Bytes, expect: Revision?) -> Revision?

    /// (Re)establish the assignment watch from `from`. On reconnect the reconciler
    /// calls this with its resume cursor.
    func startWatch(prefix: Bytes, from: Revision)

    /// Drain any watch events delivered since the last poll (wakeups for the loop).
    func poll() -> [WatchEvent]
}

// MARK: - In-process binding (host tests)

/// Drives the reconciler against a CubeStore directly — deterministic, no transport.
final class LocalStoreClient: StoreClient {
    let store: CubeStore<RamLog, RamSnapshot>
    private var pending: [WatchEvent] = []
    private var handle: WatchHandle?

    init(_ store: CubeStore<RamLog, RamSnapshot>) { self.store = store }

    func list(prefix: Bytes) -> [(key: Bytes, value: Bytes, modRevision: Revision)] {
        store.prefix(prefix).map { (key: $0.key, value: $0.value, modRevision: $0.modRevision) }
    }

    func get(_ key: Bytes) -> (value: Bytes, modRevision: Revision)? {
        guard let e = store.get(key) else { return nil }
        return (value: e.value, modRevision: e.modRevision)
    }

    func putCAS(key: Bytes, value: Bytes, expect: Revision?) -> Revision? {
        let cond: Cond = expect == nil ? .keyAbsent(key: key) : .modRevisionEquals(key: key, expect!)
        let r = store.compareAndApply(conditions: [cond], [.put(key: key, value: value)])
        return r.committed ? r.revision : nil
    }

    func startWatch(prefix: Bytes, from: Revision) {
        pending.removeAll(keepingCapacity: true)
        handle = try? store.watchRange(prefix, prefixEnd(prefix), fromRevision: from) { [unowned(unsafe) self] ev in
            self.pending.append(WatchEvent.from(ev))
        }
    }

    func poll() -> [WatchEvent] {
        let e = pending; pending.removeAll(keepingCapacity: true); return e
    }
}

// MARK: - Agent binding (production / mTLS reconnect)

/// Drives the reconciler over the SC2 `Agent` and the mTLS control API. Transport is
/// supplied as two channel-opening closures so the same client wraps a host loopback
/// (in the reconnect test) and a real TCP fd on-device. `openUnary` yields a fresh
/// mTLS channel + its pump for one unary RPC (range/casPut/get); `openWatch` yields the
/// long-lived watch channel (re-opened on reconnect).
final class AgentStoreClient: StoreClient {
    let agent: Agent
    let openUnary: () -> (channel: TLSChannel, pump: () -> Void)?
    let openWatch: () -> (channel: TLSChannel, pump: () -> Void)?

    private var watchChannel: TLSChannel?
    private var watchPump: (() -> Void)?

    init(agent: Agent,
         openUnary: @escaping () -> (channel: TLSChannel, pump: () -> Void)?,
         openWatch: @escaping () -> (channel: TLSChannel, pump: () -> Void)?) {
        self.agent = agent; self.openUnary = openUnary; self.openWatch = openWatch
    }

    func list(prefix: Bytes) -> [(key: Bytes, value: Bytes, modRevision: Revision)] {
        guard let c = openUnary(),
              let resp = agent.range(channel: c.channel, start: prefix, end: prefixEnd(prefix), c.pump) else { return [] }
        return resp.entries
    }

    func get(_ key: Bytes) -> (value: Bytes, modRevision: Revision)? {
        guard let c = openUnary(),
              let resp = agent.range(channel: c.channel, start: key, end: prefixEnd(key), c.pump) else { return nil }
        for e in resp.entries where e.key == key { return (value: e.value, modRevision: e.modRevision) }
        return nil
    }

    func putCAS(key: Bytes, value: Bytes, expect: Revision?) -> Revision? {
        guard let c = openUnary(),
              let resp = agent.casPut(channel: c.channel, key: key, value: value, expect: expect, c.pump) else { return nil }
        return resp.committed ? resp.revision : nil
    }

    func startWatch(prefix: Bytes, from: Revision) {
        guard let c = openWatch() else { watchChannel = nil; watchPump = nil; return }
        watchChannel = c.channel; watchPump = c.pump
        _ = agent.startWatch(channel: c.channel, start: prefix, end: prefixEnd(prefix), from: from, c.pump)
    }

    func poll() -> [WatchEvent] {
        guard let ch = watchChannel, let pump = watchPump else { return [] }
        pump()
        return agent.drainWatchEvents(channel: ch)
    }
}
