# SwiftCube control plane — SC2 wire & identity format

This note records the on-wire formats and the identity/lease scheme delivered in
**SC2** (node join over mTLS with bootstrap tokens and TTL leases). It complements
the cubestore (`swiftcube/cubestore/FORMAT.md`) and Raft (`swiftcube/raft/FORMAT.md`)
notes. Everything here is Foundation-free Embedded Swift; the host control-test
(`make control-test`) and the on-device gate (`make sc2-join-test`) link the same
control sources.

## 1. Identity & PKI (kubeadm-style)

- **Scheme:** EC **P-256** keys; certificates signed **ecdsa-with-SHA256**
  (`1.2.840.10045.4.3.2`) over `SHA-256(TBSCertificate)`. This is the one scheme
  the existing swift-os stack already verifies (`x509_verify.swift` chain check and
  the TLS `CertificateVerify` path), so identity reuses it rather than adding a new
  signature algorithm. **No new crypto was written** — `Identity.swift` is DER
  encoding around the existing P-256 signer (`kernel/crypto/p256.swift`) and DER
  writer (`userland/lib/asn1.swift`).
- **Controller CA:** a self-signed CA cert (`basicConstraints cA=TRUE`, critical),
  generated once. Only `caCertDER` (the trust anchor) is distributed; the CA key
  never leaves the controller.
- **Node identity:** the node id is carried in the leaf cert's `subjectAltName`
  **dNSName** (and the commonName). The server cert's SAN is its hostname (e.g.
  `sctld`), checked by the agent via `x509VerifyChain`; a client cert's SAN is the
  node id, which the controller reads out with `verifyClientIdentity` (chain +
  validity + CA-anchor, **no** hostname match).
- **Reused vs. missing primitives:** reused P-256 sign/verify, X25519, SHA-256,
  HKDF, ChaCha20-Poly1305, the ASN.1 DER **writer**, the X.509 **reader**, and
  chain verification. **Found missing** (and built by composing the above, not by
  inventing crypto): the TLS 1.3 **server role** + **mutual auth** (`MutualTLS.swift`),
  and X.509 certificate **issuance** — a TBSCertificate builder (`issueCertificate`),
  since `asn1.swift` only built CSRs, not certs.

## 2. Join flow

1. Out of band an operator runs `sctl token create` → a bootstrap token
   `"<id>.<secretHex>"` (8 hex id + 32 hex secret). The controller stores only
   `SHA-256(secret)` under `/tokens/<id>` with a TTL, a use counter, and a revoked
   flag — never the secret.
2. The node (`slet`) generates a P-256 key and a **PKCS#10 CSR** (proof of
   possession), then opens a **server-authenticated** TLS channel (it verifies the
   server cert against the baked CA; it presents **no** client cert yet).
3. `Join(token, nodeName, csr)`: the controller validates the token (constant-time
   on the hash, unexpired/unrevoked/uses-remaining), verifies the CSR self-signature,
   **spends one use** (CAS-guarded so two joins can't double-spend), and signs a
   long-lived node cert binding `nodeName` (SAN) to the CSR public key. It returns
   `{certDER, caCertDER, nodeId}`.
4. The node thereafter opens **full mTLS** channels presenting that cert; the
   controller authenticates each RPC by the channel's cert identity. A node cannot
   act as another node, and an unauthenticated caller is rejected (`unauthorized`).

## 3. mTLS transport (`MutualTLS.swift`)

A sans-IO TLS 1.3 engine (both roles) reusing the shared record layer
(`tlsRecordSeal`/`tlsRecordOpen`), key schedule (`hkdfExpandLabel`/`hkdfExtract`),
`x25519`, AEAD, SHA-256/HMAC, and P-256 from the existing stack. One suite:
**X25519** key share, **TLS_CHACHA20_POLY1305_SHA256**, **ecdsa_secp256r1_sha256**
signatures. Full handshake only (no PSK/resumption/0-RTT/HRR). The server always
sends a `CertificateRequest`; client auth is **optional at the TLS layer**
(`requireClientCert=false`) but verified-if-present, and **required per-RPC** by the
controller — so a no-cert client completes the handshake yet is rejected at the API,
and a cert not signed by the CA fails the handshake outright.

## 4. Control RPC framing (`Wire.swift`, `Rpc.swift`)

Over the mTLS byte stream, each message is one **length-prefixed frame**:

```
frame  = u32 length (LE) | payload[length]          # length ≤ 1 MiB
```

Unary RPC payloads:

```
request  = u8 opcode | body          # opcode: 1 join, 2 registerNode, 3 heartbeat,
                                      #         4 watch, 5 put, 6 range
response = u8 status | body          # status: 0 ok, 1 badRequest, 2 unauthorized,
                                      #         3 tokenRejected, 4 notFound,
                                      #         5 compacted, 6 internalError
```

Identities are **never** in request bodies — the caller is the mTLS cert identity.
All integers little-endian via cubestore `ByteIO`; byte strings are `u32`-length
blobs.

## 5. Watch wire (network form of the SC0 watch)

`Watch(start, end?, fromRevision)` turns the channel into an event stream. The
controller frames a header then events:

```
ready     = u8 0 | u64 currentRevision        # established; caught up to here
compacted = u8 3 | u64 compactedRevision      # fromRevision below the floor; re-range
put       = u8 1 | blob key | blob value | u64 modRevision
delete    = u8 2 | blob key | u64 modRevision
```

Semantics are exactly SC0's: the controller replays every matching event with
`modRevision > fromRevision` in `(revision, key)` order, then streams live with no
gap or duplicate at the boundary (the core is single-threaded, so no write
interleaves between replay and live registration). The agent tracks the highest
`modRevision` it has seen; on reconnect it re-authenticates (mTLS) and re-issues
`Watch(range, lastRevision)` to resume — or gets `compacted` and must re-`range`.

## 6. Lease format (`Lease.swift`)

```
/leases/<id> → u8 1 | u64 ttlSeconds | u64 expiry | u32 nKeys | blob key[nKeys]
```

A lease is a TTL liveness token keyed to a node. `RegisterNode` grants it
(`expiry = now + ttl`) attaching the node's `/nodes/<id>` key. A **heartbeat**
CAS-extends `expiry` (guarded on the lease's modRevision). The **leader-gated
reaper** scans `/leases/`, and for each expired lease deletes the lease **and** its
attached keys in one atomic batch under a CAS on the lease's modRevision — so a
heartbeat that landed since the scan wins and the node survives. The deletes
broadcast to watchers, so a watching agent sees the node vanish. `now` comes from
an injected `CubeClock` (a `ManualClock` in tests; the wall clock on-device).

## 7. cubestore key schema

```
/nodes/<id>   → NodeRecord{ id, status, leaseId, address, registeredRev }
/leases/<id>  → LeaseRecord (above)
/tokens/<id>  → TokenRecord{ secretHash[32], expiry, usesRemaining, revoked }
```

## 8. Seams left for later milestones

- **SC2b — real Raft peer transport.** Promote SC1's in-process Raft simulator to
  3-controller replication over **mTLS-TCP between `sctld` peers**, reusing exactly
  the TLS + framing here. The reaper is already written leader-gated for this.
- **Daemon-ization / real-NIC transport.** The control channel currently moves
  bytes over an in-process loopback in the self-test; the production `sctld`/`slet`
  loops bridge the same `MutualTLS` byte pump to a TCP fd (`swiftos_socket_stream` /
  `connect` / `accept` + `swiftos_read`/`write`). Guest-local TCP cannot loop back
  through QEMU slirp, so the end-to-end real-NIC run is host↔guest or a real fleet.
- **Watch cancellation.** Embedded Swift has no `weak`, so a watch retains its
  channel for the connection's lifetime; a real daemon cancels the `WatchHandle` on
  disconnect.
- **SC3 — `slet` drives the C6 Cell supervisor.** The agent's watch on its
  assignments feeds the local Cell supervisor (gated on the kernel C-arc).
- **SC4 — scheduler.** `Deployment → N Assignment{node, cell}` written to cubestore
  and watched by `slet`.
