# Package Manager Session Prompts

Copy-paste prompts for future Codex sessions that implement package management.
Each prompt intentionally covers one milestone. Do not combine them unless the
maintainer explicitly asks for a larger unstable branch.

## Prompt 1: P1 Host-Only `.swpkg` Format

```text
Read AGENTS.md, docs/PACKAGE_MANAGEMENT.md, docs/BASE_IMAGE.md, and the current
tools/basepack.swift implementation.

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

## Prompt 2: P2 VFS Package Image Overlay

```text
Read AGENTS.md, docs/PACKAGE_MANAGEMENT.md, docs/BASE_IMAGE.md, and the P1
package tooling commit.

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

## Prompt 3: P3 Persistent Package Store

```text
Read AGENTS.md and docs/PACKAGE_MANAGEMENT.md. Start from the P2 VFS package
overlay state.

Implement package-management milestone P3 only: a narrow persistent package
store with activation generations. Do not implement network repositories yet.

Requirements:
- design and document a minimal append-only package-store block format;
- store package blobs and extracted verified payload images by SHA-256;
- store activation manifests with generation numbers;
- atomically select the active generation;
- load active package payloads at boot;
- implement rollback to the previous generation;
- add QEMU tests for install generation, remove generation, boot persistence,
  and rollback.

Acceptance:
- `make test` passes;
- installing/removing a local package changes active generations;
- rollback restores the previous namespace;
- commit the milestone and stop for review.
```

## Prompt 4: P4 Local `/bin/pkg`

```text
Read AGENTS.md and docs/PACKAGE_MANAGEMENT.md. Start from the P3 package-store
state.

Implement package-management milestone P4 only: the target-side local package
manager `/bin/pkg`. Do not implement remote repository catalogs yet.

Required commands:
- `pkg install ./name.swpkg`
- `pkg list`
- `pkg info <name>`
- `pkg files <name>`
- `pkg remove <name>`
- `pkg history`
- `pkg rollback [generation]`

Requirements:
- keep output concise and scriptable;
- verify package hashes/signatures before activation;
- reject ABI, architecture, or static-linkage mismatches;
- produce clear exit codes for usage, not found, ABI mismatch, verification
  failure, and store failure;
- add QEMU tests that install `pkghello`, run it, list it, remove it, prove it is
  gone, and roll back.

Acceptance:
- `make test` passes;
- a user can install and remove a local `.swpkg` inside QEMU;
- commit the milestone and stop for review.
```

## Prompt 5: P5 Static HTTP Repository

```text
Read AGENTS.md and docs/PACKAGE_MANAGEMENT.md. Start from the P4 local `/bin/pkg`
state.

Implement package-management milestone P5 only: signed static repository
catalogs and network fetch. Use HTTP first; do not require HTTPS for integrity.

Required commands:
- `pkg update`
- `pkg search <text>`
- `pkg info <name>`
- `pkg install <name>`
- `pkg upgrade` if dependency/version metadata is ready; otherwise document why
  it is deferred.

Requirements:
- ship a pinned repository root key in the base image;
- verify signed catalog metadata;
- verify content-addressed `.swpkg` hashes;
- reject expired catalogs and wrong ABI/arch packages;
- add a host-side static repository fixture;
- add a QEMU test that starts a host HTTP server, runs `pkg update &&
  pkg install pkghello`, then executes `/usr/bin/pkghello`.

Acceptance:
- `make test` passes;
- installing from a static HTTP repository works end to end;
- verification failures are tested;
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
