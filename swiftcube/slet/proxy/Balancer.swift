// SPDX-License-Identifier: Apache-2.0
// Balancer.swift — the node-proxy's L4 load-balancing policy (SC7).
//
// Given a service's READY endpoints (from /endpoints/<service>) and a per-service round-robin
// cursor, produce the ORDER in which the proxy should try them for one connection. The first
// is the primary pick; the rest are the failover order (dial-failover walks them when a backend
// connect fails). Properties:
//
//   • round-robin: successive connections start at successive endpoints, so load spreads evenly
//     across all ready backends (a per-service cursor, advanced once per connection).
//   • locality preference (optional seam): if a same-node endpoint exists it is tried first, to
//     cut a hop. Off by default (open east-west; the spread test wants pure round-robin).
//   • session affinity (optional): a non-empty client key sticks to one backend within the
//     window — the key hashes to a stable index into the CURRENT ready set, so repeated
//     connections from the same client reuse one backend as long as it stays ready.
//
// The endpoint set is kept sorted by Endpoint.less (as the endpoints loop writes it), so the
// cursor and the affinity hash are stable across passes. Pure value logic — no I/O, Foundation-
// free, tested directly.

struct BalancerConfig: Equatable {
    var preferLocalNode: String = ""   // non-empty ⇒ try a same-node endpoint first (locality seam)
    var affinity: Bool = false         // non-empty client key sticks to one backend
}

struct Balancer {
    var cfg: BalancerConfig
    init(_ cfg: BalancerConfig = BalancerConfig()) { self.cfg = cfg }

    /// The try-order for one connection over `ready` (assumed sorted by Endpoint.less). `cursor`
    /// is the per-service round-robin cursor; it is advanced by one (returned in `nextCursor`)
    /// only for a non-affinity pick. `affinityKey` empty ⇒ round-robin.
    func order(ready: [Endpoint], cursor: UInt64, affinityKey: String = "")
        -> (order: [Endpoint], nextCursor: UInt64) {
        let n = ready.count
        if n == 0 { return ([], cursor) }

        // Affinity: a stable hash of the key selects the primary; failover continues round-robin
        // from there. The cursor is NOT advanced (affinity is independent of round-robin).
        if cfg.affinity && !affinityKey.isEmpty {
            let start = Int(hash(affinityKey) % UInt64(n))
            return (rotate(ready, start: localityAdjust(ready, start)), cursor)
        }

        // Round-robin: start at the cursor, advance it by one for the next connection.
        let start = Int(cursor % UInt64(n))
        return (rotate(ready, start: localityAdjust(ready, start)), cursor &+ 1)
    }

    /// If locality preference is on and a same-node endpoint exists, move it to the front of the
    /// try-order (its index becomes the new start). Otherwise the proposed start stands.
    private func localityAdjust(_ ready: [Endpoint], _ start: Int) -> Int {
        guard !cfg.preferLocalNode.isEmpty else { return start }
        for i in 0..<ready.count where endpointNode(ready[i]) == cfg.preferLocalNode { return i }
        return start
    }

    /// Endpoints don't carry their node directly; the cellId is `<app>--r..-s..-g..` and the
    /// node isn't encoded there, so locality uses the address as the node identity (a same proxy
    /// node shares the backend's reachable address host). This is a coarse seam; a real node tag
    /// on the endpoint is the follow-on. Returns the address as the locality key.
    private func endpointNode(_ e: Endpoint) -> String { e.address }

    /// Rotate `xs` so element `start` is first, preserving relative order (the failover ring).
    private func rotate(_ xs: [Endpoint], start: Int) -> [Endpoint] {
        if start == 0 { return xs }
        var out: [Endpoint] = []; out.reserveCapacity(xs.count)
        for i in 0..<xs.count { out.append(xs[(start + i) % xs.count]) }
        return out
    }

    /// FNV-1a over the key bytes — a stable, Foundation-free hash for affinity.
    private func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }
}
