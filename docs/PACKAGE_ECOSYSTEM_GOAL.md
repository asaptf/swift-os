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
- P2 package payload overlays are implemented:
  - QEMU can boot with a base SWOSBASE disk plus package payload disks;
  - VFS selects the base image by contents, independent of virtio scan order;
  - `/usr/bin/pkghello` executes from a package payload image.
- P3a package-store boot activation is implemented:
  - `docs/PKGSTORE_FORMAT.md` documents the `SWPKGST1` image layout;
  - `build/pkgstore` can create and inspect package-store images;
  - QEMU can boot a preseeded active package generation.
- P3b local target-side install is implemented:
  - `/bin/pkg install FILE` can install a local `.swpkg` into a writable
    package-store image;
  - `/bin/pkg list` reports active package-store records;
  - `make package-local-install-test` proves the flow with
    `/packages/pkghello.swpkg`.
- P5c signed static HTTP repository install is implemented as a fixture:
  - `tools/pkgrepo.swift` builds signed catalogs and content-addressed package
    trees;
  - `/bin/pkg repo set`, `pkg update [URL]`, `pkg search`, `pkg info`, and
    `pkg install NAME` work against the fixture;
  - install by name resolves catalog dependencies by package name;
  - `make package-repo-install-test` proves negative catalog rejection,
    dependency installation, package SHA-256 rejection, and execution of
    `/usr/bin/pkghello`.
- P6a/P6b/P6c/P6d/P6e/P6f ports scaffolding is implemented in this repository:
  - `ports/catalog.json` records the first package priorities, prerequisite
    bundles, runtime dependency names, and blockers;
  - `ports/lang/lua/Port.json` is the first source recipe scaffold;
  - `build/swport catalog validate/list/inspect` and
    `build/swport recipe validate/manifest/fetch/package/repo-fixture`
    provide host-side checks;
  - `scripts/build-lua.sh` cross-builds static AArch64 `lua` and `luac`
    against the local newlib sysroot;
  - `make ports-catalog-test` and `make ports-recipe-test` keep the catalog and
    Lua recipe package/repository path machine-readable;
  - `make ports-lua-repo-fixture` proves the Lua cross-build package and signed
    local repository fixture;
  - `make package-lua-repo-install-test` proves `pkg install lua`, `lua -v`,
    and a small Lua expression inside QEMU.
- Public hosted binary repository publishing, version-constraint solving,
  remove, upgrade, rollback, broad source-port coverage, package publication,
  and streaming large-package downloads remain future work.

## Workstreams

The package ecosystem splits into four independent workstreams that can run in
parallel.

### 1. Package Manager Path

Lives in `swift-os`.

Milestones:

1. P2: mount verified package payload images as read-only VFS overlays. (DONE)
2. P3a: persistent package store and boot activation generations. (DONE)
3. P3b: local target-side `/bin/pkg install FILE` and `pkg list`. (DONE)
4. P4: complete local package lifecycle: files, remove, rollback, and
   diagnostics.
5. P5: signed static HTTP repository catalogs, network fetch, configured
   repository URLs, and name-based dependency installation. (P5c fixture DONE;
   public hosted channels remain future work)

### 2. Ports Catalog

The P6a/P6b/P6c/P6d/P6e/P6f seed lives in this repository under `ports/`; the full
ports tree should move to `swift-os-ports` once cross-building, testing,
publishing, and broader package maintenance are ready.

Outputs:

- prioritized server software catalog;
- one `Port.json` per package;
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
