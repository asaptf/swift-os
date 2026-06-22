# SC7 — east-west service registry + node-proxy (format & model note)

This note records the `Service` shape, the proxy/resolution model **actually used**, and the
Cell-wiring seam. It is the SC7 counterpart to the SC5 `endpoints/FORMAT.md` and SC6
`lb/FORMAT.md`.

## What SC7 delivers

Internal (east-west) discovery + L4 load balancing — a kube-proxy-lite. App A reaches app B
**by service name** instead of chasing B's individual Cell addresses. Two pieces:

- a **service registry** in cubestore: `Service` objects + their ready endpoints (SC5);
- a per-node **node-proxy** that load-balances TCP connections for a service across its ready
  endpoints, plus a node-local **resolver** that maps a name to the proxy's address.

Acceptance (the ladder): *app A reaches app B by service name.*

## Networking primitives — verified vs. missing

Confirmed against the swift-os stack (`userland/lib/swift_user.h`) before building:

| Need | Present? | Consequence |
| --- | --- | --- |
| TCP listen/accept/connect/read/write/poll | **yes** (`swiftos_socket_stream`, `swiftos_listen`, `swiftos_accept`, `swiftos_connect`, `swiftos_poll`) | the userspace L4 proxy is buildable |
| packet redirection (DNAT / netfilter) | **no** | we use a **userspace L4 proxy**, not DNAT — the model the milestone assumes |
| bind/route a per-service **virtual IP** | **no** (`swiftos_bind` takes a port only; no route/iptables surface) | we fall back to a **node-local proxy address + a stable per-service port** |
| `shutdown(2)` (half-close a socket) | **no** | on-device the splice relays full-duplex and tears down with `close()`; half-close is a follow-on |
| active IPv6 connect | **no** (only passive v6 + active v4) | backends are dialed over IPv4 (as `NetProbe` already is) |

So SC7 uses the **userspace L4 proxy + node-local proxy address + stable per-service port**
model. This is exactly the documented fallback in the milestone ("if a stable vIP cannot be
bound/routed, fall back to a node-local proxy address + a stable local port mapping").

## The `Service` shape

`sctld/services/Service.swift`. Two cubestore object families:

- `/svcspec/<name>` — **desired** (optional): `ServiceSpec{ name, selector, servicePort }`. The
  explicit-service seam (written by `sctl`/SC9). A service that has ready endpoints but no
  explicit spec is **synthesized** by the reconciler from its endpoints (so "A reaches B by
  name" needs zero config — B's ready Cells imply a service B on B's port).
- `/services/<name>` — **materialized**: `Service{ name, selector, servicePort, clusterIP,
  proxyPort, allocIndex }`, written by the leader-only `ServiceReconciler`.

Allocation is **deterministic** (a new service gets the lowest free slot; new services are
processed in sorted name order) and **stable** (a service already in `/services` keeps its
`allocIndex`, read back each pass and never reshuffled). Each slot `i` maps to:

- `clusterIP = 10.96.0.0 + i` — the **recorded vIP** from the service range. **Not bound or
  routed today** (the stack has no vIP routing); it is the forward-compat **routing seam** for
  when a routable service range exists.
- `proxyPort = 30000 + i` — the **live** node-local port the node-proxy listens on for this
  service. This is the real, working mapping today.

`servicePort` is the logical cluster port (the manifest container port), recorded for the
routable-vIP future; `selector` is the `/endpoints` group backing the service (`== name` for
now; the seam for real label selectors).

## Resolution model actually used

`slet/resolver/Resolver.swift`. `resolve(name)` reads `/services/<name>` and returns a
`ServiceAddr{ host = node-local proxy host, port = proxyPort, servicePort, clusterIP }`.

Because there is no routable vIP, resolution returns **address + port**, not a bare IP — the
allocated node-local `proxyPort` **is** the per-service identity today. A classic wire-DNS A
record (IP only) cannot carry that port; a true DNS responder would need **SRV** records or a
routable vIP range. That responder is a documented seam (below), not built here; the resolution
logic both a lookup API and a future responder would share is what this file provides.

## node-proxy model

`slet/proxy/`. Level-triggered, like every reconciler in the system: `refresh()` re-reads
`/services` + `/endpoints` each pass and rebuilds listeners + target sets from scratch, over the
SC3 `StoreClient` seam (in-process cubestore in tests, the SC2 mTLS Agent on-device). Per
connection (`NodeProxy.accept` → `ConnectionPump`):

- **round-robin** across the ready endpoints (per-service cursor); optional **session
  affinity** (a non-empty client key hashes to a stable backend) and an optional **locality
  preference** seam (prefer a same-host endpoint);
- **dial-failover**: a backend whose connect fails is skipped for the next ready endpoint;
- **fast-fail**: zero ready (or all failing) ⇒ the client connection is **refused immediately**,
  never hung;
- **drain**: a removed endpoint simply leaves the target set — new connections never pick it,
  but an already-dialed in-flight connection is **not** torn down (the proxy holds no kill
  switch over a live backend conn), so it drains naturally.

The pure forwarding/LB/target logic (`NodeProxy`, `Balancer`, `ConnectionPump`) is Foundation-
free and tested deterministically over an in-memory `ProxyTransport`. The on-device sockets are
the `ProxyTransport` seam, with two bindings (the SC5 `FakeProber`/`NetProbe` split):

- `FakeTransport` (host tests): in-memory full-duplex conns + fake backend servers.
- `NetProxyTransport` (on-device): `swiftos_socket_stream`/`bind`/`listen`/`accept`/`connect`/
  `read`/`write`/`poll`, compiled into the `slet` ELF only.

## Cell-wiring seam (the SC3/C6 networking seam)

At Cell creation, `slet` must wire the Cell's namespace so a client inside it can reach the
resolver + the node-proxy. The mechanism (inject the node-proxy host + the resolver mapping into
the Cell's namespace/env) lands with **C6** — there is no real Cell network namespace to wire
until the userland Cell supervisor exists. Until then the resolver + proxy are exercised by the
host acceptance test; the **QEMU east-west gate** (two real Cells, A connects to B by service
name over virtio-net) is **deferred**, exactly as the SC3/SC5 on-device gates are.

## Seams left (out of scope for SC7, recorded)

- **per-Cell network isolation / network policy** — east-west is open in v1 (design §6); zero-
  trust segmentation is later.
- **UDP services** — TCP only here.
- **locality preference** — wired as a `BalancerConfig` flag + a coarse address-based node key;
  a real per-endpoint node tag is the follow-on (endpoints don't carry their node today).
- **routable vIP** — `clusterIP` is allocated/recorded but not bound/routed; needs a service
  route + the proxy binding the vIP (or DNAT) to drop the node-local-port indirection.
- **wire-DNS responder** — a UDP responder answering Cell lookups needs SRV (or a routable vIP)
  to express the per-service port; the resolution logic is here, the responder is not.
- **cross-DC overlay / WireGuard mesh** — deferred; v1 is flat L3 (design §6).
- **half-close** — on-device full-duplex relay until `close()`; needs `shutdown(2)` in the bridge.
