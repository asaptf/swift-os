# Agent-Operated Workflow

> **Positioning note — HYPOTHESIS, not a shipped claim.** This records a stance
> about *who operates the system* and the design requirements that follow from
> it. It schedules no kernel or userland work. Nothing here may be advertised
> until the benchmark in §6 has been run; per
> [Philosophy](PHILOSOPHY.md), we advertise only checked behavior. The active
> plan remains Phase 1 in
> [Risk Remediation Roadmap](RISK_REMEDIATION_ROADMAP.md).

## 1. Thesis

SwiftOS's flagship profile is application and AI hosting. "AI" there has two
distinct meanings, and conflating them makes both claims mushy:

- **AI as the workload** — serving models on the machine. This is
  [AI Hosting Guide](AI_HOSTING_GUIDE.md), and it is the meaning used elsewhere
  in the documentation.
- **AI as the operator** — an autonomous coding agent that writes an
  application, deploys it, tests it, reads the result, and iterates, with no
  human in the loop per cycle. That is this document.

The thesis: **an autonomous agent needs an execution substrate that is cheap,
deterministic, disposable, and machine-legible.** SwiftOS's immutable signed
base, Cells as capability-scoped isolation domains, and declarative SwiftCube
manifests are that substrate — and they are that substrate for the same reason
they are good for hosting: the properties are structural, not features added for
agents.

Latency is *one* of the four properties, and not the first.

## 2. The premise we do not use

A tempting formulation is "container deployment is slow, so the agent idles, and
that idle time is lost development time." We reject that framing because it is
weak on its own terms:

- The dominant cost in an agent's iteration is usually the **build**: dependency
  resolution, compilation, image assembly, registry push. Removing the container
  abstraction does not remove any of those.
- Container *start* is already fast in the incumbent stacks. The recoverable
  time is in orchestrated rollout, readiness gating, and teardown — a real cost,
  but a smaller one than the framing implies.
- "The agent waits" is a cost, not a blocker: agents overlap work, and wall
  clock alone is a weak argument.

The honest version of the same intuition is stronger: long, untrustworthy
feedback loops degrade an agent's *decisions*, not just its throughput. An agent
that cannot cheaply obtain a clean environment batches speculative changes; an
agent that cannot trust an environment's provenance cannot distinguish "my code
is wrong" from "the environment drifted." Both produce compounding errors that
no amount of parallelism recovers.

## 3. The four properties

| Property | Why an agent needs it | Mechanism in SwiftOS | Status |
| --- | --- | --- | --- |
| **Deterministic** | The agent must attribute a failure to its own change, not to environment drift. Provenance must be checkable, not assumed. | Immutable signed base image, hash-identified and content-addressed; no mutable root updates | [Base Image](BASE_IMAGE.md), [Update Store](UPDATE_STORE.md) — exists |
| **Disposable** | Cheap create/destroy makes "one fresh environment per test" affordable, which is what removes shared-state flakiness. | Cell = read-only base + private tmpfs scratch + resource domain; explicit teardown | [Capabilities](CAPABILITIES.md) §5–§6 — kernel side exists (`make c6-cell-create-test`) |
| **Safely isolated** | An agent executes code it just generated. Confinement must not rest on "root inside the sandbox." | One address space per process, capability/principal authorization, namespace-root confinement | [Security Guide](SECURITY_GUIDE.md), [Architecture](ARCHITECTURE.md) — exists |
| **Machine-legible** | The agent is the reader. It needs an oracle ("is it ready, is it healthy, what changed"), not screen-scraping and sleeps. | Readiness/liveness probes, endpoints loop, kernel counters, structured log markers | [Observability Guide](OBSERVABILITY_GUIDE.md), [SwiftCube Design](SWIFTCUBE_DESIGN.md) §5, §8 — partial; see §5 |

## 4. The headwind we state up front

**SwiftOS has no Linux ABI, and that is exactly the property that makes the
incumbent stacks useful to an agent.** Docker's value to an autonomous agent is
portability: an arbitrary image runs unchanged. We trade that away deliberately
(see [Philosophy](PHILOSOPHY.md), "Compatibility stance"). Deployment onto
SwiftOS is cheap; *arriving* on SwiftOS is not — dependencies are rebuilt from
source against our ABI ([Porting Guide](PORTING_GUIDE.md)).

Therefore the claim is scoped, and must stay scoped whenever it is repeated:

- **In scope:** applications an agent writes from scratch against runtimes we
  already carry — native Embedded Swift programs, and Node.js where the port
  covers what the application needs
  ([Compatibility Guide](COMPATIBILITY_GUIDE.md)).
- **Out of scope:** running arbitrary existing container images, and any
  suggestion that OCI or Linux-ABI compatibility be added to serve this
  positioning. That trade is settled and this note does not reopen it.

## 5. Design requirements that follow

These are the useful output of the thesis: concrete, testable requirements, each
one a thing an agent cannot work around from the outside.

1. **Machine-readable command output.** `sctl` and the observability surfaces
   should emit structured output (a stable, parseable form) alongside their
   human text, so an agent parses a contract rather than a layout. Today `sctl`
   is text-only — this is the largest concrete gap.
2. **Readiness as the oracle.** Every "is it up" question must be answerable by
   a probe with a definite verdict, so no caller needs a timed sleep. The
   readiness/liveness and endpoints loops already model this
   ([SwiftCube Design](SWIFTCUBE_DESIGN.md) §5, §8); the requirement is that
   nothing outside them reintroduces sleeps.
3. **Ephemeral environments as a first-class verb.** Create a scoped Cell from a
   signed image, run a check, destroy it, reclaim the resource domain — one
   command, no residue. Teardown is a supervisor duty, not a kernel primitive
   ([Capabilities](CAPABILITIES.md) §5.3), so this requirement lands on the
   supervisor and on `slet`.
4. **Diffable environment identity.** An agent should be able to compare two
   environments by hash rather than by inspection: image digest, manifest
   revision, and package overlay must each be reportable identities.
5. **Honest failure surfaces.** Errors must be distinguishable by kind
   (capability denied, resource exhausted, image unverified, probe never
   converged), because an agent's next action differs per kind. Undifferentiated
   failure is the most expensive output a substrate can give an agent.

Requirements 1 and 4 are gaps. 2, 3, and 5 are partly carried by existing work
and mostly need to not be eroded.

## 6. What must be measured before this is advertised

The positioning rests on a latency and cost claim that is currently
**unmeasured**. SwiftCube's control plane (SC0–SC9b) is implemented and covered
host-side by `make swiftcube-test`, but the on-device data-plane wiring is not
finished: the C6 adapter reports `.unavailable` rather than creating a Cell, so
no instance has yet been started on hardware through the orchestrator. Until
that lands there is no number to quote.

The falsifiable benchmark, once it can run:

| Measurement | Definition | Baseline to compare against |
| --- | --- | --- |
| Instance start | `sctl apply` → first successful request served | `docker run` on the same host class; a Kubernetes rolling update |
| Environment churn | create + verify + destroy of N isolated instances, sequential and concurrent | the same loop with containers |
| Steady-state footprint | resident memory and CPU of the control plane plus one idle instance | the incumbent agent + runtime pair |
| Agent-visible loop | commit → environment up → check verdict returned, with no sleeps | the same loop on a container stack |

If instance start and environment churn are not *substantially* better — not
marginally — the honest conclusion is that this positioning does not carry its
weight, and the note should be revised rather than defended.

## 7. Non-goals

- No OCI or Docker image compatibility, and no Linux syscall ABI. See
  [Philosophy](PHILOSOPHY.md), "Compatibility stance."
- No agent-specific syscalls, and no privileged "agent mode." An agent is an
  ordinary principal with an explicit capability set; if it needs authority that
  the capability model cannot express, that is a finding about the capability
  model.
- No claim that this replaces a developer's local toolchain. The substrate is
  where the application runs and is verified, not where it is compiled.
