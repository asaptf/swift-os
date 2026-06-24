# SC9b — the rollout state machine: phases, transitions, rollback, and the harness

The rollout controller is `sctld`'s deployment orchestration: it transitions an app from its old
revision to a new one with a chosen strategy, gating on SC5 readiness and rolling back automatically
if the new revision does not converge. It **sits above the SC4 scheduler and reuses it** — it never
places or supervises a Cell itself.

## How it reuses the lower milestones

A rollout decides two things and writes them as desired state; the existing reconcilers do the rest:

| The controller writes | Consumed by | Effect |
| --- | --- | --- |
| `/schedrev/<app>/<rev>` = DeploymentSpec (per-revision desired count) | **SC4 scheduler** | places each revision's replicas (sharing capacity ⇒ surge) |
| `/traffic/<app>` = TrafficPolicy (per-revision weights) | SC5 endpoints / SC6 LB *(seam — see below)* | admits traffic per the rollout |
| `/rollouts/<app>` = RolloutRecord (status + history) | `sctl rollout status` / `undo` | observability + undo |

The SC4 scheduler already keys placement on `dep.revision`, so feeding it one DeploymentSpec per
active revision makes it place old + new simultaneously with **no scheduler rewrite** — only
`readDeployments()` learned to prefer `/schedrev/<app>/*` over `/apps/<app>/spec` when an app is
under a managed rollout (with none, it is the unchanged SC4 direct path, so SC4 stays green).
Readiness is observed from `/status/cells` (SC3/SC5); node-loss reschedule, image trust, fencing —
all inherited unchanged.

## Pure stepper + thin loop (the SC4 pattern)

- `RolloutPlan.swift` — **pure** `startRollout(...)` / `planRollout(rec, observed, now)`: a
  deterministic function of the record + observed readiness + clock. The strategies and rollback
  live here, so they are unit-testable with no store (cases 3–8).
- `RolloutController.swift` — the **leader-gated, level-triggered** loop: read the desired spec +
  rollout record + observed readiness, plan one step, write `/schedrev` + `/traffic` + `/rollouts`.
  Idempotent writes (skip-if-unchanged) + reading state fresh each pass mean a reconnect/restart
  resumes without double-stepping (case 9). Only the Raft leader runs it.

## Revisions, history, and the per-revision spec

`sctl apply` writes `/apps/<app>/spec` at the new revision (SC9a bumps it on a template change). The
controller snapshots each target into `/history/<app>/<rev>` so the draining old revision keeps
running and `rollout undo` can recover a prior spec. The live scheduler input `/schedrev/<app>/<rev>`
is that spec with `replicas` set to the rollout's current per-revision desire. On **Complete** the
controller deletes `/schedrev` and the scheduler falls back to `/apps/<app>/spec` (same revision, same
cellIds) — a seamless hand-off with no churn.

## Phases and transitions

```
            apply new revision
   (any) ───────────────────────▶ Progressing
                                     │  step per strategy, gated on SC5 readiness
                 all/target ready    │
        ┌────────────────────────────┤
        ▼                            ▼  progress deadline exceeded & target not ready
    Complete                     Failed  (after RollingBack: new→0, old→N, traffic→old)
```

- **Progressing** — stepping toward the target. The plan adjusts per-revision desired counts and the
  traffic split each pass.
- **Complete** — new = N ready, old = 0. `/schedrev` removed; the app returns to the SC4 direct path.
- **Failed** — the progress deadline tripped before the target reached N ready: the controller
  reverts (new → 0, old → N, traffic → 100% old) and records `failedRevision`. The **same broken
  spec is not auto-retried** — the rollout stays Failed (serving the old revision) until a *different*
  spec is applied. `RollingBack` is the transient label while the revert is in flight.

## Strategies

- **Rolling** (`maxSurge` S, `maxUnavailable` U): scale new up to the surge ceiling `N + S − oldDesired`,
  **wait for SC5 readiness**, then shrink old only enough to keep availability ≥ `N − U`
  (`oldDesired = min(oldDesired, max(0, (N−U) − newReady))`). With `U = 0` the old revision is held
  at N until the new is ready — availability never drops. Converges to new = N, old = 0.
- **Blue-green**: bring the **full** new revision up alongside the old; traffic stays 100% old until
  **all** new Cells are ready, then flips **atomically** to 100% new (never a split); the old is then
  torn down. Completes when the old is gone.
- **Canary**: ramp `update.canarySteps` (e.g. `[25, 50, 100]`). At step `P`, desire `ceil(N·P/100)`
  new and `N − that` old, with traffic weighted `P`/`100−P`; advance to the next step only when the
  current step's new Cells are ready. The final step (100) drains the old and completes.
- **Automatic rollback** — a per-rollout **progress deadline** (`update.progressDeadlineSeconds`,
  default 600s) measured from the rollout's start. If the new revision has not reached N ready when
  the deadline passes, the controller aborts and reverts as above; the old revision served the whole
  time (rolling holds old at `N−U`; blue-green never switches; canary keeps `100−P`% on old).

## Traffic consumption — the remaining wiring seam (surfaced, not hidden)

The controller **decides** the traffic split and writes `/traffic/<app>` (tested). The **data-plane
consumption** is the wiring left for the case-10 E2E:

- The SC5 `EndpointsLoop` currently admits every ready Cell regardless of revision. For blue-green's
  "only the switched revision serves" and canary's split, the endpoints loop must filter
  `/endpoints/<service>` by the admitted revisions in `/traffic/<app>`.
- **Canary weights need an LB knob the SC6 nginx provider does not emit:** per-backend `weight=` on
  the `upstream` (open-source nginx supports it — a renderer change) or an API provider
  (Hetzner/AWS) that programs weights directly. Until then canary ramps the **count** but not a true
  weighted split at the LB.

Both are gated with the case-10 E2E because they are only observable on a real multi-node data plane.

## `rollout undo` / `status`

`rolloutUndo(app, store)` (and the `sctl rollout undo` verb over the ControlClient) revert the
desired Deployment to the prior revision from `RolloutRecord.history` by writing that revision's
`/history` snapshot back to `/apps/<app>/spec`; the controller then rolls toward it like any new
target. `rollout pause/resume` is a noted seam (a `paused` flag on the record). `sctl logs` is a
noted seam (no log streaming).

## Multi-node QEMU harness (case 10) — conditional on C6, deferred

The end-to-end gate is a multi-node QEMU cluster: several `qemu-system-aarch64 -M virt` instances on
a shared virtual net (`-netdev socket` mesh), `-smp` per node, one or more `sctld` controllers
(SC2b) + a `slet` per node; `sctl apply` from the host brings a service up, a new revision flips
backends with no dropped requests, and a broken revision rolls back on its own. This is **gated on
C6** — the userland Cell supervisor that is `slet`'s data plane — plus the network + datafs and the
`sctld` production accept-loop (a seam in `control/FORMAT.md`). Until C6 lands the gate is deferred
and reported as a gap; building the harness is part of completing SC9. The control-plane logic it
would exercise — the rollout decisions, the per-revision placement, the rollback — is proven by the
host acceptance (`make rollout-test`, cases 3–9 + the real-scheduler integration check).
