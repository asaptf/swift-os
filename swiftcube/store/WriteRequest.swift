// SPDX-License-Identifier: Apache-2.0
// WriteRequest.swift — the replicated write command, Foundation-free.
//
// SC1b. A cubestore write no longer applies directly: the client's request is
// encoded into a Raft `.normal` entry, replicated to a quorum, and applied — in
// log order, identically on every node — only after commit. The general form is a
// compare-and-apply: `{conditions, ops}`. A plain batch is just a CAS with no
// conditions (it always commits). Evaluating the conditions *at apply time*
// against the applied state makes the accept/reject verdict deterministic across
// the cluster (every node applies the same entries in the same order), so the
// leader can report the single agreed outcome to the client.
//
// Encoding (little-endian, reusing cubestore's ByteIO; no text):
//   u32 condCount | cond*
//   u32 opCount   | op*
//   cond : u8 kind | blob key | [u64 revision]      (revision only for modRevision*)
//          kinds: 0 keyExists, 1 keyAbsent, 2 ==, 3 <, 4 >
//   op   : u8 kind(0=put,1=delete) | blob key | [blob value]   (value only for put)

struct WriteRequest: Equatable {
    var conditions: [Cond]
    var ops: [Op]

    init(conditions: [Cond] = [], ops: [Op]) {
        self.conditions = conditions
        self.ops = ops
    }
}

enum WriteRequestCodec {
    static func encode(_ req: WriteRequest) -> Bytes {
        var w = ByteWriter()
        w.u32(UInt32(req.conditions.count))
        for c in req.conditions { encodeCond(&w, c) }
        w.u32(UInt32(req.ops.count))
        for op in req.ops { encodeOp(&w, op) }
        return w.bytes
    }

    static func decode(_ bytes: Bytes) -> WriteRequest? {
        var r = ByteReader(bytes)
        guard let condCount = r.u32() else { return nil }
        var conds: [Cond] = []
        var i: UInt32 = 0
        while i < condCount { guard let c = decodeCond(&r) else { return nil }; conds.append(c); i += 1 }
        guard let opCount = r.u32() else { return nil }
        var ops: [Op] = []
        i = 0
        while i < opCount { guard let op = decodeOp(&r) else { return nil }; ops.append(op); i += 1 }
        return WriteRequest(conditions: conds, ops: ops)
    }

    private static func encodeCond(_ w: inout ByteWriter, _ c: Cond) {
        switch c {
        case .keyExists(let k):              w.u8(0); w.blob(k)
        case .keyAbsent(let k):              w.u8(1); w.blob(k)
        case .modRevisionEquals(let k, let v):  w.u8(2); w.blob(k); w.u64(v)
        case .modRevisionLess(let k, let v):    w.u8(3); w.blob(k); w.u64(v)
        case .modRevisionGreater(let k, let v): w.u8(4); w.blob(k); w.u64(v)
        }
    }

    private static func decodeCond(_ r: inout ByteReader) -> Cond? {
        guard let kind = r.u8(), let key = r.blob() else { return nil }
        switch kind {
        case 0: return .keyExists(key: key)
        case 1: return .keyAbsent(key: key)
        case 2: guard let v = r.u64() else { return nil }; return .modRevisionEquals(key: key, v)
        case 3: guard let v = r.u64() else { return nil }; return .modRevisionLess(key: key, v)
        case 4: guard let v = r.u64() else { return nil }; return .modRevisionGreater(key: key, v)
        default: return nil
        }
    }

    private static func encodeOp(_ w: inout ByteWriter, _ op: Op) {
        switch op {
        case .put(let k, let v): w.u8(0); w.blob(k); w.blob(v)
        case .delete(let k):     w.u8(1); w.blob(k)
        }
    }

    private static func decodeOp(_ r: inout ByteReader) -> Op? {
        guard let kind = r.u8(), let key = r.blob() else { return nil }
        switch kind {
        case 0: guard let v = r.blob() else { return nil }; return .put(key: key, value: v)
        case 1: return .delete(key: key)
        default: return nil
        }
    }
}
