# SC9a — `sctl` CLI, manifest parser, and the manifest→object mapping

SC9 is the human entry point and the deployment orchestration that close the SC0–SC9 ladder. It
lands in two reviewable passes:

- **SC9a (this pass)** — the `sctl` CLI + the manifest parser/validator + the `apply`/`get`/
  `describe`/`scale`/`delete` round-trip. The `apply → schedule → run → ready → endpoint → LB`
  pipeline already works (SC3–SC7); SC9a adds the human entry point and validation on top.
- **SC9b (landed)** — the leader-gated rollout state machine (revisions, rolling/blue-green/canary,
  automatic rollback) under `swiftcube/sctld/rollout/` — see its
  [FORMAT.md](../sctld/rollout/FORMAT.md). Still seam: the remote mTLS `WireControlClient`, the
  data-plane consumption of `/traffic` (endpoints/LB weights), and the multi-node QEMU E2E (gated on
  C6). `sctl rollout status`/`undo` now drive the real rollout objects.

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

## The rollout state machine (SC9b)

Strategies (rolling/blue-green/canary), the phase transitions, the automatic-rollback deadline, the
per-revision `/schedrev` placement, and the multi-node QEMU harness are documented in the rollout
[FORMAT.md](../sctld/rollout/FORMAT.md). The `update:` block parsed here is persisted on the
DeploymentSpec, so the controller reads the strategy straight off `/apps/<app>/spec`.
