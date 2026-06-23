// SPDX-License-Identifier: Apache-2.0
// Watch.swift — in-process watcher state, Foundation-free.
//
// A watcher is fully described by {range, fromRevision} and is resumable from
// its last delivered revision — the shape a network layer (SC2) wraps unchanged.
// Delivery is a synchronous callback at SC0; concurrency is the caller's concern.

/// Internal per-watcher state held by the store.
final class Watcher {
    let id: Int
    let start: Bytes
    let end: Bytes?              // exclusive upper bound; nil = open-ended
    /// Highest revision already delivered; the watcher resumes after it. Live
    /// events with modRevision > lastDelivered are sent next, in order.
    var lastDelivered: Revision
    var cancelled = false
    let callback: (Event) -> Void

    init(id: Int, start: Bytes, end: Bytes?, fromRevision: Revision, callback: @escaping (Event) -> Void) {
        self.id = id
        self.start = start
        self.end = end
        self.lastDelivered = fromRevision
        self.callback = callback
    }

    /// True if `key` falls in this watcher's half-open [start, end) range.
    func covers(_ key: Bytes) -> Bool {
        if compareBytes(key, start) < 0 { return false }
        if let end = end, compareBytes(key, end) >= 0 { return false }
        return true
    }

    /// Deliver one event, advancing the resume point. No-op once cancelled.
    func deliver(_ event: Event) {
        guard !cancelled else { return }
        callback(event)
        lastDelivered = event.modRevision
    }
}

/// Caller-held cancellation token. `cancel()` stops delivery and frees the
/// watcher's resources in the store; it is idempotent.
final class WatchHandle {
    private let _cancel: () -> Void
    private(set) var cancelled = false

    init(_ cancel: @escaping () -> Void) { self._cancel = cancel }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        _cancel()
    }
}
