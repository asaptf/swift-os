// SPDX-License-Identifier: Apache-2.0
// Node.swift — the Node object the agent registers on join (SC2).
//
// A Node is observed cluster state: it appears under /nodes/<id> on a successful
// join+register and disappears when the node's lease expires. SC2 keeps it
// minimal (id, status, the lease it is bound to, an advertised address, the
// revision it registered at); SC3+ will grow it with capacity/labels/conditions.
// Serialized with cubestore's little-endian ByteIO — no text, no Foundation.

enum NodeStatus: UInt8 {
    case joining = 0
    case ready   = 1
}

struct NodeRecord: Equatable {
    var id: String
    var status: NodeStatus
    var leaseId: String
    var address: String        // advertised host:port or ip:port (free-form for SC2)
    var registeredRev: Revision

    func encode() -> Bytes {
        var w = ByteWriter()
        w.u8(1)                                    // record version
        w.blob(Array(id.utf8))
        w.u8(status.rawValue)
        w.blob(Array(leaseId.utf8))
        w.blob(Array(address.utf8))
        w.u64(registeredRev)
        return w.bytes
    }

    static func decode(_ bytes: Bytes) -> NodeRecord? {
        var r = ByteReader(bytes)
        guard let ver = r.u8(), ver == 1,
              let idB = r.blob(),
              let st = r.u8(), let status = NodeStatus(rawValue: st),
              let leaseB = r.blob(),
              let addrB = r.blob(),
              let rev = r.u64() else { return nil }
        return NodeRecord(id: String(decoding: idB, as: UTF8.self),
                          status: status,
                          leaseId: String(decoding: leaseB, as: UTF8.self),
                          address: String(decoding: addrB, as: UTF8.self),
                          registeredRev: rev)
    }
}
