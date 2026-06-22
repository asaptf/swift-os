// SPDX-License-Identifier: Apache-2.0
// Node.swift — the Node object the agent registers on join (SC2).
//
// A Node is observed cluster state: it appears under /nodes/<id> on a successful
// join+register and disappears when the node's lease expires. SC2 kept it minimal
// (id, status, the lease it is bound to, an advertised address, the revision it
// registered at); SC4 grows it with the two fields the scheduler needs — schedulable
// `capacity` (cpu/mem) and `labels` for nodeSelector matching. The record is
// versioned: a v1 record (SC2 on the wire) decodes with zero capacity and no labels.
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
    // SC4 capacity the scheduler fits against. Kept as scalars (not the cell layer's
    // `ResourceLimits`) so the control layer stays free of a cell-layer dependency; the
    // scheduler lifts these into a `ResourceLimits` view.
    var capacityCpuMillis: UInt32  // total schedulable milli-cpu
    var capacityMemBytes: UInt64   // total schedulable memory
    var labels: [String]           // "key=value" entries matched by a Deployment nodeSelector

    /// `capacity`/`labels` default to empty so SC2 call sites — and a decoded v1 record —
    /// keep working unchanged (a node that never advertised capacity simply fits nothing).
    init(id: String, status: NodeStatus, leaseId: String, address: String,
         registeredRev: Revision,
         capacityCpuMillis: UInt32 = 0, capacityMemBytes: UInt64 = 0,
         labels: [String] = []) {
        self.id = id; self.status = status; self.leaseId = leaseId; self.address = address
        self.registeredRev = registeredRev
        self.capacityCpuMillis = capacityCpuMillis; self.capacityMemBytes = capacityMemBytes
        self.labels = labels
    }

    func encode() -> Bytes {
        var w = ByteWriter()
        w.u8(2)                                    // record version (2: adds capacity + labels)
        w.blob(Array(id.utf8))
        w.u8(status.rawValue)
        w.blob(Array(leaseId.utf8))
        w.blob(Array(address.utf8))
        w.u64(registeredRev)
        w.u32(capacityCpuMillis)
        w.u64(capacityMemBytes)
        w.u32(UInt32(labels.count))
        for l in labels { w.blob(Array(l.utf8)) }
        return w.bytes
    }

    static func decode(_ bytes: Bytes) -> NodeRecord? {
        var r = ByteReader(bytes)
        guard let ver = r.u8(), ver == 1 || ver == 2,
              let idB = r.blob(),
              let st = r.u8(), let status = NodeStatus(rawValue: st),
              let leaseB = r.blob(),
              let addrB = r.blob(),
              let rev = r.u64() else { return nil }
        var cpu: UInt32 = 0
        var mem: UInt64 = 0
        var labels: [String] = []
        if ver >= 2 {
            guard let c = r.u32(), let m = r.u64(), let n = r.u32() else { return nil }
            cpu = c; mem = m
            var i: UInt32 = 0
            while i < n { guard let b = r.blob() else { return nil }; labels.append(String(decoding: b, as: UTF8.self)); i += 1 }
        }
        return NodeRecord(id: String(decoding: idB, as: UTF8.self),
                          status: status,
                          leaseId: String(decoding: leaseB, as: UTF8.self),
                          address: String(decoding: addrB, as: UTF8.self),
                          registeredRev: rev,
                          capacityCpuMillis: cpu, capacityMemBytes: mem, labels: labels)
    }
}
