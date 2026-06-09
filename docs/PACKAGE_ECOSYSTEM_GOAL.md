# Package Ecosystem Goal

Active goal: build the swift-os package ecosystem until a hosted binary
repository can serve packages that `/bin/pkg` downloads and installs on
swift-os.

## Target Outcome

The user-facing target is:

```sh
pkg update
pkg search nginx
pkg install lua
pkg install nginx
```

For the first public end-to-end proof, use a small real package before large
server stacks:

```sh
pkg update
pkg install lua
lua -v
```

Then expand to web-hosting packages:

```sh
pkg install nginx acme-client postgresql node openjdk swift mc
```

## Current State

- P1 host package artifact tooling is present:
  - `tools/swpkg.swift`;
  - `tools/packfs.swift`;
  - `docs/SWPKG_FORMAT.md`;
  - `tests/swpkg_tool_test.swift`.
- `.swpkg` can be created, inspected, verified, and host-tested.
- P2 is now the next implementation milestone: VFS package payload overlays.
- No target-side `/bin/pkg`, package store, repository catalog, or hosted binary
  repository exists yet.

## Workstreams

The package ecosystem splits into four independent workstreams that can run in
parallel.

### 1. Package Manager Path

Lives in `swift-os`.

Milestones:

1. P2: mount verified package payload images as read-only VFS overlays.
2. P3: persistent package store and activation generations.
3. P4: target-side `/bin/pkg install ./name.swpkg`.
4. P5: signed static HTTP repository catalogs and network fetch.

### 2. Ports Catalog

Lives in `swift-os-ports` once that repository exists.

Outputs:

- prioritized server software catalog;
- one `Port.toml` per package;
- patches and static-link build flags;
- QEMU smoke tests;
- first real packages: `lua`, `zlib`, `ca-certificates`, then web stack
  packages.

### 3. Build Automation

Lives mostly in `swift-os-ports`.

Outputs:

- `swport new/fetch/build/test/package/bulk`;
- FreeBSD ports importer/scaffolder;
- deterministic build roots;
- CI for changed ports;
- QEMU smoke-test integration;
- `.swpkg` artifacts uploaded for PR review.

### 4. Repository Hosting

Lives in `swift-os-packages` plus the chosen static host.

Outputs:

- content-addressed package blob upload;
- signed `catalog.json`;
- channel layout such as `aarch64/current`;
- rollback to previous catalog generations;
- public repository URL configured in the base image.

## Deployment Inputs Needed

The final hosted deployment cannot be completed without external choices and
credentials. Required maintainer decisions:

- GitHub organization/account name for:
  - `swift-os-ports`;
  - `swift-os-packages`.
- Binary blob host:
  - GitHub Releases/Pages for bootstrap, or
  - S3/R2/other object storage for larger packages.
- Public package repository URL, for example `https://pkg.swift-os.org`.
- Signing-key policy:
  - local offline root key;
  - CI publishing key;
  - key rotation and revocation process.
- CI runner model:
  - GitHub-hosted runner if toolchain/QEMU setup is fast enough;
  - self-hosted runner if large packages such as Node.js, OpenJDK, Swift, and
    PostgreSQL need heavier build resources.

Until those are known, the implementation should build a local static
repository fixture that behaves exactly like the final hosted repository.

## First End-to-End Definition of Done

The first complete milestone is not `nginx`; it is a small package proving the
whole pipe:

1. CI builds `pkghello` and `lua` into `.swpkg`.
2. Publishing job generates a signed static catalog.
3. A host HTTP server serves the catalog and blobs.
4. swift-os boots in QEMU.
5. `/bin/pkg update` fetches and verifies the catalog.
6. `/bin/pkg install lua` downloads and verifies the package.
7. VFS activation exposes `/usr/bin/lua`.
8. `lua -v` runs on swift-os.

Only after that is green should the project spend serious effort on heavy
server packages such as PostgreSQL, Node.js, OpenJDK, and Swift.
