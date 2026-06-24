// SPDX-License-Identifier: Apache-2.0
// Volume.swift — the SC8 persistent-volume object, key schema, and (app,ordinal) id.
//
// SC8 adds node-local sticky persistent volumes (SWIFTCUBE_DESIGN §7). A stateful
// replica that declares a persistent volume is NOT fungible: it gets a stable ordinal
// identity (`<app>-s<ordinal>`) and a DEDICATED volume keyed by `(app, ordinal)`, stable
// across Cell generations and revisions. The volume is a subtree on the node's datafs
// (`/data/volumes/<volumeId>/`, honest fsync); a `slet` provisions it and BINDS it to its
// node, and the scheduler thereafter PINS the replica to that node.
//
// One object family enters the cubestore schema here (SC2 owns /nodes,/leases,/tokens;
// SC3 owns /assignments,/status/cells; SC4 owns /apps,/pending; SC7 owns /services):
//
//   /volumes/<volumeId>  → VolumeRecord{ name, app, ordinal, node(bound), path, size,
//                          mountPath, state, retainPolicy, fencingToken }
//
// The record is the SINGLE source of truth for "which node owns this volume" (read by the
// scheduler to pin) and "which fencing generation is current" (read by every node's slet
// to refuse a stale mount). Written by the owning node's `slet` (the node is the sole
// local authority for its volumes). Foundation-free; little-endian ByteIO, like every
// other cubestore record.

// MARK: - (app, ordinal) volume identity

/// Derives the stable per-replica volume id. The id is keyed by `(app, ordinal)` ONLY, so
/// it is identical across Cell revisions and generations (the stateful-identity guarantee
/// of SC8 case 8). Both the scheduler (forward, from a slot) and `slet` (reverse, from a
/// running Cell's `cellId`) compute it through here, so the two never disagree.
///
/// Wire form `"<app>--s<ordinal>"`: the `--` separates the (possibly hyphenated) app name
/// from the ordinal, mirroring `CellIdCodec`'s `--` convention. App names must not contain
/// `--` (the same rule the cellId codec already imposes).
enum VolumeId {
    static func make(app: String, ordinal: UInt32) -> String { "\(app)--s\(ordinal)" }

    /// Recover `(app, ordinal)` from a Cell's `cellId` (`"<app>--r<rev>-s<slot>-g<gen>"`).
    /// `slet` uses this to find the volume a running Cell owns without depending on the
    /// scheduler's `CellIdCodec` (slet does not link the scheduler). Returns nil if the id
    /// is not a SwiftCube cellId.
    static func fromCellId(_ cellId: String) -> (app: String, ordinal: UInt32)? {
        let b = Array(cellId.utf8)
        // Last "--" splits app from the numeric suffix (app may contain single hyphens).
        var sep = -1
        var i = b.count - 2
        while i >= 0 { if b[i] == 0x2D && b[i + 1] == 0x2D { sep = i; break }; i -= 1 }
        guard sep > 0 else { return nil }
        let app = String(decoding: b[0..<sep], as: UTF8.self)
        // suffix = r<rev>-s<slot>-g<gen>; pull the s<slot> field.
        var parts: [[UInt8]] = []
        var cur: [UInt8] = []
        var j = sep + 2
        while j < b.count { if b[j] == 0x2D { parts.append(cur); cur = [] } else { cur.append(b[j]) }; j += 1 }
        parts.append(cur)
        guard parts.count == 3, parts[1].first == 0x73 /* 's' */,
              let slot = decimal(parts[1].dropFirst()) else { return nil }
        return (app, UInt32(truncatingIfNeeded: slot))
    }

    /// The cubestore volume id for the volume a given `cellId` owns, or nil.
    static func forCellId(_ cellId: String) -> String? {
        guard let p = fromCellId(cellId) else { return nil }
        return make(app: p.app, ordinal: p.ordinal)
    }

    private static func decimal(_ s: ArraySlice<UInt8>) -> UInt64? {
        var v: UInt64 = 0; var any = false
        for c in s { guard c >= 0x30 && c <= 0x39 else { return nil }; v = v &* 10 &+ UInt64(c - 0x30); any = true }
        return any ? v : nil
    }
}

// MARK: - Key schema

enum VolumeKeys {
    static let volumesPrefix: Bytes = Array("/volumes/".utf8)

    static func volume(_ volumeId: String) -> Bytes { volumesPrefix + Array(volumeId.utf8) }

    /// The volumeId from a `/volumes/<id>` key, or nil if the key is not in range.
    static func id(ofVolumeKey key: Bytes) -> String? {
        guard key.count > volumesPrefix.count else { return nil }
        for i in 0..<volumesPrefix.count where key[i] != volumesPrefix[i] { return nil }
        return String(decoding: key[volumesPrefix.count...], as: UTF8.self)
    }
}

// MARK: - Volume lifecycle + retain policy

/// The lifecycle of a node-local PV. `bound` is the resting state (provisioned + owned by
/// a node, not currently mounted); `mounted` means a live Cell generation holds the single
/// writer; `released` is the brief post-fence state before the next mount; `deleted` is a
/// tombstone written by an explicit `Delete` teardown.
enum VolumeState: UInt8, Equatable {
    case provisioned = 0   // datafs subtree exists, not yet bound to a node
    case bound       = 1   // owned by `node`, no live mount
    case mounted     = 2   // a live Cell generation holds the single writer
    case released    = 3   // unmounted (fenced); ready for the next mount
    case deleted     = 4   // explicit Delete tombstone (PV removed)
}

/// What a routine Cell teardown does to the PV. `Retain` (default) keeps the data so it
/// survives reschedule/restart; `Delete` removes the subtree — only on explicit request,
/// never on a routine teardown (SWIFTCUBE_DESIGN §7: "never lose data on a reschedule").
enum RetainPolicy: UInt8, Equatable {
    case retain = 0
    case delete = 1
}

// MARK: - VolumeRecord (the /volumes/<id> object)

struct VolumeRecord: Equatable {
    var volumeId: String      // "<app>--s<ordinal>" (VolumeId.make)
    var name: String          // the manifest volume name ("data")
    var app: String           // owning app
    var ordinal: UInt32       // stable replica ordinal
    var node: String          // the BOUND node (the scheduler pins here)
    var path: String          // datafs subtree, e.g. "/data/volumes/<id>"
    var sizeBytes: UInt64      // requested size — BEST-EFFORT accounting (datafs has no quota)
    var mountPath: String      // where it mounts inside the Cell ("/data")
    var state: VolumeState
    var retain: RetainPolicy
    var fencingToken: UInt64   // monotonic generation, bumped on each (re)bind

    func encode() -> Bytes {
        var w = ByteWriter()
        w.u8(1)                          // record version
        w.blob(Array(volumeId.utf8))
        w.blob(Array(name.utf8))
        w.blob(Array(app.utf8))
        w.u32(ordinal)
        w.blob(Array(node.utf8))
        w.blob(Array(path.utf8))
        w.u64(sizeBytes)
        w.blob(Array(mountPath.utf8))
        w.u8(state.rawValue)
        w.u8(retain.rawValue)
        w.u64(fencingToken)
        return w.bytes
    }

    static func decode(_ bytes: Bytes) -> VolumeRecord? {
        var r = ByteReader(bytes)
        guard let ver = r.u8(), ver == 1,
              let vidB = r.blob(), let nameB = r.blob(), let appB = r.blob(), let ord = r.u32(),
              let nodeB = r.blob(), let pathB = r.blob(), let size = r.u64(), let mpB = r.blob(),
              let stB = r.u8(), let st = VolumeState(rawValue: stB),
              let rpB = r.u8(), let rp = RetainPolicy(rawValue: rpB), let tok = r.u64() else { return nil }
        return VolumeRecord(volumeId: String(decoding: vidB, as: UTF8.self),
                            name: String(decoding: nameB, as: UTF8.self),
                            app: String(decoding: appB, as: UTF8.self), ordinal: ord,
                            node: String(decoding: nodeB, as: UTF8.self),
                            path: String(decoding: pathB, as: UTF8.self), sizeBytes: size,
                            mountPath: String(decoding: mpB, as: UTF8.self),
                            state: st, retain: rp, fencingToken: tok)
    }
}

// MARK: - VolumeBinding (the scheduler's distilled view of a /volumes/<id> record)

/// What the scheduler needs to PIN a stateful replica: which node owns the volume for
/// `(app, ordinal)`. Distilled from a `VolumeRecord` by the scheduler loop; the pure
/// `schedule()` consumes it (SWIFTCUBE_DESIGN §7: "the replica is pinned to its bound
/// node"). A volume that has not been bound yet simply has no binding, so its ordinal is
/// placed fresh (first placement) by fit+spread.
struct VolumeBinding: Equatable {
    var app: String
    var ordinal: UInt32
    var node: String
}
