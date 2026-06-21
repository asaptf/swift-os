# SC6 — the LB provider interface, the nginx provider, and the programmer loop

This note records the SC6 wire shapes and the behavioral contract. SC6 programs an **external**
load balancer so a service's listener forwards to its **ready** endpoints. It consumes the SC5
`/endpoints/<service>` set (the backend pool) and the service's `expose` config, and makes the
LB's backend pool track the live ready set. We do **not** build an LB (design §1) — SC6 programs
one. The full rolling-update state machine across revisions is **SC9**; SC6 faithfully tracks
whatever ready set SC5 produces.

Code: the interface + loop in `swiftcube/sctld/lb/`, the nginx provider in
`swiftcube/sctld/lb/nginx/`. The loop, interface, and renderer are **Foundation-free** (they run
in `sctld`); only the concrete `NginxApplier` (shells out to a local nginx) and the host test
fakes use Foundation.

## Schema (two new object families)

SC2 owns `/nodes,/leases,/tokens`; SC3 owns `/assignments,/status/cells`; SC4 owns
`/apps,/pending`; SC5 owns `/endpoints`. SC6 adds:

| Key | Role | Object |
| --- | --- | --- |
| `/expose/<service>` | DESIRED: listener + health + provider for a service | `ServiceExpose` |
| `/lb/<service>` | OBSERVED: the programmer's result for a service | `LBStatusRecord` |

`ServiceExpose { service, provider, listenPort, proto(http/https/tcp), tlsCertRef, healthPath,
healthPort }` is the manifest `expose:` block (design §10). SC9's `sctl apply` will write it;
until then it is a first-class cubestore object so SC6 is independently testable.

`LBStatusRecord { service, generation, backends, healthy, lastError }`. `generation` is the
CRC32 of the config **actually active** on the LB — stable across no-op reconciles, changing only
when the live config changes. A failed `nginx -t`/reload sets `healthy=false` and puts the reason
in `lastError`; the bad config is **never** made active.

Both records are versioned little-endian ByteIO, like every other cubestore record.

## `LBProvider` contract (`LBProvider.swift`)

```
reconcile(desired: LBDesiredState) -> LBReconcileResult
remove(service: String)           -> LBReconcileResult
```

`LBDesiredState { service, listener, backends: [Endpoint], health }` — the listener (port,
protocol, optional TLS-cert ref), the backend pool (the SC5 ready endpoints), and the
health-check config. The shape is provider-agnostic so **Hetzner/AWS implement the same two
calls** against their cloud APIs instead of nginx config + reload.

Every provider upholds:

- **Idempotent** — diff the live config against desired; apply only the delta. An unchanged
  desired state causes no rewrite and no reload (`changed == false`).
- **Validate-before-commit** — a config that does not validate is never made active; the previous
  config stays and the error is reported. *Never take the LB down with a bad config.*
- **Reports status, never throws** — failure comes back as `error != nil`. Rate-limiting and
  retry-with-backoff are the **loop's** job (it owns the clock); the provider is the single
  idempotent apply step.

`LBReconcileResult { generation, changed, healthy, error }`. `generation` is the CRC32 of the
config now active (so on a failed apply it reflects the still-serving config, not the rejected
candidate).

## nginx provider = renderer + applier (`nginx/`)

**Renderer** (`NginxRenderer`, pure, golden-tested): service + endpoints → a config fragment —
an `upstream <svc>_pool { … }` block (the backend pool, one `server` line per ready endpoint with
passive-health `max_fails`/`fail_timeout`) and a `server { listen … location / { proxy_pass
http://<svc>_pool; … } }` block (the listener). Deterministic: backends are sorted by
`Endpoint.less`, so endpoint-set equality ⇒ config equality (the basis for the hash-compare).
`https` threads `tlsCertRef` into `ssl_certificate*` paths (cert **provisioning** is the
secrets/SC9 seam). The configured readiness `healthPath` is rendered as a comment — open-source
nginx has no active `health_check` (nginx-plus only), and the active readiness probe is owned by
SC5's probe runner.

**Empty-pool form (correctness rule):** nginx rejects an empty `upstream {}`, so **zero ready
endpoints** renders an explicit no-backends `server` that `return 503;` — a *valid* config that
keeps the listener up (clean 503) while a rollout momentarily empties the pool. Never a broken
upstream.

**Applier** (`ConfigApplier` seam → `NginxApplier`): the validate→swap→reload flow:

1. **stage** every active fragment + the candidate into a fresh temp tree with a generated main
   `nginx.conf` that `include`s it.
2. **validate** — `nginx -t -c <temp main>`. On failure the live config is untouched and the
   error is returned (validate-before-swap).
3. **swap** — write the candidate to `<confDir>/<service>.conf.tmp`, then `rename(2)` it over
   `<confDir>/<service>.conf`. The rename is **atomic** on one filesystem: a crash before it
   leaves the previous fragment intact; there is never a partial/active broken config.
4. **reload** — `nginx -s reload` (graceful: drains old workers, so a backend a rollout removed
   finishes its in-flight requests).

The provider hash-compares the rendered config against `applier.active(service)` and **skips the
apply entirely when unchanged** — *no needless reloads*. The applier targets a **local** nginx
(the SC6 testing target); delivering config to a **non-local** nginx (SSH / on-node agent / cloud
API) is the remote-delivery transport seam — a sibling `ConfigApplier` with the same three calls.

## LB programmer loop (`LBLoop.swift`)

Level-triggered: each pass re-reads all `/expose/<service>` + `/endpoints/<service>`, computes
`desiredState`, calls `provider.reconcile`, and CAS-writes `/lb/<service>` (skipping the write
when bytes are unchanged — no churn). Three properties on top:

- **Leader-only** — exactly one controller may program the external LB; two controllers reloading
  nginx with different configs is the failure mode to prevent. A follower returns immediately
  (reuses the SC2/SC4/SC5 `isLeader` signal). On handover the new leader re-derives everything
  from `/expose` + `/endpoints` + the applier's live config — no in-memory state is authoritative.
- **Debounced** — a changed desired-state fingerprint restarts a settle timer; the reconcile
  fires only once the set has been stable for `debounceWindow`, coalescing a burst of endpoint
  flips (a rollout churning the ready set) into **one** reload.
- **Backoff** — a provider/reload failure never crashes the loop. It is recorded in `/lb/<service>`
  and retried with capped exponential backoff; level-triggering re-applies the desired state on
  the next eligible pass until it sticks.

A `ServiceExpose` naming a provider this loop does not have (e.g. `hetzner`) is a config error,
reported in `/lb/<service>` — not a crash (the Hetzner/AWS seam).

## Tests

`make lb-test` — host acceptance, cases 1–10 (per the SC6 ladder): render+apply, golden config,
idempotency, rolling backend flip with exactly one reload, validate gating, atomic-swap crash,
debounce, retry/backoff, leader-only, empty pool. Foundation only in the harness.

## Seams left

- **SC9 (rollout):** the rolling-update state machine across revisions (`maxSurge`/
  `maxUnavailable`, blue-green, canary weights, readiness-gated rollback). SC6 tracks whatever
  ready set SC5 produces; it does not sequence revisions.
- **Hetzner / AWS providers:** implement `LBProvider` (`reconcile`/`remove`) against their cloud
  APIs; the loop and the desired-state shape are unchanged.
- **https cert provisioning:** `tlsCertRef` is threaded through to `ssl_certificate*`; minting and
  mounting the cert is the secrets/SC9 seam.
- **remote-delivery transport:** a `ConfigApplier` that programs a non-local nginx (SSH / agent /
  API). SC6's `NginxApplier` targets a local nginx.
- **on-device gate (QEMU):** program a real nginx on a node and `curl` through the listener to a
  ready Cell over virtio-net — conditional on a ported nginx + real Cells (C6); deferred, like
  SC3/SC5, not claimed.
