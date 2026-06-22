# SwiftCube Design Note

> **Design note — RECORD ONLY. Not a Phase-1 item.** This records the agreed
> v1 design for SwiftCube, a Swift-native cluster orchestrator for fleets of
> SwiftOS machines. No kernel or userland code is scheduled by this note. The
> active plan remains Phase 1 in
> [Risk Remediation Roadmap](RISK_REMEDIATION_ROADMAP.md) — complete the
> capability/handle model (the C-arc), deliver SMP, move drivers toward
> restartable userland services. SwiftCube's data plane depends on that work
> reaching the Cell supervisor (C6); see "Dependencies" below. The SwiftCube
> milestone ladder (SC0–SC9) would be scheduled as its own track once the
> prerequisites land.

SwiftCube is a simplified-but-complete analogue of Kubernetes: a small,
Swift-everywhere control plane that schedules applications onto SwiftOS nodes,
keeps a desired state reconciled, and programs external load balancers. Its
distinguishing property is speed and near-zero footprint, achieved by **removing
the container abstraction**, not optimizing it.

## 1. Thesis: why this is faster than Docker

SwiftCube does not run containers. A deployed application instance is a **SwiftOS
Cell** — the kernel-native, capability-based isolation domain described in
[Architecture](ARCHITECTURE.md) ("Future isolation model: Cells") and decided as
a userland composition in [Capabilities](CAPABILITIES.md) (§5, milestone C6).

A Cell already bundles exactly what an orchestrated workload needs:

- a read-only base image plus a private tmpfs scratch (this is the "image");
- explicit device/file/IPC/clock/process (later network) capabilities;
- a resource accounting domain and limits, keyed by a per-process `CellId`;
- a VFS namespace and root view;
- lifecycle state (`created`, `running`, `stopping`, `dead`);
- observability counters and event streams.

Because there is no container runtime, no image layering, no union filesystem,
and no daemon, an instance starts in milliseconds, the read-only base is
content-addressed and shared (deduplicated on disk), and writable scratch is RAM
(tmpfs). This is the single decision that makes SwiftCube unlike "another
Kubernetes": **instance = Cell**, not a process and not a Linux container.

**Scope decision (v1): nodes are SwiftOS only.** Generic-Linux nodes are
explicitly out of scope for v1, because the speed and footprint thesis depends
on the Cell substrate.

## 2. Components and naming

The original sketch used `sctl` for both the controller and the CLI. They are
split here, mirroring Kubernetes but shorter:

| Role | Name | Kubernetes analogue |
| --- | --- | --- |
| CLI (Mac/Linux/Windows) | `sctl` | kubectl |
| Control-plane daemon | `sctld` | apiserver + scheduler + controller-manager, merged |
| Embedded store | `cubestore` | etcd |
| Node agent | `slet` | kubelet |

`sctld` is intentionally a single binary (API + scheduler + reconcilers +
LB programmer + embedded `cubestore`) for minimalism; internally it is a set of
reconcile loops. `slet` runs on every worker node.

```
sctl ──apply/get/watch──▶ sctld (×3, raft quorum, embeds cubestore)
                              │  desired state ▼   ▲ status
                              ▼                    │
   external LBs ◀─program─ endpoints loop      slet (node agent)
   (nginx/hetzner/aws)                          ├─ drives Cells (instances)
                                                ├─ node-proxy (east-west)
                                                └─ node-local PV on datafs
```

## 3. cubestore — the embedded store

cubestore is a library inside `sctld`: an MVCC key/value store with a watch API,
backed by a write-ahead log and snapshots on datafs.

**Consistency (decided): one Raft group, linearizable writes, leader
forwarding.** Any `sctld` accepts a request; writes are forwarded to the Raft
leader. Externally this looks like master-master (talk to any controller and the
change appears everywhere) while avoiding multi-leader conflict resolution. An
orchestrator needs strong consistency: two reconcile loops must not disagree
about where an instance is placed. True multi-leader/CRDT was rejected for v1.

- **Watch by key prefix** with a monotonic revision (MVCC). This is the
  backbone: every object is desired state in the store, and reconcilers pull
  reality toward it. The SPSC ring IPC primitive is the natural local transport;
  over the network it is a framed stream.
- **Leases/TTL** for node heartbeats and leader election.
- **Snapshot + log compaction**; **joint consensus** for adding/removing
  controllers. A minority partition goes read-only (it cannot reach the leader)
  to avoid split-braining the load balancer.

A note on the original "faster than Redis" goal: Redis is a heavily optimized
in-memory engine and we will not beat its raw ops/sec, nor do we need to. Our
real advantage is integrated consensus + watch + a purpose-fit schema in the
same process as the reconcile loops, with zero-copy framing and no text
serialization — none of which Redis provides (its replication is async and not
linearizable). The honest target is predictable low latency with built-in
consensus/watch, not "faster than Redis".

## 4. Reconciliation model

Everything is declarative desired state in cubestore, driven by control loops
(the Kubernetes model, deliberately reused):

1. `sctl apply` writes a `Deployment` (forwarded to leader, Raft-committed).
2. The scheduler loop expands it into N `Assignment{node, cell}` objects
   (spread across nodes, fit by cpu/mem).
3. The `slet` on each node watches its assignments and makes local reality match
   — creating, supervising, or tearing down Cells — and reports status back.
4. The endpoints loop watches healthy Cells and programs the load balancers.

Self-healing falls out of this for free: when a node's lease expires, its
assignments are re-placed elsewhere. This is the cluster-level form of the
"restartable userland services" arc in the roadmap.

## 5. Cells as the unit of deployment

A SwiftCube instance is a Cell. The manifest maps onto Cell properties almost
one-to-one:

| Manifest field | Cell property |
| --- | --- |
| `image` (signed packed base) | read-only base image |
| writable scratch | private tmpfs |
| `capabilities:` | explicit kernel capability set (not root-in-container) |
| `resources: {cpu, mem}` | resource domain keyed by `CellId` + limits |
| `volumes:` (`/data` PV) | a file/storage capability (handle) into the Cell |
| readiness/liveness, metrics | observability counters + event streams |
| instance status | lifecycle `created → running → stopping → dead` |

Because a Cell owns a *group* of processes, a single instance may host more than
one process sharing the same namespace and capabilities — the Pod-with-sidecars
pattern, available for free later. In v1 an instance is one Cell with one main
process.

**`slet` is a cluster-aware wrapper over the C6 Cell supervisor, not a
replacement for it.** C6 provides the *local* mechanism: given a Cell spec,
assemble job + handle set + resource domain + namespace, launch a process, and
supervise it. `slet` receives an `Assignment` from cubestore and calls that
local supervisor. SwiftCube does not re-implement Cell lifecycle; it consumes
C6. This keeps the orchestrator thin and avoids building a second isolation
model beside the kernel's.

## 6. Networking

- **North-south:** external load balancers, programmed by the endpoints loop
  via a provider plugin (see §8). SwiftCube does not ship its own LB in v1.
- **East-west (decided): flat L3 plus a node-local proxy.** A service registry
  lives in cubestore; each node runs a small proxy with a virtual service IP
  (a kube-proxy-lite). This is fast when nodes share a network segment. Overlay
  (WireGuard mesh) and per-Cell network isolation are deferred — the Cells model
  in [Architecture](ARCHITECTURE.md) explicitly postpones per-Cell network
  isolation beyond bring-up, so v1 relies on capability + namespace isolation,
  not network segmentation between instances.

## 7. Storage

**Decided: node-local sticky persistent volumes.** A volume is a node-local PV
on datafs (`/data`, honest `fsync`). A stateful instance is scheduled to the
node holding its volume and stays pinned there. Replicated/networked storage is
out of scope for v1 (it is a separate distributed-storage project).

**Fencing is SwiftCube's responsibility.** The Cell-as-composition decision
notes there is no single atomic kernel "destroy the Cell" operation; clean
teardown is a userland-supervisor duty. Therefore `slet` owns atomic instance
teardown and PV fencing: no process of an old Cell may still write to a volume
after a reschedule. This is why fencing lives in the orchestrator, not the
kernel.

## 8. Load-balancer providers and rollout

A provider is a plugin behind one interface:
`reconcile(service, desiredEndpoints)` — ensure a listener on the port, set the
backend pool to the healthy endpoints, configure a health check; idempotent,
rate-limited, retried. Initial providers: nginx (config generation + reload or
its API), Hetzner LB API, AWS NLB/ELB API.

Rollout is a state machine per deployment revision: rolling
(`maxSurge`/`maxUnavailable`), blue-green, and canary (backend weights), with
readiness as the gate before an endpoint is registered and automatic rollback if
readiness does not converge within a window. This is what makes deployment and
load-balancer switching automatic. The single-node precursor already exists in
the "AI serving cells" pattern in [Capabilities](CAPABILITIES.md) (one model
server per Cell, hot reload draining old generations); SwiftCube generalizes it
to the cluster, which lands squarely in the OS's application/AI-hosting profile.

## 9. Security and identity

- **Node join:** a bootstrap token issues the node a TLS certificate; all
  control traffic is mTLS under a controller CA.
- **Workload identity = capabilities:** manifest-declared permissions map to
  SwiftOS capability grants (`net.listen`, `fs.read`, device `.map`). Fine-
  grained kernel capabilities replace root-in-container — the second
  differentiator after Cells.
- **Secrets:** encrypted in cubestore (envelope encryption), delivered into the
  Cell via a tmpfs mount, never written to a persistent disk.
- **RBAC** for the API and CLI.

## 10. Manifest sketch (compose-like)

```yaml
app: web-api
image: registry.local/web-api@blake3:9f2c…     # content-addressed, signed
replicas: 4
update: { strategy: rolling, maxSurge: 1, maxUnavailable: 0 }
resources: { cpu: 100m, memory: 64Mi }
ports:
  - name: http
    container: 8080
    expose: { via: lb, provider: hetzner, listen: 443, protocol: https }
env: { LOG_LEVEL: info }
secrets: [ db-password ]                         # from cubestore, mounted in tmpfs
volumes:
  - { name: data, mount: /data, persistent: true, size: 1Gi }   # node-local PV, sticky
health:
  readiness: { http: /healthz, port: 8080, period: 1s }
  liveness:  { http: /livez,   port: 8080, period: 5s }
capabilities: [ net.listen:8080, fs.read:/etc/app ]   # kernel grants, not root
placement: { spread: node, nodeSelector: { zone: eu-central } }
```

## 11. Milestone ladder (SC0–SC9)

One submilestone at a time, each with a test and a commit, per the repository
workflow.

| # | Milestone | Test criterion | Kernel dependency |
| --- | --- | --- | --- |
| SC0 | cubestore single-node: MVCC KV + watch + WAL/snapshot on datafs | put/get/watch by revision; recover from WAL | none — host-testable |
| SC1 | Raft over cubestore: elections, replication, quorum of 3, forwarding | kill the leader, writes continue; talk-to-any forwards | none |
| SC2 | node join: bootstrap token, mTLS, lease/heartbeat | a node appears/expires in the store | network stack |
| SC3 | slet apply loop: create/destroy a Cell from a signed image, report status | assign 1 instance → Cell running; remove → gone; crash → restart | **yes — C-arc, esp. C6** |
| SC4 | scheduler: Deployment → N Assignments (spread + fit) | replicas=3 across 3 nodes; node down → reschedule | none |
| SC5 | readiness/liveness + endpoints loop | ready → endpoint registered | SC3 |
| SC6 | LB provider interface + nginx provider | endpoints → config + reload; rolling flips backends | SC5 |
| SC7 | east-west: service registry + node-proxy (virtual IP) | app A reaches app B by service name | SC3 |
| SC8 | node-local sticky PV on datafs + fencing | `/data` survives restart; instance pinned to node | datafs |
| SC9 | sctl CLI + manifest parser + rollout state machine | end-to-end on QEMU `-smp`, multi-node | all of the above |

**Dependencies.** SC0–SC2 and SC4 are decoupled from the in-flight kernel work
(they are networking and storage on existing primitives) and can proceed in
parallel with the roadmap. SC3 and everything downstream are gated on the kernel
reaching the C-arc, specifically C6 (the userland Cell supervisor): the data
plane spawns isolated, capability-scoped, accounted Cells, which is exactly what
C6 delivers.

## 12. Placement in the repository

SwiftCube is proposed as a new subtree in this repository (host CLI plus userland
services), because it co-evolves with the kernel's Cell and capability
primitives and should be built and tested by the same `make` chain in the same
QEMU. A sibling repository with a dependency on SwiftOS is the alternative; for
v1, keeping it in-tree is preferred.

## 13. Open design points (not yet decided)

- Exact cubestore key schema and the watch wire protocol.
- The rollout state machine in full (state transitions, rollback windows).
- The `Assignment` and endpoints object shapes.
- The provider-plugin API surface and failure/retry policy.

These are the natural next design tasks before SC0 begins.
