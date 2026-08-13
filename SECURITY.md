<!-- SPDX-License-Identifier: Apache-2.0 -->

# Security Policy

## Scope, honestly stated

swift-os is a learning-first operating system under active development. It is
**not production software**, and the [README](README.md) says so deliberately.
Please do not deploy it where a compromise would matter.

That said, the security model is a first-class design goal, not decoration:
processes are isolated by the MMU with one address space each, authorization is a
principal plus a capability mask (never `uid == 0`), the base image is immutable
and signed, and the syscall surface is deliberately small. Bugs that break those
properties are real bugs and we want to hear about them.

The current guarantees and — just as important — the current *limits* are
documented in [docs/SECURITY_GUIDE.md](docs/SECURITY_GUIDE.md) and
[docs/CAPABILITIES.md](docs/CAPABILITIES.md). Known-incomplete areas (the
handle-based capability model, driver confinement, TLS in userland) are tracked in
[docs/RISK_REMEDIATION_ROADMAP.md](docs/RISK_REMEDIATION_ROADMAP.md). If something
is listed there as future work, it is a known gap rather than a vulnerability —
but a *concrete* exploit against it is still worth reporting, because it tells us
how urgent the gap is.

## Reporting a vulnerability

**Please do not open a public issue for a vulnerability.**

Use GitHub's private reporting: **Security → Advisories → Report a vulnerability**
on <https://github.com/asaptf/swift-os/security/advisories/new>. That channel is
private to the maintainer until an advisory is published.

Helpful reports include:

- what property breaks (isolation, capability enforcement, image integrity,
  memory safety in the kernel, the network stack);
- the boot profile and exact `make` invocation you used;
- a reproduction — a serial log, a test script, or a small program is ideal;
- the toolchain, QEMU version and host (macOS Apple Silicon or Linux), because
  bring-up behaviour differs across them.

Expect an acknowledgement within about a week. This is a one-maintainer project,
so please allow reasonable time for a fix before publishing details; credit is
given in the advisory and the commit unless you prefer otherwise.

## Supported versions

Development happens on `main`, and there are no long-lived release branches yet:
fixes land on `main`. There is no backport channel — if you are running an older
checkout, update it.

## Out of scope

- The deliberate non-goals in the [README](README.md#non-goals-minimalism-by-removing-legacy)
  (no Linux ABI, no dynamic linking, no journaling guarantees). These are design
  boundaries, not defects.
- Vulnerabilities in bundled third-party components (busybox, the newlib port,
  and the cross-built ports) that are already public upstream — report those
  upstream; we track the pinned versions.
- The demo credentials (`root` / `swordfish`) documented in the guides and used by
  the test harness. They are a bring-up convenience in a non-production system,
  not a leaked secret.
- Anything requiring physical access to the host, or a compromised host
  toolchain — the trusted computing base includes the machine that builds the
  image.
