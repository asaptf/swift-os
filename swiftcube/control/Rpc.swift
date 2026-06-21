// SPDX-License-Identifier: Apache-2.0
// Rpc.swift — the SC2 control RPC message set (payloads inside Wire frames).
//
// A request frame is: u8 opcode || body. A unary response frame is: u8 status ||
// body (status 0 = ok, else an error code). The watch RPC is not unary: its first
// response frame is a WatchReady header (or a Compacted error), then a sequence of
// WatchEvent frames stream until the watch is dropped. The agent tracks the last
// event's modRevision and, on reconnect, re-issues Watch(range, lastRevision) to
// resume with no gaps or duplicates — the wire form of SC0's watch semantics.
//
// All integers little-endian via cubestore ByteIO; identities are NOT carried in
// request bodies (they come from the authenticated mTLS client cert), so a node
// cannot spoof another's id. Foundation-free.

enum RpcOp: UInt8 {
    case join         = 1
    case registerNode = 2
    case heartbeat    = 3
    case watch        = 4
    case put          = 5
    case range        = 6
    case casPut       = 7   // SC3: compare-and-put for status reporting (don't clobber)
}

/// Response status codes (u8). 0 is success; the rest are typed failures the agent
/// can act on without parsing a string.
enum RpcStatus: UInt8 {
    case ok            = 0
    case badRequest    = 1
    case unauthorized  = 2   // mTLS ok but not permitted (e.g. register before join)
    case tokenRejected = 3
    case notFound      = 4
    case compacted     = 5
    case internalError = 6
}

// MARK: - Requests

struct JoinRequest: Equatable {
    var token: String        // "<id>.<secretHex>"
    var nodeName: String     // requested node identity (controller validates uniqueness)
    var csrDER: Bytes        // PKCS#10 CSR proving possession of the node key

    func encode() -> Bytes {
        var w = ByteWriter(); w.u8(RpcOp.join.rawValue)
        w.blob(Array(token.utf8)); w.blob(Array(nodeName.utf8)); w.blob(csrDER); return w.bytes
    }
    static func decodeBody(_ r: inout ByteReader) -> JoinRequest? {
        guard let t = r.blob(), let n = r.blob(), let csr = r.blob() else { return nil }
        return JoinRequest(token: String(decoding: t, as: UTF8.self),
                           nodeName: String(decoding: n, as: UTF8.self), csrDER: csr)
    }
}

struct RegisterNodeRequest: Equatable {
    var address: String      // advertised address (free-form for SC2)
    var ttlSeconds: UInt64   // requested lease TTL

    func encode() -> Bytes {
        var w = ByteWriter(); w.u8(RpcOp.registerNode.rawValue)
        w.blob(Array(address.utf8)); w.u64(ttlSeconds); return w.bytes
    }
    static func decodeBody(_ r: inout ByteReader) -> RegisterNodeRequest? {
        guard let a = r.blob(), let ttl = r.u64() else { return nil }
        return RegisterNodeRequest(address: String(decoding: a, as: UTF8.self), ttlSeconds: ttl)
    }
}

/// Heartbeat carries no body — the node is identified by its client cert.
struct HeartbeatRequest: Equatable {
    func encode() -> Bytes { var w = ByteWriter(); w.u8(RpcOp.heartbeat.rawValue); return w.bytes }
}

struct WatchRequest: Equatable {
    var start: Bytes
    var end: Bytes?          // nil = open upper bound
    var fromRevision: Revision

    func encode() -> Bytes {
        var w = ByteWriter(); w.u8(RpcOp.watch.rawValue)
        w.blob(start)
        if let e = end { w.u8(1); w.blob(e) } else { w.u8(0) }
        w.u64(fromRevision); return w.bytes
    }
    static func decodeBody(_ r: inout ByteReader) -> WatchRequest? {
        guard let s = r.blob(), let hasEnd = r.u8() else { return nil }
        var end: Bytes? = nil
        if hasEnd == 1 { guard let e = r.blob() else { return nil }; end = e }
        guard let from = r.u64() else { return nil }
        return WatchRequest(start: s, end: end, fromRevision: from)
    }
}

struct PutRequest: Equatable {
    var key: Bytes
    var value: Bytes
    func encode() -> Bytes {
        var w = ByteWriter(); w.u8(RpcOp.put.rawValue); w.blob(key); w.blob(value); return w.bytes
    }
    static func decodeBody(_ r: inout ByteReader) -> PutRequest? {
        guard let k = r.blob(), let v = r.blob() else { return nil }
        return PutRequest(key: k, value: v)
    }
}

/// Compare-and-put: write `key=value` iff the key's current modRevision matches the
/// expectation. `hasExpect == 0` means "key must be ABSENT" (create-only); otherwise
/// the key's modRevision must equal `expect`. This is the wire form of cubestore's
/// `compareAndApply` and backs SC3's "report status via CAS, don't clobber".
struct CasPutRequest: Equatable {
    var key: Bytes
    var value: Bytes
    var expect: Revision?     // nil = require absent
    func encode() -> Bytes {
        var w = ByteWriter(); w.u8(RpcOp.casPut.rawValue); w.blob(key); w.blob(value)
        if let e = expect { w.u8(1); w.u64(e) } else { w.u8(0) }
        return w.bytes
    }
    static func decodeBody(_ r: inout ByteReader) -> CasPutRequest? {
        guard let k = r.blob(), let v = r.blob(), let has = r.u8() else { return nil }
        var expect: Revision? = nil
        if has == 1 { guard let e = r.u64() else { return nil }; expect = e }
        return CasPutRequest(key: k, value: v, expect: expect)
    }
}

struct RangeRequest: Equatable {
    var start: Bytes
    var end: Bytes?
    func encode() -> Bytes {
        var w = ByteWriter(); w.u8(RpcOp.range.rawValue); w.blob(start)
        if let e = end { w.u8(1); w.blob(e) } else { w.u8(0) }
        return w.bytes
    }
    static func decodeBody(_ r: inout ByteReader) -> RangeRequest? {
        guard let s = r.blob(), let hasEnd = r.u8() else { return nil }
        var end: Bytes? = nil
        if hasEnd == 1 { guard let e = r.blob() else { return nil }; end = e }
        return RangeRequest(start: s, end: end)
    }
}

// MARK: - Responses (unary)

struct JoinResponse: Equatable {
    var certDER: Bytes
    var caCertDER: Bytes
    var nodeId: String
    func encode() -> Bytes {
        var w = ByteWriter(); w.u8(RpcStatus.ok.rawValue)
        w.blob(certDER); w.blob(caCertDER); w.blob(Array(nodeId.utf8)); return w.bytes
    }
    static func decodeBody(_ r: inout ByteReader) -> JoinResponse? {
        guard let c = r.blob(), let ca = r.blob(), let id = r.blob() else { return nil }
        return JoinResponse(certDER: c, caCertDER: ca, nodeId: String(decoding: id, as: UTF8.self))
    }
}

struct RegisterNodeResponse: Equatable {
    var revision: Revision
    var leaseExpiry: UInt64
    func encode() -> Bytes {
        var w = ByteWriter(); w.u8(RpcStatus.ok.rawValue); w.u64(revision); w.u64(leaseExpiry); return w.bytes
    }
    static func decodeBody(_ r: inout ByteReader) -> RegisterNodeResponse? {
        guard let rev = r.u64(), let exp = r.u64() else { return nil }
        return RegisterNodeResponse(revision: rev, leaseExpiry: exp)
    }
}

struct HeartbeatResponse: Equatable {
    var alive: Bool
    var expiry: UInt64
    func encode() -> Bytes {
        var w = ByteWriter(); w.u8(RpcStatus.ok.rawValue); w.u8(alive ? 1 : 0); w.u64(expiry); return w.bytes
    }
    static func decodeBody(_ r: inout ByteReader) -> HeartbeatResponse? {
        guard let a = r.u8(), let exp = r.u64() else { return nil }
        return HeartbeatResponse(alive: a != 0, expiry: exp)
    }
}

struct RangeResponse: Equatable {
    var entries: [(key: Bytes, value: Bytes, modRevision: Revision)]
    var revision: Revision
    func encode() -> Bytes {
        var w = ByteWriter(); w.u8(RpcStatus.ok.rawValue); w.u64(revision); w.u32(UInt32(entries.count))
        for e in entries { w.blob(e.key); w.blob(e.value); w.u64(e.modRevision) }
        return w.bytes
    }
    static func decodeBody(_ r: inout ByteReader) -> RangeResponse? {
        guard let rev = r.u64(), let n = r.u32() else { return nil }
        var out: [(key: Bytes, value: Bytes, modRevision: Revision)] = []
        var i: UInt32 = 0
        while i < n {
            guard let k = r.blob(), let v = r.blob(), let m = r.u64() else { return nil }
            out.append((k, v, m)); i += 1
        }
        return RangeResponse(entries: out, revision: rev)
    }

    static func equalEntries(_ a: RangeResponse, _ b: RangeResponse) -> Bool {
        if a.revision != b.revision || a.entries.count != b.entries.count { return false }
        for i in 0..<a.entries.count {
            if a.entries[i].key != b.entries[i].key || a.entries[i].value != b.entries[i].value
               || a.entries[i].modRevision != b.entries[i].modRevision { return false }
        }
        return true
    }
    static func == (a: RangeResponse, b: RangeResponse) -> Bool { equalEntries(a, b) }
}

struct PutResponse: Equatable {
    var revision: Revision
    func encode() -> Bytes { var w = ByteWriter(); w.u8(RpcStatus.ok.rawValue); w.u64(revision); return w.bytes }
    static func decodeBody(_ r: inout ByteReader) -> PutResponse? {
        guard let rev = r.u64() else { return nil }; return PutResponse(revision: rev)
    }
}

/// CAS-put outcome: whether the precondition held and the resulting revision. On a
/// committed write the key's modRevision equals `revision` (each batch bumps by 1).
struct CasPutResponse: Equatable {
    var committed: Bool
    var revision: Revision
    func encode() -> Bytes {
        var w = ByteWriter(); w.u8(RpcStatus.ok.rawValue); w.u8(committed ? 1 : 0); w.u64(revision); return w.bytes
    }
    static func decodeBody(_ r: inout ByteReader) -> CasPutResponse? {
        guard let c = r.u8(), let rev = r.u64() else { return nil }
        return CasPutResponse(committed: c != 0, revision: rev)
    }
}

/// A typed error response: u8 status (nonzero) || blob message.
struct ErrorResponse: Equatable {
    var status: RpcStatus
    var message: String
    func encode() -> Bytes {
        var w = ByteWriter(); w.u8(status.rawValue); w.blob(Array(message.utf8)); return w.bytes
    }
}

// MARK: - Watch stream framing

/// Watch stream control bytes (the first byte of each watch frame distinguishes a
/// header/event so the agent can demultiplex the stream).
enum WatchFrameKind: UInt8 {
    case ready      = 0   // header: the watch is established at `currentRevision`
    case put        = 1   // event
    case delete     = 2   // event
    case compacted  = 3   // header: fromRevision precedes the compaction floor
}

/// The header sent when a watch is established: the store's current revision, so
/// the agent knows the high-water mark it has caught up to.
struct WatchReady: Equatable {
    var currentRevision: Revision
    func encode() -> Bytes {
        var w = ByteWriter(); w.u8(WatchFrameKind.ready.rawValue); w.u64(currentRevision); return w.bytes
    }
}

/// One streamed change, in strict revision order (matches SC0 Event).
struct WatchEvent: Equatable {
    enum Kind: Equatable { case put(Bytes), delete }
    var kind: Kind
    var key: Bytes
    var modRevision: Revision

    func encode() -> Bytes {
        var w = ByteWriter()
        switch kind {
        case .put(let v): w.u8(WatchFrameKind.put.rawValue); w.blob(key); w.blob(v)
        case .delete:     w.u8(WatchFrameKind.delete.rawValue); w.blob(key)
        }
        w.u64(modRevision)
        return w.bytes
    }

    /// Build from a cubestore Event.
    static func from(_ e: Event) -> WatchEvent {
        switch e {
        case .put(let k, let v, let m): return WatchEvent(kind: .put(v), key: k, modRevision: m)
        case .delete(let k, let m):     return WatchEvent(kind: .delete, key: k, modRevision: m)
        }
    }
}

/// A decoded watch frame: either a header or an event.
enum WatchFrame: Equatable {
    case ready(Revision)
    case compacted(Revision)
    case event(WatchEvent)

    static func decode(_ payload: Bytes) -> WatchFrame? {
        var r = ByteReader(payload)
        guard let kind = r.u8(), let k = WatchFrameKind(rawValue: kind) else { return nil }
        switch k {
        case .ready:
            guard let rev = r.u64() else { return nil }; return .ready(rev)
        case .compacted:
            guard let rev = r.u64() else { return nil }; return .compacted(rev)
        case .put:
            guard let key = r.blob(), let v = r.blob(), let m = r.u64() else { return nil }
            return .event(WatchEvent(kind: .put(v), key: key, modRevision: m))
        case .delete:
            guard let key = r.blob(), let m = r.u64() else { return nil }
            return .event(WatchEvent(kind: .delete, key: key, modRevision: m))
        }
    }
}

/// A compacted header frame.
struct WatchCompacted {
    var compactedRevision: Revision
    func encode() -> Bytes {
        var w = ByteWriter(); w.u8(WatchFrameKind.compacted.rawValue); w.u64(compactedRevision); return w.bytes
    }
}
