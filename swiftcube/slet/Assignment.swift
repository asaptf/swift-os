// SPDX-License-Identifier: Apache-2.0
// Assignment.swift — SC3 desired/observed objects + key schema for the reconcile loop.
//
// SC3 adds two object families to the cubestore schema (SC2 owns /nodes, /leases,
// /tokens):
//
//   /assignments/<node>/<cellId>  — DESIRED: one instance placed on a node. Written by
//                                    the scheduler (SC4, out of scope here — SC3 only
//                                    consumes them); each `slet` watches the subtree for
//                                    its own node and drives a Cell to match.
//   /status/cells/<cellId>        — OBSERVED: the Cell's reported status, written by the
//                                    owning `slet` via CAS (don't clobber). This closes
//                                    the loop for SC4 (placement) and SC5 (readiness)
//                                    to read.
//
// An `Assignment` carries a generation (bumped by the scheduler on a meaningful change)
// plus the full `CellSpec`, so a reconciler can both detect drift (spec changed) and
// roll a deliberate update (generation changed). Foundation-free; little-endian ByteIO,
// like every other cubestore record.

// MARK: - Key schema

enum SletKeys {
    static let assignmentsPrefix: Bytes = Array("/assignments/".utf8)
    static let statusCellsPrefix:  Bytes = Array("/status/cells/".utf8)

    /// The watch/range prefix for one node's assignments: `/assignments/<node>/`.
    static func nodeAssignmentsPrefix(_ node: String) -> Bytes {
        assignmentsPrefix + Array(node.utf8) + Array("/".utf8)
    }

    static func assignment(node: String, cellId: String) -> Bytes {
        nodeAssignmentsPrefix(node) + Array(cellId.utf8)
    }

    static func status(_ cellId: String) -> Bytes {
        statusCellsPrefix + Array(cellId.utf8)
    }

    /// Extract the cellId from an assignment key under a node's prefix, or nil if the
    /// key is not in that range.
    static func cellId(ofAssignmentKey key: Bytes, node: String) -> String? {
        let pfx = nodeAssignmentsPrefix(node)
        guard key.count > pfx.count else { return nil }
        for i in 0..<pfx.count where key[i] != pfx[i] { return nil }
        return String(decoding: key[pfx.count...], as: UTF8.self)
    }
}

// MARK: - Assignment (desired state)

struct Assignment: Equatable {
    var generation: UInt64     // bumped by the scheduler to force a deliberate roll
    var spec: CellSpec

    func encode() -> Bytes {
        var w = ByteWriter()
        w.u8(1)                 // record version
        w.u64(generation)
        spec.encode(into: &w)
        return w.bytes
    }

    static func decode(_ bytes: Bytes) -> Assignment? {
        var r = ByteReader(bytes)
        guard let ver = r.u8(), ver == 1, let gen = r.u64(), let spec = CellSpec.decode(&r) else { return nil }
        return Assignment(generation: gen, spec: spec)
    }
}

// MARK: - CellStatusRecord (observed state)

struct CellStatusRecord: Equatable {
    var cellId: String
    var node: String
    var phase: CellPhase
    var ready: Bool
    var restartCount: UInt32
    var imageDigest: [UInt8]      // 32-byte content address of the running base
    var startedAtSeconds: UInt64  // when the current generation launched (0 if none)
    var message: String           // human-readable reason (e.g. image rejection)

    func encode() -> Bytes {
        var w = ByteWriter()
        w.u8(1)                  // record version
        w.blob(Array(cellId.utf8))
        w.blob(Array(node.utf8))
        Self.encodePhase(phase, into: &w)
        w.u8(ready ? 1 : 0)
        w.u32(restartCount)
        w.blob(imageDigest)
        w.u64(startedAtSeconds)
        w.blob(Array(message.utf8))
        return w.bytes
    }

    static func decode(_ bytes: Bytes) -> CellStatusRecord? {
        var r = ByteReader(bytes)
        guard let ver = r.u8(), ver == 1, let cidB = r.blob(), let nodeB = r.blob(),
              let phase = decodePhase(&r), let readyB = r.u8(), let rc = r.u32(),
              let dig = r.blob(), let started = r.u64(), let msgB = r.blob() else { return nil }
        return CellStatusRecord(cellId: String(decoding: cidB, as: UTF8.self),
                                node: String(decoding: nodeB, as: UTF8.self),
                                phase: phase, ready: readyB != 0, restartCount: rc,
                                imageDigest: dig, startedAtSeconds: started,
                                message: String(decoding: msgB, as: UTF8.self))
    }

    // Phase wire form: u8 tag (+ i32 exit code for .dead).
    static func encodePhase(_ p: CellPhase, into w: inout ByteWriter) {
        switch p {
        case .created:            w.u8(0)
        case .running:            w.u8(1)
        case .stopping:           w.u8(2)
        case .dead(let code):     w.u8(3); w.u32(UInt32(bitPattern: code))
        case .failed:             w.u8(4)
        }
    }
    static func decodePhase(_ r: inout ByteReader) -> CellPhase? {
        guard let tag = r.u8() else { return nil }
        switch tag {
        case 0: return .created
        case 1: return .running
        case 2: return .stopping
        case 3: guard let c = r.u32() else { return nil }; return .dead(exitCode: Int32(bitPattern: c))
        case 4: return .failed
        default: return nil
        }
    }
}
