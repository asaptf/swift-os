// SPDX-License-Identifier: Apache-2.0
// Endpoint.swift — the SC5 endpoints object + key schema for the ready-only endpoints loop.
//
// The endpoints loop (EndpointsLoop.swift) is the controller-side reconciler that turns the
// Cell statuses `slet` reports into the routable backend set SC6 (LB) and SC7 (east-west)
// consume. It introduces one object family into the cubestore schema (SC2 owns /nodes,
// /leases,/tokens; SC3 owns /assignments,/status/cells; SC4 owns /apps,/pending):
//
//   /endpoints/<service>  — OBSERVED: the set of ready, reachable endpoints backing one
//                           service, written by the leader endpoints loop. The KEY input
//                           SC6/SC7 read. Level-triggered: it is rebuilt every pass from
//                           the actual ready Cells, so it converges and never churns on a
//                           reconnect/restart.
//
// An `Endpoint` is `{cellId, address, port}` — the Cell's cluster identity plus the
// reachable address `slet` reported in its status (SC7 fills the real node-IP+mapped-port).
// An `EndpointSet` is the deterministic, sorted set for one service, so equal inputs encode
// to byte-identical values and the CAS write is skipped when nothing changed. Foundation-
// free; little-endian ByteIO, like every other cubestore record.

// MARK: - Key schema

enum EndpointKeys {
    static let endpointsPrefix: Bytes = Array("/endpoints/".utf8)

    /// `/endpoints/<service>` — the endpoint set for one service.
    static func endpoints(_ service: String) -> Bytes {
        endpointsPrefix + Array(service.utf8)
    }

    /// The service name from an `/endpoints/<service>` key, or nil if not in that range.
    static func service(ofKey key: Bytes) -> String? {
        let pfx = endpointsPrefix
        guard key.count > pfx.count else { return nil }
        for i in 0..<pfx.count where key[i] != pfx[i] { return nil }
        return String(decoding: key[pfx.count...], as: UTF8.self)
    }
}

// MARK: - Endpoint (one ready backend)

struct Endpoint: Equatable {
    var cellId: String
    var address: String
    var port: UInt16

    func encode(into w: inout ByteWriter) {
        w.blob(Array(cellId.utf8)); w.blob(Array(address.utf8)); w.u32(UInt32(port))
    }
    static func decode(_ r: inout ByteReader) -> Endpoint? {
        guard let cidB = r.blob(), let addrB = r.blob(), let p = r.u32() else { return nil }
        return Endpoint(cellId: String(decoding: cidB, as: UTF8.self),
                        address: String(decoding: addrB, as: UTF8.self),
                        port: UInt16(truncatingIfNeeded: p))
    }

    /// Total order for deterministic output: by cellId, then address, then port.
    static func less(_ a: Endpoint, _ b: Endpoint) -> Bool {
        if a.cellId != b.cellId { return a.cellId < b.cellId }
        if a.address != b.address { return a.address < b.address }
        return a.port < b.port
    }
}

// MARK: - EndpointSet (the value at /endpoints/<service>)

struct EndpointSet: Equatable {
    var service: String
    var endpoints: [Endpoint]   // kept sorted by Endpoint.less for deterministic encoding

    func encode() -> Bytes {
        var w = ByteWriter()
        w.u8(1)                          // record version
        w.blob(Array(service.utf8))
        w.u32(UInt32(endpoints.count))
        for e in endpoints { e.encode(into: &w) }
        return w.bytes
    }

    static func decode(_ bytes: Bytes) -> EndpointSet? {
        var r = ByteReader(bytes)
        guard let ver = r.u8(), ver == 1, let svcB = r.blob(), let n = r.u32() else { return nil }
        var eps: [Endpoint] = []; eps.reserveCapacity(Int(n))
        var i: UInt32 = 0
        while i < n { guard let e = Endpoint.decode(&r) else { return nil }; eps.append(e); i += 1 }
        return EndpointSet(service: String(decoding: svcB, as: UTF8.self), endpoints: eps)
    }
}
