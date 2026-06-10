# Package Manager Session Prompts

Copy-paste prompts for future Codex sessions that implement package management.
Each prompt intentionally covers one milestone. Do not combine them unless the
maintainer explicitly asks for a larger unstable branch.

P1, P2, P3a boot activation, and the narrow P3b/P4-local install path are
already implemented in the current tree. `/bin/pkg install FILE` and `pkg list`
work for the local `pkghello.swpkg` smoke test. The next implementation prompt
is Prompt 4b if you want to finish local remove/rollback/history, or Prompt 5 if
you intentionally want to start repository download work first.

## Prompt 1: P1 Host-Only `.swpkg` Format (Historical)

```text
Read AGENTS.md, docs/PACKAGE_MANAGEMENT.md, docs/BASE_IMAGE.md, and the current
tools/basepack.swift implementation.

This prompt is historical. Use it only if P1 needs to be recreated from scratch.

Implement package-management milestone P1 only: a host-only `.swpkg` artifact
format and verifier. Do not change the kernel or VFS yet.

Requirements:
- define a small `.swpkg` v1 container with magic/version/header lengths;
- store a package manifest and an uncompressed packed read-only payload image;
- reuse or carefully factor the existing packed image builder instead of
  duplicating fragile file-walking logic;
- add a host tool under tools/ that can create, inspect, and verify a sample
  package;
- add a sample package fixture for `/usr/bin/pkghello`;
- add host tests that verify manifest parsing, payload hash validation, wrong
  hash rejection, and deterministic output;
- wire the new host test into `make test` without weakening existing tests.

Acceptance:
- `make test` passes;
- the tool can build a deterministic `.swpkg` for `pkghello`;
- verification fails on a corrupted manifest or payload;
- commit the milestone and stop for review.
```

## Prompt 2: P2 VFS Package Image Overlay (Historical)

```text
Read AGENTS.md, docs/PACKAGE_MANAGEMENT.md, docs/BASE_IMAGE.md, and the P1
package tooling commit.

This prompt is historical. Use it only if P2 needs to be recreated from scratch.

Implement package-management milestone P2 only: mount one or more verified
package payload images as read-only VFS overlays. Do not implement downloads,
persistent package storage, or dependency solving yet.

Requirements:
- teach the VFS to serve files from the base image plus package payload images;
- keep overlay priority deterministic and documented;
- reject conflicting package paths unless the test explicitly declares the
  expected priority;
- keep `/usr` package paths separate from boot-critical base files;
- add a QEMU test that boots with a sample package payload and runs
  `/usr/bin/pkghello`;
- preserve all existing base-image and disk-exec behavior.

Acceptance:
- `make test` passes;
- QEMU can execute `/usr/bin/pkghello` from a package image;
- a conflict test proves deterministic rejection or priority;
- commit the milestone and stop for review.
```

## Prompt 3: P3b Target-Writable Package Store (Historical)

```text
Read AGENTS.md, docs/PACKAGE_MANAGEMENT.md, and docs/PKGSTORE_FORMAT.md. Start
from the P3a package-store boot-activation state.

This prompt is historical. Use it only if P3b needs to be recreated from
scratch.

Implement package-management milestone P3b only: make the existing package store
target-writable and support active-generation updates from EL0. Do not implement
network repositories yet.

Requirements:
- add minimal virtio-blk write support for the selected package-store device;
- keep base and package payload disks read-only by policy;
- expose coarse package-store syscalls for appending a verified payload,
  appending an activation, switching the active generation, listing history, and
  selecting an older generation;
- preserve the P3a boot path that loads active payloads from `SWPKGST1`;
- implement rollback to the previous generation;
- add QEMU tests for store write persistence, remove generation, boot
  persistence, and rollback.

Acceptance:
- `make test` passes;
- a target-side helper or `/bin/pkg install FILE` can add `pkghello` by changing
  active generations;
- commit the milestone and stop for review.
```

## Prompt 4b: Finish Local `/bin/pkg`

```text
Read AGENTS.md and docs/PACKAGE_MANAGEMENT.md. Start from the P3 package-store
state where `/bin/pkg install FILE` and `pkg list` already work for
`pkghello.swpkg`.

Implement the remaining local package-manager milestone only. Do not implement
remote repository catalogs yet.

Required commands:
- `pkg info <name>`
- `pkg files <name>`
- `pkg remove <name>`
- `pkg history`
- `pkg rollback [generation]`

Requirements:
- keep output concise and scriptable;
- preserve the existing local install/list flow;
- add installed package metadata enough for info/files/history;
- make remove a new activation generation without the package;
- make rollback select an older activation generation;
- reject ABI, architecture, or static-linkage mismatches with focused tests;
- produce clear exit codes for usage, not found, ABI mismatch, verification
  failure, and store failure;
- add QEMU tests that install `pkghello`, run it, list it, remove it, prove it is
  gone, and roll back.

Acceptance:
- `make test` passes;
- a user can install, inspect, remove, and roll back a local `.swpkg` inside
  QEMU;
- commit the milestone and stop for review.
```

## Prompt 5: P5 Static HTTP Repository

```text
Read AGENTS.md, docs/PACKAGE_MANAGEMENT.md, and docs/PKGREPO_FORMAT.md.
Start from the current P5c state: `tools/pkgrepo.swift` builds a signed static
HTTP repository fixture, `/bin/pkg repo set`, `pkg update [URL]`,
`search/info/install NAME` work for `pkghello`, and
`make package-repo-install-test` covers expired catalogs, wrong-arch catalogs,
package SHA-256 mismatch, default repo config, dependency resolution
(`pkgdep -> pkghello`), and the positive install path.

Harden package-management milestone P5 without jumping to the ports tree yet.
Keep HTTP acceptable for transport integrity because catalogs are signed and
packages are content-addressed.

Focus:
- add version-constraint validation for dependency metadata;
- design and start the streaming package download/store path;
- prepare the transaction shape needed for `pkg upgrade`;
- keep `pkg update URL`, `pkg search <text>`, `pkg info <name>`, and
  `pkg install <name>` working;
- leave `pkg upgrade` deferred unless dependency/version metadata is ready.

Requirements:
- do not break local `pkg install FILE`;
- do not add a large JSON/TLS dependency to `/bin/pkg`;
- keep parsers bounded and canonical;
- update docs/PKGREPO_FORMAT.md if the catalog shape changes.

Acceptance:
- `make test` passes;
- `make package-repo-install-test` passes;
- version-constraint/streaming changes are covered by focused tests;
- commit the milestone and stop for review.
```

## Prompt 6: Create `swift-os-ports`

```text
Create the `swift-os-ports` repository described in
docs/PACKAGE_MANAGEMENT.md. Keep the first version small and useful.

Requirements:
- scaffold `ports/`, `Mk/`, `tools/`, and `ci/`;
- add `swport` with `new`, `fetch`, `build`, `test`, `package`, and
  `bulk --changed` commands;
- support one simple real port, preferably `lang/lua`;
- support a local sample `pkghello` port for CI speed;
- add GitHub Actions that lint recipes, build changed ports, upload preview
  `.swpkg` artifacts, and run QEMU smoke tests through the current swift-os
  image;
- document how maintainers add or bump a port.

Acceptance:
- CI builds `pkghello` and `lua`;
- generated packages can be installed by the current `/bin/pkg`;
- commit and stop for review before adding more ports.
```

## Prompt 7: Create `swift-os-packages`

```text
Create the `swift-os-packages` repository described in
docs/PACKAGE_MANAGEMENT.md. This repository owns binary repository publication
metadata and automation, not source port recipes.

Requirements:
- define the public repository layout for `aarch64/current`;
- add scripts or workflows that receive `.swpkg` artifacts, address them by
  SHA-256, regenerate `catalog.json`, sign the catalog, and publish a new
  generation;
- keep package blobs on GitHub Releases or the chosen object host;
- keep generated catalogs reviewable in git;
- document key handling, channel policy, and rollback to an older catalog
  generation.

Acceptance:
- a package built from `swift-os-ports` can be published to `current`;
- a fresh swift-os image can run `pkg update && pkg install lua`;
- commit and stop for review.
```
