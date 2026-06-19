# raft — consensus core, entry format & recovery (SC1a)

`swiftcube/raft/` puts cubestore's writes behind **Raft** so a cluster of `sctld`
controllers stays linearizable: any node accepts a request, writes replicate to a
quorum, and talking to any node behaves master-master. The consensus core is a
**transport-agnostic, deterministic state machine** (the etcd-raft / raft-rs
split): it consumes inbound messages + logical **ticks** and emits outbound
messages + "entry committed" / "apply snapshot" notifications. It never touches a
socket or a wall clock. The core (everything except `tests/`) is Foundation-free
and reuses cubestore's seams verbatim — `Bytes`, `ByteWriter`/`ByteReader`,
`cubeCrc32`, and the `AppendLog` / `SnapshotStore` durability protocols — so the
**committed Raft log _is_ cubestore's durability log** (see "one log" below).

**Scope.** SC1a landed the consensus core + the deterministic simulator + the
safety/liveness suite (cases 1, 4–8, 11) against a trivial state machine. SC1b
wires **cubestore** in as the real state machine (`swiftcube/store/`) — writes go
through Raft (propose → commit → apply), compare-and-apply is evaluated at apply,
ReadIndex serves linearizable reads, and writes submitted to a follower are
forwarded to the leader (cases 2, 3, 9, 10). There is no network here: SC2 adds
the TCP/TLS transport, client RPC, and worker-node join. Membership is **static
3-node**; dynamic membership / joint consensus is deferred.

## The algorithm (`RaftNode`)

A pure replica of Raft: randomized **seeded** election timeouts measured in ticks
(no wall clock; the per-node PRNG stream is varied by node id), terms + voting,
log replication via AppendEntries, commit-index advance under the
leader-completeness rule (a leader commits only via an entry from **its own**
term — hence the no-op below), step-down on a higher term, and snapshot transfer
via InstallSnapshot.

- `tick()` — advance one logical tick (drive elections / heartbeats).
- `step(message, from)` — consume one inbound message.
- `propose(data, kind:) -> LogIndex?` — leader appends a command; followers return
  nil (the driver forwards to `leaderId` — in-sim in SC1, an RPC in SC2).
- `compact(throughIndex:, snapshotData:)` — fold an applied-state snapshot into the
  log (log compaction).
- `takeMessages()` / `takeCommitted()` / `takeSnapshotToApply()` — the driver
  drains outbound messages, newly committed entries (strict index order), and a
  "reset the state machine to this snapshot" notification (applied **before** any
  committed entries returned in the same round).

Volatile state (role, commit index, election/heartbeat timers, the leader's
per-peer `nextIndex`/`matchIndex`) lives in the node; durable state lives in
storage. On restart the volatile state is rebuilt and the commit index re-derives
from replication — standard Raft.

## Entry kinds & payload

A committed entry is `{term, index, kind, data}`:

- **`.noop`** (kind 0) — the empty entry a freshly elected leader appends to commit
  at its own term. The state machine **ignores** it; in SC1b it must **not** bump
  the cubestore revision.
- **`.normal`** (kind 1) — an opaque state-machine command. In SC1b `data` is a
  **cubestore write batch** (the encoded `{conditions, ops}` of an `apply` /
  `compareAndApply`); a committed `.normal` entry advances the cubestore revision
  by exactly 1 when applied. `compareAndApply` becomes deterministic-at-apply:
  conditions are evaluated against the applied state in log order, so every node
  reaches the same accept/reject verdict.

The core treats `data` as opaque bytes — only entry **kind** matters to consensus.

## One log, not two

The committed Raft log replaces SC0's standalone cubestore WAL. `SinkRaftStorage`
persists the three things Raft must keep across a crash — `currentTerm`,
`votedFor`, and the log — through the same `AppendLog` + `SnapshotStore` seams
cubestore uses. A Raft snapshot (log compaction) **is** a state-machine snapshot at
the applied index, and drives `InstallSnapshot` for lagging followers.

### WAL stream (`AppendLog`, binary, little-endian, no text)

8-byte versioned header `"CUBERFT"0x01` written once, then one length-prefixed
record per mutation:

```
record    : u32 bodyLen | body[bodyLen] | u32 crc32(body)
body kinds (first byte):
  0 hardState : u64 term | u8 hasVote | u64 votedFor
  1 entry     : u64 index | u64 term | u8 kind | u32 dataLen | data
  2 truncate  : u64 fromIndex          (drop entries with index ≥ fromIndex)
```

The CRC covers the body; a short/torn/bad-CRC trailing record is detected and
discarded by the codec scan (same honest-`fsync` + app-level recovery model as
cubestore — no FS journaling). Every mutation is written through and `fsync`'d
before the node acts on it, so a restart over the same sink recovers identical
state (**no double-vote within a term**, even across a crash mid-election).

### Snapshot blob (`SnapshotStore`)

```
"CUBERSN"0x01 | u64 lastIncludedIndex | u64 lastIncludedTerm | u32 dataLen | data | u32 crc32(payload)
```

`data` is the opaque **state-machine** snapshot at `lastIncludedIndex` (the bytes
shipped in `InstallSnapshot`). In SC1b this is a cubestore snapshot at the applied
revision.

### Recovery on open

1. Load the latest snapshot → `lastIncludedIndex` / `lastIncludedTerm` / the SM
   snapshot bytes.
2. Replay WAL records in order: `hardState` sets `term`/`votedFor`; `entry` appends
   (entries at or below the snapshot floor are skipped); `truncate` drops a
   conflicting suffix. The result is the exact pre-crash hard state + log tail.
3. The driver rebuilds the state machine from the SM snapshot bytes; committed
   entries past the snapshot are re-applied (idempotently, by index) as the cluster
   re-commits them.

Compaction and a follower installing a remote snapshot both **rewrite** the WAL:
persist the snapshot, reset the log, then restamp current hard state + the
post-snapshot tail (mirroring cubestore's `snapshot()` truncate pattern).

## The simulator (test substrate, `tests/`, Foundation allowed)

An in-process `MessageBus` with controllable **drop / delay / reorder / partition /
heal**, all from a seeded PRNG, so a `(seed, scenario)` pair reproduces byte-for-
byte (case 11). `MemAppendLog` / `MemSnapshotStore` retain bytes across reopen, so
reopening storage over the same sinks *is* a crash-restart (case 7). The harness
asserts the Raft **safety** properties continuously, not just "it worked":

- **election safety** — at most one leader per term;
- **log matching** — equal `(index, term)` on two nodes ⇒ identical term-prefix;
- **leader / state-machine completeness** — a committed index never changes its
  entry, and applied command sequences are prefixes of one another;
- **liveness** — progress resumes within bounded ticks after a heal.

## State-machine integration (SC1b, `swiftcube/store/`)

`CubeStateMachine` conforms to `RaftStateMachine` and wraps an SC0 `CubeStore`
running over a **discard** log + an in-memory snapshot (its own WAL retired):

- A committed `.normal` entry decodes to a `WriteRequest` `{conditions, ops}` and
  is applied via `cubestore.compareAndApply` — so a plain batch and a CAS share one
  path, and the accept/reject verdict is **deterministic at apply** (identical on
  every node). A committed write that commits advances the cubestore revision by
  exactly 1; `.noop` entries are ignored (no revision bump).
- The proposing node records the per-index `CASResult`, so the leader reports the
  single agreed outcome to the client.
- `snapshot()` serializes the cubestore keyspace at the applied revision (this *is*
  the Raft snapshot shipped by InstallSnapshot); `restore(...)` rebuilds cubestore
  from it.
- **ReadIndex** (`RaftNode.requestRead`): the leader stamps a fresh heartbeat
  `round`, and the read is served only once a quorum echoes that round (current
  leadership confirmed) and the state machine has applied the recorded read index.
  A partitioned ex-leader never gets the quorum echo, so it cannot serve stale
  committed data — it fails (the driver then forwards). Lease-based fast reads and
  stale follower reads are out of scope.
- **Forwarding:** a write submitted to a non-leader follows the node's `leaderId`
  hint to the leader (in-sim routing here; the client-facing forwarding RPC is SC2).

## Seams left for later milestones

- **SC2 (network):** replace the simulated bus with a TCP/TLS transport + message
  framing, the client-facing RPC server (client reads/writes + watch streams), and
  worker-node join. The `Envelope` `{from, to, message}` shape and the
  `takeMessages`/`step` seam wrap unchanged; client forwarding becomes a real RPC.
- **Dynamic membership / joint consensus:** add configuration-change entries and a
  two-phase joint configuration; SC1 is static 3-node only.
- **datafs durability:** point `SinkRaftStorage` at the swift-os datafs `AppendLog`
  / `SnapshotStore` (honest `fsync`) instead of the host file/in-memory sinks.
