# cubestore — on-disk format & API (SC0)

cubestore is SwiftCube's storage backbone: an ordered, MVCC key/value store with
a watch API, made durable by a write-ahead log + snapshots behind a pluggable
`StorageSink`. SC0 is single-node, in-process, host-testable. The core
(everything except `host/` and `tests/`) is Foundation-free and written to later
compile under Embedded Swift for swift-os userland.

## Data model (etcd-lite)

- Keys and values are byte strings; the keyspace is ordered lexicographically.
- A global monotonic `Revision` (`UInt64`) starts at 0; each committed non-empty
  batch bumps it by exactly 1 (an empty batch is a no-op).
- Per key the index tracks `value`, `createRevision`, `modRevision`, `version`
  (writes since create). A delete tombstones the key; a later put revives it with
  a fresh `createRevision` and `version = 1`.

## Core API (`CubeStore`, synchronous, single-threaded)

- `get(key, atRevision:) -> Entry?` — MVCC point read (default latest).
- `range(start, end, atRevision:) -> [Entry]` — ordered, half-open `[start, end)`
  (`end == nil` ⇒ open upper bound); `prefix(p, atRevision:)` is the prefix scan.
- `apply([Op]) -> Revision` — atomic batch, one revision; `Op = .put | .delete`.
  Duplicate keys in a batch collapse to the last op (one version per key per rev).
- `compareAndApply(conditions:[Cond], [Op]) -> CASResult` — commit iff every
  condition holds (`keyExists` / `keyAbsent` / `modRevision ==,<,>`). This is the
  primitive leases and leader-election build on (SC1+).
- `compact(upTo:)` — drop history ≤ rev (current values stay); raises the watch
  floor. `snapshot()` — checkpoint the live keyspace and truncate the WAL.
- `watchRange(start, end, fromRevision:)` / `watchPrefix(prefix, fromRevision:)` —
  return a `WatchHandle`. Replays retained events with `modRevision > fromRevision`
  in `(revision, key)` order, then continues live with no gaps/dups (the core is
  single-threaded, so no write interleaves the history→live handoff). A watcher is
  fully described by `{range, fromRevision}` and resumes from its last delivered
  revision. `fromRevision` below the compaction floor throws `.compacted`.

## On-disk format (binary, little-endian, no text)

**WAL** (`AppendLog`): an 8-byte versioned header `"CUBEWAL"0x01` written once,
then one length-prefixed record per committed batch:

```
record : u32 bodyLen | body[bodyLen] | u32 crc32(body)
body   : u64 revision | u32 opCount | op*
op     : u8 kind(0=put,1=delete) | u32 keyLen | key | [u32 valLen | val]   (val only for put)
```

The CRC covers the body; on recovery a short/torn/bad-CRC trailing record is
detected and discarded, and the log is durably truncated to the last good
boundary so future appends extend a clean log.

**Snapshot** (`SnapshotStore`): header `"CUBESNP"0x01`, then
`u64 revision | u64 compactedRevision | u32 entryCount`, then per live key
`u32 keyLen | key | u32 valLen | val | u64 createRevision | u64 modRevision | u64 version`,
then a `u32 crc32` over the whole payload.

**Recovery on open:** load the latest snapshot (set state + compaction floor to
it), then replay WAL records with `revision >` the loaded revision, in order.

## Sinks

`StorageSink` is two seams: `AppendLog` (`append`/`sync`/`readAll`/`reset`, honest
`fsync`) and `SnapshotStore` (`put(bytes, atRevision)`/`latest`). The store hands
across already-framed blobs — framing/CRC/magic live in the codecs, so a sink is a
dumb byte medium. SC0 ships the host POSIX-file sink (`host/PosixFileSink.swift`,
outside the core): WAL is one append-only file with a real `fsync`; snapshots are
per-revision files written via temp + `fsync` + atomic `rename`.

## Seams left for later milestones

- **SC1 (Raft wrap):** `apply` / `compareAndApply` are the single linearizable
  commit point; a Raft layer commits the batch to the log of N replicas, then
  calls `apply` on each state machine. Revisions are already a deterministic
  monotonic clock derived purely from the committed op stream.
- **SC2 (network/wire framing):** a watcher is `{range, fromRevision}` + a resume
  revision, so the in-process callback wraps unchanged into a framed stream;
  `.compacted` maps to the re-`range`-then-re-watch protocol.
- **datafs sink:** implement `AppendLog` + `SnapshotStore` against swift-os datafs
  (`/data`, honest `fsync`/`fdatasync`). No core change — the seam is already
  codec-agnostic. (Note: explicit `compact(upTo:)` raises the in-memory watch
  floor for the running process; the *persistent* floor is carried by snapshots,
  which encode `compactedRevision`. Auto-snapshot/auto-compaction thresholds are a
  later milestone.)
