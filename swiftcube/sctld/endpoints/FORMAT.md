# SC5 — probes, the readiness↔liveness contract, and `/endpoints/<service>`

This note records the wire shapes and the behavioral contract SC5 introduces. SC6 (LB) and
SC7 (east-west) consume `/endpoints/<service>`; SC9 (rollout) gates on readiness. The probe
runner lives in `swiftcube/slet/probes/`; the endpoints loop in `swiftcube/sctld/endpoints/`.

## Probe spec (`ProbeSpec`, in `slet/probes/Probe.swift`)

Carried in the SC5 trailing section of `CellSpec` (so `slet` reads it off the Assignment it
already watches). One spec each for **readiness** and **liveness**.

| field | meaning |
| --- | --- |
| `kind` | `none` (unconfigured), `http` (GET path:port, 2xx/3xx ⇒ healthy), `tcp` (connect ⇒ healthy), `exec` (**C6 seam** — not run in SC5) |
| `port` | the port to hit |
| `httpPath` | http only, e.g. `/healthz` |
| `periodSeconds` | how often the probe runs |
| `timeoutSeconds` | a probe hanging past this counts as **one failure** |
| `initialDelaySeconds` | startup grace: no probe runs — and none can fail — before this elapses |
| `successThreshold` | consecutive successes to flip healthy (debounce) |
| `failureThreshold` | consecutive failures to flip unhealthy (debounce) |

Only `http` and `tcp` are active in SC5. `exec` is recorded so the wire format is stable but
the runner treats it as unconfigured (in-Cell command execution needs C6).

## Readiness vs. liveness contract (the core property)

The two probes are kept strictly distinct — this is what safe rollout (SC9) stands on:

- **readiness** answers *should this Cell receive traffic now?* A readiness failure (past
  `failureThreshold`) sets `ready=false`, so the endpoints loop drops the Cell from
  `/endpoints/<service>`. It **never restarts** the Cell; recovery flips it back, no churn.
- **liveness** answers *is this Cell wedged?* A liveness failure (past `failureThreshold`)
  routes through SC3's restart machinery. The fresh generation re-enters its `initialDelay`
  window and re-proves readiness, so the Cell is **out of endpoints while it restarts**.

Debounce, startup, and timeout: a single blip never flips state (N consecutive results do);
no probe runs or fails before `initialDelay`; a hung probe past `timeout` is one failure.

`slet` writes the result into `/status/cells/<cellId>` (SC3's record, extended in SC5 with
`service`, `address`, `port`). Readiness moves the `ready` bit; liveness drives restart.

## `/status/cells/<cellId>` additions (v2)

`CellStatusRecord` gains, after the v1 fields: `service` (the service the Cell backs;
service = app for now, with the explicit-service-object seam being this field), `address`
(the Cell's reachable host as `slet` reports it), and `port`. v1 records decode with these
empty/zero. The reachable `address` is whatever `slet` reports — SC7 fills in the real
flat-L3 Cell address vs. node-IP + mapped port; SC5 just propagates and groups it.

## `/endpoints/<service>` (`EndpointSet`, in `sctld/endpoints/Endpoint.swift`)

One key per service. The value is a versioned, **deterministically sorted** set:

```
EndpointSet { service: String, endpoints: [Endpoint{ cellId, address, port }] }
            // endpoints sorted by (cellId, address, port)
```

Written by the **leader-only**, **level-triggered** endpoints loop. Each pass it re-reads
all `/status/cells/`, keeps only Cells that are `ready ∧ phase==running ∧ have a non-empty
address:port`, groups them by `service`, and CAS-writes each set — skipping the write when
the bytes are unchanged (so a reconnect/restart never churns a stable set). A service whose
last ready Cell goes away has its key deleted. Endpoints are never registered for a Cell
that is not ready: **only ready → endpoint** is the invariant.

## Seams left

- **SC6 (LB):** consumes `/endpoints/<service>` to program backend pools. SC5 stops at
  writing the key.
- **SC7 (east-west / node-proxy):** consumes endpoints and fills in the real reachable
  `address:port` (flat L3 Cell address vs. node IP + mapped port). SC5 propagates whatever
  `slet` reports.
- **SC9 (rollout):** gates surge/drain on readiness — the `ready` bit this milestone makes
  honest.
- **exec probes:** need in-Cell command execution via C6; `ProbeKind.exec` is the placeholder.
- **on-device gate:** a real Cell becoming ready via an http probe over virtio-net is gated
  on C6 (no real Cells yet), like SC3 — deferred, not claimed. `NetProbe` is the real prober
  that lights up when C6 lands.
