# SC4 scheduler — object shapes, scoring, and the reschedule boundary

The scheduler is `sctld`'s controller-side placement loop: it watches `Deployment`
specs and live node state and produces the `Assignment` objects SC3's `slet` consumes,
closing the self-healing loop of `SWIFTCUBE_DESIGN.md` §4. **SC4 produces what SC3
consumes.** The placement decision is a **pure function** (`schedule()` in
`Schedule.swift`) so it is deterministic and trivially testable; the reconcile loop
(`SchedulerLoop.swift`) is the only part that touches cubestore.

## Objects and key schema

| Key | Object | Who writes | Who reads |
| --- | --- | --- | --- |
| `/apps/<app>/spec` | `DeploymentSpec` | `sctl apply` (SC9) | scheduler |
| `/assignments/<node>/<cellId>` | `Assignment` | **scheduler** | `slet` (SC3) |
| `/status/cells/<cellId>` | `CellStatusRecord` | `slet` (SC3) | scheduler |
| `/pending/<app>/s<slot>` | `PendingRecord` | scheduler | operators / SC5 |
| `/nodes/<id>`, `/leases/<id>` | `NodeRecord`, `LeaseRecord` | SC2 | scheduler |

### `DeploymentSpec` (`/apps/<app>/spec`)

`app`, `replicas`, `revision`, `request` (cpu/mem the scheduler fits against),
`nodeSelector` (required `"key=value"` labels), `pinHint` (SC8 seam; `""` = unpinned),
and a `CellTemplate` — the `CellSpec` minus the per-instance `cellId`/`node`, which the
scheduler fills per slot. `request` is the scheduling request and is distinct from the
template's `resources` (the cell's enforced limit), mirroring Kubernetes request-vs-limit;
SC4 sets them equal in practice but keeps the seam.

### `Assignment` (`/assignments/<node>/<cellId>`) — the SC3↔SC4 contract

SC3 already defined `Assignment{generation, spec}`. SC4 adds **`revision`**: the
Deployment revision a replica belongs to. SC3's reconciler ignores it (drift is keyed on
`generation` + image digest); SC9 layers multi-revision rollout on top using it, with no
further schema change. The record is versioned — a v1 record (SC3 on the wire) decodes
with `revision == 0`, and `Assignment(generation:spec:)` still compiles (the new
parameter defaults).

`NodeRecord` likewise grew (v2): schedulable `capacity` (cpu/mem) and `labels` for
selector matching. Both are kept as scalars/`[String]` so the control layer stays free of
a cell-layer dependency; v1 records decode with zero capacity and no labels.

### Deterministic Cell identity

`cellId = "<app>--r<rev>-s<slot>-g<gen>"` (`CellIdCodec`), derived from
`(app, revision, slot ordinal, generation)` — **never random**. The `--` separates a
(possibly hyphenated) app name from the numeric suffix; app names must not contain `--`.
A slot keeps its ordinal across a reschedule, so the same slot reappearing on a survivor
is predictable; `generation` bumps when a terminally failed slot is replaced, yielding a
fresh `cellId` the old generation cannot be confused with.

## The pure `schedule()` and its scoring

`schedule(deployments, nodes, placements) -> (desired, pending)`. `placements` is the
current world: every live `Assignment` joined with its observed `CellStatusRecord`. Per
app (apps processed in id order for determinism):

1. **Filter** candidate nodes: healthy (live lease) ∧ `nodeSelector` matches ∧ **fits**
   (`free = capacity − Σ requests of resident non-failed replicas ≥ request`).
2. **Keep** healthy, non-terminally-failed replicas at slots `< replicas` — no churn.
3. **Scale up** by placing the missing replicas onto the **best-scoring** nodes:
   - fewest replicas of *this app* (spread), then **most free resources** (memory then
     cpu), then **lowest node id** (stable). A `pinHint` that is itself a candidate wins
     outright (SC8 sticky-PV seam).
   - new replicas take the lowest free **slot ordinals**.
4. **Scale down** by evicting the **most-loaded** nodes first: most replicas of this app,
   then least free (most pressure), then a stable id-desc/slot-desc tie-break.
5. **Pending**: a slot with no candidate node is recorded as `PendingPlacement{app, slot,
   reason}` — **never silently dropped**. It is placed and its marker cleared as soon as a
   fitting node joins.

**Determinism guarantee:** no clock, no randomness, no I/O; every ordering is a total
order (node id, slot). `desired` is returned sorted by `(node, cellId)` and `pending` by
`(app, slot)`, so equal inputs yield byte-identical output (case 9 asserts this directly).

## Reschedule vs. local restart (the critical boundary)

- **Node loss** — a lease expires, so the node is no longer healthy. Its placements never
  reach `schedule()` (the loop drops them), so those slots are simply missing and get
  **re-placed on survivors**; the stranded `/assignments/<deadnode>/…` keys fall out of
  the desired set and the loop deletes them. The lease TTL is the grace period before a
  node is treated as gone.
- **Terminal Cell failure** on a *live* node — `slet` reports phase `.failed` (restart
  policy exhausted). The scheduler re-places that slot (new generation ⇒ new `cellId`).
- **Transient Cell crash** on a live node — status is **not** `.failed`; SC3's `slet`
  owns local restart. The scheduler keeps the `Assignment` untouched: **no reschedule, no
  churn** (case 7).

## The reconcile loop

`SchedulerLoop.step()` is level-triggered and **leader-gated** (reuses the SC2 `isLeader`
signal — a follower returns immediately, so two controllers never write conflicting
Assignments). Each pass: read Deployments + nodes/leases + Assignments + status → call
`schedule()` → diff the desired set against `/assignments/` and apply the delta with **CAS**
(create-if-absent / update-on-revision / delete-on-revision, defensively) → write/clear
`/pending` markers. Generic over the cubestore durability seams, so it runs over the SC2
RAM store in host tests and the datafs-backed store on-device unchanged.

## Seams left for later milestones

- **SC5 (probes → health):** `schedule()` already keys re-placement on observed status;
  SC5 feeds richer readiness/liveness into the `terminalFailed`/health signal and the
  endpoints loop reads `/status/cells`.
- **SC8 (PV pinning):** `pinHint` is carried on the Deployment and honored by the scorer
  (a pinned candidate wins). The real sticky-PV binding (datafs handle, fencing) is SC8;
  the scheduler seam is in place.
- **SC9 (rollout across revisions):** each Assignment carries `revision`; SC4 schedules a
  single current revision. SC9 layers `maxSurge`/`maxUnavailable` and canary weights over
  multiple revisions using that field, without changing the object schema.

## Tests

`make scheduler-test` — host acceptance, cases 1–10, deterministic against an in-process
cubestore. SC0–SC3 suites (`cubestore-test`, `raft-test`, `store-test`, `control-test`,
`slet-test`) stay green.
