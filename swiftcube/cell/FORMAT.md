# SwiftCube SC3 — the Cell-supervisor seam, reconcile loop, and status format

This note records what **SC3** delivers: the node-side reconcile loop (`slet`) that
watches its assignments in cubestore and drives the **C6 Cell supervisor** to bring each
**Cell** (the deployed instance) to the desired state, reporting status back. It
complements the SC2 control-plane note (`swiftcube/control/FORMAT.md`) and the cubestore
note (`swiftcube/cubestore/FORMAT.md`). Everything on the data path is Foundation-free
Embedded Swift; the host `slet-test` (`make slet-test`) links the same reconcile-loop
sources, and the on-device gate is **deferred** (see "C6 status" below).

## 1. The design rule

`slet` is a **cluster-aware wrapper over the C6 supervisor, not a replacement**
(SWIFTCUBE_DESIGN §5). C6 owns the *local* mechanism — given a `CellSpec`, assemble
`job + handle set + resource domain + namespace` and launch/supervise a process. SC3 is
the *cluster* loop on top: watch assignments → drive the supervisor → report status. SC3
does **not** re-implement Cell lifecycle, isolation, or capability assembly.

The boundary is the `CellSupervisor` protocol (`swiftcube/cell/CellSupervisor.swift`).
Two implementations sit behind it:

- **`FakeCellSupervisor`** (`swiftcube/cell/FakeSupervisor.swift`) — host-only, models a
  per-Cell process count + handle count + generations + injectable crash, so the
  acceptance tests can assert atomic teardown and exercise restart/policy/backoff with no
  kernel.
- **`C6CellSupervisor`** (`swiftcube/cell/C6Adapter.swift`) — the real adapter onto the
  kernel C6 Cell primitives.

## 2. C6 status — honest scope

**C6 is not implemented.** Per CAPABILITIES §6 and `docs/RISK_REMEDIATION_ROADMAP.md`,
only the per-process `CellId` tag and syscalls 51–53 exist; the C1–C6
capability/handle/IPC/cell arc has not been built. SC3 is the first SwiftCube milestone
gated on C6, so — following the milestone's "scope honestly" rule — the SwiftCube value
lands now without faking the kernel:

- the reconcile loop is built against the `CellSupervisor` seam and is fully exercised by
  the host fake;
- `C6CellSupervisor` is a **documented stub**: it creates no Cell and returns
  `.unavailable`, which the loop surfaces as a Cell status;
- the **QEMU end-to-end gate (SC3 case 9) is deferred**, not claimed. When C6 lands,
  `C6Adapter.swift` is the only file that changes to light up the on-device path; the loop
  above the seam is unchanged.

## 3. `CellSpec` ↔ Cell mapping

`CellSpec` (`swiftcube/cell/CellSpec.swift`) is the desired shape of one Cell. It maps
onto C6 Cell properties almost one-to-one (SWIFTCUBE_DESIGN §5):

| `CellSpec` field   | Cell property (CAPABILITIES C6)                                    |
| ------------------ | ------------------------------------------------------------------ |
| `image: ImageRef`  | read-only, content-addressed signed packed base                    |
| `capabilities`     | explicit kernel capability grant set (**not** root-in-container)    |
| `resources`        | resource-accounting domain + limits, keyed by `CellId`             |
| `namespaceRoot`    | the cell's VFS root view                                            |
| `args` / `env`     | the launched process's argv / environment                          |
| `tmpfsScratch`     | private RAM scratch (the writable half of the "image")             |
| `volume`           | optional node-local PV handle slot (**SC8 seam**; unwired in SC3)  |
| `restartPolicy`    | orchestrator supervision policy (`Always`/`OnFailure`/`Never`)     |

`ImageRef = { digest[32], signature[64] }` is a content address (SHA-256 of the packed
base) plus a detached Ed25519 signature over the digest. Verification reuses swift-os's
existing `ed25519Verify` + `sha256` (the SWSYS/SWOSBASE trust model) — **no new signature
scheme**. The reconciler verifies the image (content address **and** signature under the
trusted key) *before* asking the supervisor to create a Cell; a bad/unsigned/unstaged ref
is rejected with no Cell and the reason in status. The network pull / registry that
**stages** the bytes locally is the explicit out-of-scope seam (`ImageStore.resolve`
returns nil for "not staged").

## 4. cubestore key schema (SC3 additions)

```
/assignments/<node>/<cellId>  → Assignment{ generation, CellSpec }   # DESIRED (scheduler writes; SC4)
/status/cells/<cellId>        → CellStatusRecord                      # OBSERVED (slet CAS-writes)
```

`Assignment` carries a `generation` (bumped by the scheduler for a deliberate roll) plus
the full `CellSpec`. `slet` watches `/assignments/<thisNode>/` (resumable watch) and
reconciles. SC3 only **consumes** assignments — the scheduler that produces them is SC4.

### Status object shape (`CellStatusRecord`)

```
record    = u8 version(=1) | blob cellId | blob node | phase | u8 ready
            | u32 restartCount | blob imageDigest(32) | u64 startedAtSeconds | blob message
phase     = u8 tag                         # 0 created, 1 running, 2 stopping, 4 failed
          | u8 3, u32 exitCode             # dead(exitCode)  (i32 as bit-pattern u32)
```

`ready` is `phase == running` in SC3 (real readiness/liveness probes are SC5). The status
closes the loop for SC4 (placement) and SC5 (endpoints) to read.

## 5. Reconcile loop (level-triggered)

`Reconciler` (`swiftcube/slet/Reconciler.swift`) reconciles **to desired state from
actual state**, not from events — every pass re-derives the world from `desired`
(the assignment range) vs `actual` (the supervisor's `liveCells()` + its own bookkeeping).
Watch events are only wakeups. Each pass:

1. **Adopt** — register any `liveCells()` Cell we don't track yet (a freshly restarted
   `slet` re-attaches instead of recreating — the basis of restart idempotency).
2. **Converge** — create a missing Cell (after image verification); on a changed
   image-digest or generation, atomic **recreate** (drift repair).
3. **Reap** — atomically `destroy` any tracked Cell no longer desired.
4. **Supervise** — poll running Cells; on `dead`/`failed` apply `restartPolicy` + backoff,
   incrementing and reporting the restart count.
5. **Report** — CAS each status into `/status/cells/<cellId>` (don't clobber).

The result: missed/duplicate watch events, reconnects, and `slet` restarts all converge
with **no duplicate Cells and no orphans**. A reconnect re-issues the watch from the
resume cursor and does **not** churn healthy Cells (level-triggered, so a matching
desired/actual is left untouched).

Status reporting goes over a new SC2 control RPC, **`casPut` (opcode 7)** — the wire form
of cubestore's `compareAndApply` — so "report status via CAS, don't clobber" holds over
the real mTLS API (`AgentStoreClient`), not just in-process.

## 6. Teardown & fencing contract

`destroy(handle, fence:)` is **atomic teardown**: stop *every* process of the Cell and
release *every* handle/resource, returning `true` only when the supervisor can guarantee
nothing of the Cell still runs. Because there is no single kernel "destroy-Cell" op
(CAPABILITIES §5.3), this atomicity is **slet/the supervisor's duty**, not the kernel's.
The host fake proves it: `destroy` zeroes the Cell's process and handle counts in one act
and the test asserts both reached zero (no leak) and the Cell is gone. A `destroy` that
cannot verify teardown (returns `false`) keeps the record for a retry next pass rather
than orphaning the Cell.

**Fencing** is the SC8 seam: `destroy` invokes the optional `VolumeFence` **before**
releasing a volume handle, so no process of an old Cell can still write to a PV after a
reschedule (SWIFTCUBE_DESIGN §7). SC3 passes `fence: nil` and leaves the `volume` slot on
`CellSpec` unwired; SC8 supplies the real PV handle + fence.

## 7. Seams left for later milestones

- **SC4 — scheduler.** Produces `/assignments/<node>/<cellId>`; SC3 only consumes them.
- **SC5 — readiness/liveness probes + endpoints loop.** SC3's `ready` is just
  `phase == running`; real probes drive endpoint registration off the status object.
- **SC7 — east-west networking.** The node-proxy / service registry; SC3 grants
  `net.listen:*` capabilities but does not wire service IPs.
- **SC8 — node-local sticky PV + fencing.** The `volume` slot on `CellSpec`, the
  `VolumeFence` hook in `destroy`, and sticky placement are seams here.
- **Image registry / network pull.** `ImageStore` assumes the base is pre-staged locally;
  fetching it (content-addressed pull, dedup) is out of scope.
- **C6 real adapter.** `C6CellSupervisor` is a stub until the kernel C-arc reaches C6;
  it is the single file that changes to enable the on-device Cell path and the SC3 QEMU
  gate.
