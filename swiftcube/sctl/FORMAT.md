# SC9a — `sctl` CLI, manifest parser, and the manifest→object mapping

SC9 is the human entry point and the deployment orchestration that close the SC0–SC9 ladder. It
lands in two reviewable passes:

- **SC9a (this pass)** — the `sctl` CLI + the manifest parser/validator + the `apply`/`get`/
  `describe`/`scale`/`delete` round-trip. The `apply → schedule → run → ready → endpoint → LB`
  pipeline already works (SC3–SC7); SC9a adds the human entry point and validation on top.
- **SC9b (next)** — the leader-gated rollout state machine (revisions, rolling/blue-green/canary,
  automatic rollback) under `swiftcube/sctld/rollout/`, the remote mTLS `WireControlClient`, and the
  multi-node QEMU end-to-end harness. The forward design is sketched at the end of this note so SC9b
  has a spec.

## Components

| Path | Role | Foundation? |
| --- | --- | --- |
| `swiftcube/manifest/Yaml.swift` | a tiny YAML-subset parser (the §10 forms only) | no — server-linked |
| `swiftcube/manifest/Manifest.swift` | the typed manifest + the mapping to cubestore objects | no — server-linked |
| `swiftcube/manifest/ManifestParser.swift` | YAML tree → typed `Manifest`, with validation | no — server-linked |
| `swiftcube/sctl/ControlClient.swift` | the transport seam the command layer talks to | no |
| `swiftcube/sctl/StoreControlClient.swift` | in-process `ControlClient` over a cubestore | no |
| `swiftcube/sctl/Command.swift` | verb dispatch, validation, output formatting | no |
| `swiftcube/sctl/Config.swift` | the `sctl` config (kubeconfig analog) | no (parse); host reads the file |
| `swiftcube/sctl/main.swift` | the host binary shell (config + file I/O + client + exit) | yes (host only) |

The manifest parser/validator is **Foundation-free on purpose**: `sctld` links the same three files
to re-validate a submitted manifest, so a malformed manifest is rejected identically at the CLI and
at the controller.

## Manifest → object mapping

One `sctl apply` of a §10 manifest writes the desired-state objects the lower milestones already
reconcile:

| Manifest | cubestore key | Object | Consumed by |
| --- | --- | --- | --- |
| the whole deployment | `/apps/<app>/spec` | `DeploymentSpec` | SC4 scheduler |
| the primary container port | `/svcspec/<app>` | `ServiceSpec` | SC7 east-west registry |
| a port's `expose:` block (via `lb`) | `/expose/<app>` | `ServiceExpose` | SC6 LB programmer |

Field-level mapping:

- `image: <ref>@<algo>:<hex>` → `ImageRef.digest` (the decoded 32-byte content address). The
  detached image **signature** is staged by the registry (the image-registry seam, out of scope for
  SC9), so `ImageRef.signature` is empty until a registry stages it. The digest must decode to 32
  bytes — the implemented CAS width — regardless of the `<algo>` label.
- `resources: { cpu, memory }` → BOTH the scheduling `request` and the Cell's enforced limit
  (`request == limit` in v1). `cpu` accepts `100m` / `1` / `1.5`; `memory` accepts `64Mi` / `1Gi` /
  decimal `K`/`M`/`G` / bare bytes.
- `command` → the Cell's argv; `env` (a `KEY: value` map) → `KEY=VALUE` entries; `capabilities` →
  the kernel capability grant set (`category.action[:arg]`, validated).
- `ports[].container` → the Cell's endpoint port + the east-west `servicePort`; the first port with
  an `expose:` block becomes `/expose/<app>` (listen port/protocol/cert + provider).
- `health.readiness` / `health.liveness` → SC5 `ProbeSpec`s. To carry them (and the service/port)
  from a manifest all the way to each replica, **`CellTemplate` grew an SC9 trailing section**
  (`service`, `port`, `readiness`, `liveness`) mirroring `CellSpec`'s SC5 section — appended after
  the v1 fields and decoded EOF-tolerantly, so every SC3/SC4/SC8 record still round-trips (all
  SC0–SC8 tests stay green).
- `volumes[]` (a `persistent` one) → the `VolumeMount` slot (SC8 node-local sticky PV).
- `placement.nodeSelector: { k: v }` → required `"k=v"` labels; `placement.spread` is recorded.

### Revision discipline (the rollout seam)

The Deployment `revision` is the spec identity SC9b's rollout keys on. `apply` assigns it:

- **new app** → revision `1`;
- **template change** (anything except `replicas`) → `old.revision + 1`;
- **pure replica change** (a re-apply or `scale` differing only in count) → revision **unchanged**;
- **identical manifest** → no write (idempotent).

`scale` therefore never bumps the revision (a replica count is not a template change); a CAS on the
read revision guards against clobbering a concurrent writer. This matches Kubernetes: scaling does
not create a new rollout revision.

## CLI verbs

```
sctl apply -f <manifest.yaml>
sctl get <deployments|services|endpoints|nodes|expose|pending>
sctl describe <deployment|service|expose> <name>
sctl scale <app> --replicas=N
sctl delete <deployment|service|expose> <name>
sctl rollout status <app>      # read-only view; the controller is SC9b
```

`rollout undo|pause|resume` and `token create` are present but return a clear **SC9b seam** message
(they need the rollout state machine and a token-mint RPC). `sctl logs` is a noted seam (no log
streaming yet). Command dispatch, validation, and formatting are tested host-side over a fake
`ControlClient` (`sctl-test`, case 2), independent of any transport.

## Config & transport

The `sctl` config (kubeconfig analog) sets either `local: <statedir>` (single-node/dev over an
on-disk cubestore — fully wired today) or a remote `endpoint:` + client cert/key/CA for the SC2
mTLS control API. **The remote `WireControlClient` is the SC9b seam:** the SC2 RPC set has
put/range/casPut but no delete opcode, and `sctld`'s production accept-loop is itself a seam (it
runs a self-test on-device, not a server loop — see `control/FORMAT.md`). So `sctl --local` is the
client SC9a can drive end to end; a remote endpoint prints the gap and exits non-zero rather than
pretend. The TLS primitives `sctl` will reuse are the same sans-I/O `MutualTLS` + `Channel` + `Agent`
the node uses (`control/`), which already do a real P-256 mTLS handshake in host tests.

## SC9b forward design (recorded, not built here)

**`/rollouts/<app>`** — the rollout object: strategy, the ordered revision history (for `undo`), and
per-revision `desired/updated/ready/available` counts + a phase. **Phases:**
`Progressing → Complete`, or `Progressing → Failed` (deadline) with `RollingBack` while reverting.

- **Rolling** (`maxSurge`/`maxUnavailable`): step new-revision replicas up within surge, **wait for
  SC5 readiness**, step old-revision replicas down within unavailable; never fewer than
  `desired − maxUnavailable` ready; converge to new=N, old=0.
- **Blue-green**: bring the full new revision up alongside the old; once **all** new Cells are ready,
  atomically switch `/endpoints` + the LB from old→new; then tear the old down. No mixed traffic.
- **Canary**: bring a small new fraction up, route a traffic **percentage** via LB backend
  **weights**, ramp to 100% while scaling the old down. *LB-weight gap to surface:* the SC6 nginx
  provider tracks a ready backend pool but does not emit per-backend `weight=`; canary weighting
  needs that knob (open-source nginx supports `weight` on `upstream` servers — a renderer change) or
  an API provider (Hetzner/AWS) that programs weights directly.
- **Automatic rollback**: a per-rollout **progress deadline** (`update.progressDeadlineSeconds`,
  default 600s). If the new revision does not reach its ready target within the window (or trips a
  failure threshold), abort and revert (new→0, old→N) and mark `Failed` — the old revision stays
  serving throughout.

The machine is **leader-only and level-triggered** like every other reconciler: each pass re-reads
the world from cubestore and steps at most once, so a controller restart/reconnect resumes from
store state without double-stepping.

**Multi-node QEMU harness (SC9b, case 10):** multiple QEMU `virt` instances on a shared virtual net
(`-netdev socket` mesh), `-smp` per node, one or more `sctld` controllers (SC2b) + `slet` per node;
`sctl apply` from the host brings a service up, a new revision flips backends with no dropped
requests, and a broken revision rolls back on its own. This gate is **conditional on C6** (the
userland Cell supervisor — `slet`'s data plane) plus network + datafs; until C6 lands it is deferred
and reported as a gap, and building the harness is itself part of SC9b.
