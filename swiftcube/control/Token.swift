// SPDX-License-Identifier: Apache-2.0
// Token.swift — bootstrap-token join secrets (SC2, kubeadm-style).
//
// A node joins by presenting a short-lived bootstrap token issued out-of-band
// (`sctl token create`). The token is a bearer secret of the form "<id>.<secret>"
// (both hex), e.g. "a1b2c3d4.0011223344556677889900aabbccddee". The controller
// stores only a SHA-256 *hash* of the secret under /tokens/<id>, never the secret
// itself, plus a TTL, a remaining-use counter, and a revoked flag. Validation is
// constant-time on the hash; a successful join spends one use (CAS-guarded so two
// concurrent joins cannot both consume the last use); a spent/expired/revoked
// token is rejected with nothing written.
//
// Serialized with cubestore ByteIO (little-endian, no text). Foundation-free.

/// The persisted, hashed form of a bootstrap token (value at /tokens/<id>).
struct TokenRecord: Equatable {
    var secretHash: [UInt8]    // SHA-256 of the secret bytes
    var expiry: UInt64         // clock seconds after which the token is invalid
    var usesRemaining: UInt32  // join attempts left (0 ⇒ spent)
    var revoked: Bool

    func encode() -> Bytes {
        var w = ByteWriter()
        w.u8(1)
        w.blob(secretHash)
        w.u64(expiry)
        w.u32(usesRemaining)
        w.u8(revoked ? 1 : 0)
        return w.bytes
    }

    static func decode(_ bytes: Bytes) -> TokenRecord? {
        var r = ByteReader(bytes)
        guard let ver = r.u8(), ver == 1,
              let hash = r.blob(),
              let exp = r.u64(),
              let uses = r.u32(),
              let rev = r.u8() else { return nil }
        return TokenRecord(secretHash: hash, expiry: exp, usesRemaining: uses, revoked: rev != 0)
    }
}

/// The clear bootstrap token, as minted and handed to an operator. Only the
/// hashed `TokenRecord` is stored; this value carries the secret out-of-band.
struct BootstrapToken {
    var id: String             // hex lookup key, /tokens/<id>
    var secret: [UInt8]        // raw secret bytes (never stored server-side)

    /// The wire form presented on join: "<id>.<secretHex>".
    var presented: String { id + "." + Hex.encode(secret) }

    /// Parse a presented "<id>.<secretHex>" back into (id, secret).
    static func parse(_ presented: String) -> (id: String, secret: [UInt8])? {
        let parts = presented.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let id = String(parts[0])
        guard !id.isEmpty, let secret = Hex.decode(String(parts[1])), !secret.isEmpty else { return nil }
        return (id, secret)
    }
}

enum TokenError: Error, Equatable {
    case notFound
    case expired
    case revoked
    case spent
    case badSecret
    case malformed
}

/// Mints, stores, validates, spends, and revokes bootstrap tokens in cubestore.
/// Generic over the cubestore durability seams, like the store itself.
struct TokenAuthority<Log: AppendLog, Snap: SnapshotStore> {
    let store: CubeStore<Log, Snap>
    let clock: CubeClock

    /// Mint a token valid for `ttlSeconds` and `uses` joins; persist its hash.
    /// `rng` fills the id (4B) and secret (16B). Returns the clear token.
    func create(ttlSeconds: UInt64, uses: UInt32, _ rng: (inout [UInt8]) -> Void) -> BootstrapToken {
        var idBytes = [UInt8](repeating: 0, count: 4)
        var secret  = [UInt8](repeating: 0, count: 16)
        rng(&idBytes); rng(&secret)
        let id = Hex.encode(idBytes)
        let rec = TokenRecord(secretHash: sha256Bytes(secret),
                              expiry: clock.nowSeconds() &+ ttlSeconds,
                              usesRemaining: uses, revoked: false)
        store.apply([.put(key: CubeKeys.token(id), value: rec.encode())])
        return BootstrapToken(id: id, secret: secret)
    }

    /// Validate a presented token without consuming it (its id and current record).
    func validate(_ presented: String) -> Result<(id: String, rev: Revision), TokenError> {
        guard let (id, secret) = BootstrapToken.parse(presented) else { return .failure(.malformed) }
        let key = CubeKeys.token(id)
        guard let entry = store.get(key), let rec = TokenRecord.decode(entry.value) else {
            return .failure(.notFound)
        }
        if rec.revoked { return .failure(.revoked) }
        if clock.nowSeconds() > rec.expiry { return .failure(.expired) }
        if rec.usesRemaining == 0 { return .failure(.spent) }
        if !constantTimeEqual(sha256Bytes(secret), rec.secretHash) { return .failure(.badSecret) }
        return .success((id, entry.modRevision))
    }

    /// Atomically spend one use of a validated token (decrement, or delete the
    /// record when the last use is consumed). CAS-guarded on the record's
    /// modRevision so a concurrent join cannot double-spend. Returns true on spend.
    func spend(id: String, atRevision rev: Revision) -> Bool {
        let key = CubeKeys.token(id)
        guard let entry = store.get(key), let rec = TokenRecord.decode(entry.value) else { return false }
        if rec.usesRemaining == 0 { return false }
        var updated = rec
        updated.usesRemaining -= 1
        let op: Op = updated.usesRemaining == 0
            ? .delete(key: key)
            : .put(key: key, value: updated.encode())
        let res = store.compareAndApply(conditions: [.modRevisionEquals(key: key, rev)], [op])
        return res.committed
    }

    /// Revoke a token immediately (idempotent; missing token is a no-op success).
    @discardableResult
    func revoke(id: String) -> Bool {
        let key = CubeKeys.token(id)
        guard let entry = store.get(key), var rec = TokenRecord.decode(entry.value) else { return true }
        rec.revoked = true
        let res = store.compareAndApply(conditions: [.modRevisionEquals(key: key, entry.modRevision)],
                                        [.put(key: key, value: rec.encode())])
        return res.committed
    }
}
