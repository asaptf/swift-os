# SwiftCube SC8 — node-local sticky persistent volumes + fencing (format & model note)

This note records the `Volume` shape, the **fencing contract** (single-mount + token), the
**pin / Pending-on-node-down** behavior, and the **retain policy** actually implemented. It is
the SC8 counterpart to SC3's `cell/FORMAT.md` and SC7's `proxy/FORMAT.md`.

## What SC8 delivers

Persistent storage for stateful instances, the **node-local sticky** way (SWIFTCUBE_DESIGN §7).
A volume is a subtree on the node's **datafs** (`/data`, honest `fsync`); a stateful Cell is
**pinned** to the node holding its volume and stays there across restarts; and **fencing**
guarantees a single writer. Acceptance (the ladder): */data survives a restart, and the
instance stays pinned to its node.*

Replicated / networked / failover storage is **out of scope** (design §7): node death means a
stateful Cell is **unavailable until that node returns**, by design.

## Stateful identity + per-replica volume

A replica that declares a persistent volume is **not fungible**. It gets a **stable ordinal**
identity and a **dedicated** PV keyed by `(app, ordinal)`:

- `cellId` is `"<app>--r<rev>-s<slot>-g<gen>"` (the SC4 `CellIdCodec`); the **ordinal** is the
  slot.
- `volumeId` is `"<app>--s<ordinal>"` (`VolumeId.make`) — keyed by `(app, ordinal)` **only**, so
  it is identical across Cell **generations** and **revisions**. The scheduler computes it
  forward (from a slot); `slet` computes it backward (`VolumeId.fromCellId`) from a running
  Cell's `cellId`, so the two never disagree without `slet` linking the scheduler.

## The `Volume` shape

`slet/volume/Volume.swift`. One cubestore object family:

```
/volumes/<volumeId>  → VolumeRecord{ volumeId, name, app, ordinal, node, path, sizeBytes,
                                     mountPath, state, retain, fencingToken }
```

`record = u8 ver(=1) | blob volumeId | blob name | blob app | u32 ordinal | blob node
        | blob path | u64 sizeBytes | blob mountPath | u8 state | u8 retain | u64 fencingToken`

- `node` is the **bound** node — the single source of truth the scheduler reads to **pin**.
- `state`: `provisioned → bound → mounted → released` (and a `deleted` tombstone).
- `fencingToken`: a monotonic generation, **bumped on each (re)bind** (the fencing guard).
- written by the **owning node's `slet`** (the node is the sole local authority for its
  volumes); read by the scheduler (to pin) and by every node's `slet` (to refuse a stale mount).

## Binding & sticky scheduling (extends SC4)

The pure `schedule()` (`sctld/scheduler/Schedule.swift`) takes a new `bindings: [VolumeBinding]`
input (distilled from `/volumes/`). A **stateful** app (its template declares a `volume`) takes
the sticky path:

- **First placement** (ordinal unbound): fit + spread, like the fungible path. `slet` then
  provisions the PV on the chosen node and records the binding, which pins every later pass.
- **Thereafter** (ordinal bound): the replica is **pinned** — placed **only** on the bound node.
  If that node is **down** (no live lease), the ordinal is left **Pending**, **never re-placed
  elsewhere** (the data is node-local). It resumes on the **same** node when the node returns,
  re-attaching the **same** PV. Scale-down drops the highest ordinals; their PVs are **retained**.

This is the SC4 pin-hint seam realized per-replica: the `pinHint` field (a single node id) is
the fungible coarse pin; SC8's per-`(app, ordinal)` binding is the stateful one.

## Fencing contract (single-mount + token)

`slet/volume/VolumeManager.swift` is the node-local authority. There is **no atomic kernel
destroy-Cell op** (CAPABILITIES §5.3), so single-writer serialization is **SwiftCube's duty**:

- **Single mount.** At most one live Cell generation may hold a volume. The reconciler's
  pre-create hook (`VolumeMounter.acquire`) is **refused** while a prior holder is still mounted;
  the supervisor's teardown hook (`VolumeFence.fence`, invoked by `destroy` **before** releasing
  the volume handle) releases it. A new/restarted Cell is therefore **not mounted until the prior
  teardown is confirmed** — two writers never overlap (asserted via `peakConcurrency`).
- **Fencing token.** A mount presenting a token **older** than the record's `fencingToken` is
  **refused**. A (re)bind to a (new) node bumps the token, so a partitioned controller that
  rebinds the volume elsewhere cannot let a stale holder keep writing — exactly one node wins.

These two are wired into the SC3 reconcile loop: `Reconciler` takes a `VolumeMounter?` (acquire
before `create`/`recreate`/restart) and a `VolumeFence?` (already threaded into `destroy`). SC3–
SC7 pass `nil` for both, so their behavior is unchanged.

## Retain policy

A **routine** teardown (`fence`) **RETAINS** the data — it only releases the mount, never deletes
(`state → released`). Deletion is **explicit** (`VolumeManager.delete`, the `Delete` policy / an
operator action): the subtree is removed and the record tombstoned. Delete is **refused while a
live writer holds the volume**. So a reschedule/restart **never loses data** (design §7).

## datafs / C6 primitives — reused vs. missing

| Need | Present? | Consequence |
| --- | --- | --- |
| `/data` durable FS with honest `fsync` | **yes** (datafs virtio-blk tier; `swiftos_open/write/fsync/mkdir/unlink/getdents/stat`) | the on-device `DatafsVolumeStore` is buildable; the durability path is real |
| per-subtree **size quota** | **no** (datafs is an inode-table + block-bitmap FS) | `sizeBytes` is **best-effort accounting** recorded in the record, **never enforced** — surfaced honestly, not faked |
| **mount a PV into a Cell's namespace** at its mount path | **no — needs C6** (a Cell owns a VFS namespace + root) | the in-Cell mount is **C6-dependent like SC3**; the provisioning / binding / fencing logic is host-testable without it |
| atomic kernel **destroy-Cell** | **no** (CAPABILITIES §5.3) | single-writer fencing is the **orchestrator's** duty — implemented here, not in the kernel |

The on-device `DatafsVolumeStore` compiles into the `slet` ELF (the SC5 `NetProbe` / SC7
`NetProxyTransport` real-binding pattern); its live `/data` provisioning runs once datafs + C6
yield a real stateful Cell. The **QEMU end-to-end gate** (a real stateful Cell writes `/data`,
the Cell/node restarts, the data survives and stays pinned) is therefore **deferred**, exactly as
the SC3/SC5/SC7 on-device gates are — the slet self-check exercises the SC8 types + datafs binding
on-device (`slet: SC8 PV record …`) without faking a Cell.

## Tests

`make volume-test` (`slet/volume/tests/volume_test.swift`), host-deterministic over an in-process
cubestore + a `HostDirVolumeStore` (a host directory standing in for datafs, honest POSIX `fsync`)
+ the SC3 `FakeCellSupervisor` + an injected clock. Cases 1–8: provision+bind, data-survives-
restart, pinning, node-down→Pending→return, single-mount (direct + through the reconcile loop),
stale-token, retain/delete, stable identity. SC0–SC7 targets stay green.

## Seams left (out of scope for SC8, recorded)

- **replicated / networked / failover storage** — node death ⇒ a stateful Cell is unavailable
  until the node returns; cross-node replication is a separate distributed-storage project.
- **size quotas** — `sizeBytes` is best-effort until datafs grows a per-subtree quota.
- **PV snapshots / backups, dynamic resize** — not built.
- **shared / `ReadWriteMany` volumes** — single-writer only here.
- **the in-Cell mount** — binding the PV into a Cell's namespace at its mount path lands with C6
  (`C6Adapter.swift`), the same file that lights up the SC3 Cell path.
- **nested-subtree delete on datafs** — `DatafsVolumeStore.remove` enumerates one level
  (`getdents`); the manager writes only flat files, so a recursive walk is a follow-on.
