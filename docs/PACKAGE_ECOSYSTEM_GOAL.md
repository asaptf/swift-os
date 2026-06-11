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

- Host package artifact tooling is present:
  - `tools/swpkg.swift`;
  - `tools/packfs.swift`;
  - `docs/SWPKG_FORMAT.md`;
  - `tests/swpkg_tool_test.swift`.
- `.swpkg` can be created, inspected, verified, and host-tested.
- Package payload overlays are implemented:
  - QEMU can boot with a base SWOSBASE disk plus package payload disks;
  - VFS selects the base image by contents, independent of virtio scan order;
  - `/usr/bin/pkghello` executes from a package payload image.
- Package-store boot activation is implemented:
  - `docs/PKGSTORE_FORMAT.md` documents the `SWPKGST1` image layout;
  - `build/pkgstore` can create and inspect package-store images;
  - QEMU can boot a preseeded active package generation.
- Local target-side install is implemented:
  - `/bin/pkg install FILE` can install a local `.swpkg` into a writable
    package-store image;
  - `/bin/pkg list` reports active package-store records;
  - `make package-local-install-test` proves the flow with
    `/packages/pkghello.swpkg`.
- Signed static HTTP repository install is implemented as a fixture:
  - `tools/pkgrepo.swift` builds signed catalogs and content-addressed package
    trees;
  - `/bin/pkg repo set`, `pkg update [URL]`, `pkg search`, `pkg info`, and
    `pkg install NAME` work against the fixture;
  - install by name resolves catalog dependencies by package name;
  - `make package-repo-install-test` proves negative catalog rejection,
    dependency installation, package SHA-256 rejection, and execution of
    `/usr/bin/pkghello`.
- The checked ports seed is implemented in this
  repository:
  - `ports/catalog.json` records the first package priorities, prerequisite
    bundles, runtime dependency names, and blockers;
  - `ports/lang/lua/Port.json`, `ports/archivers/zlib/Port.json`,
    `ports/archivers/bzip2/Port.json`, `ports/archivers/zstd/Port.json`,
    `ports/archivers/xz/Port.json`, `ports/archivers/libarchive/Port.json`,
    `ports/security/ca-certificates/Port.json`, `ports/security/openssl/Port.json`,
    `ports/devel/pcre2/Port.json`, `ports/sysutils/tzdata/Port.json`, `ports/www/nginx/Port.json`, and
    `ports/databases/sqlite/Port.json` are the checked recipe scaffolds;
  - `build/swport catalog validate/list/inspect` and
    `build/swport recipe validate/manifest/fetch/package/repo-fixture`
    provide host-side checks;
  - `scripts/build-lua.sh` cross-builds static AArch64 `lua` and `luac`,
    `scripts/build-zlib.sh` cross-builds static zlib plus `minigzip` against
    the local newlib sysroot, `scripts/build-bzip2.sh` cross-builds static
    bzip2 tools and `libbz2.a`, `scripts/build-zstd.sh` cross-builds static
    zstd tools and `libzstd.a`, `scripts/build-xz.sh` cross-builds static xz
    tools and `liblzma.a`, `scripts/build-libarchive.sh` cross-builds static
    `bsdtar` plus `libarchive.a` against the checked compression libraries,
    `scripts/build-ca-certificates.sh` packages the pinned Mozilla CA bundle as
    data, `scripts/build-openssl.sh` cross-builds the static OpenSSL CLI,
    and `scripts/build-pcre2.sh` cross-builds static PCRE2 libraries plus
    `pcre2grep`;
  - `scripts/build-tzdata.sh` compiles IANA TZif zoneinfo with host `zic`,
    `scripts/build-nginx.sh` cross-builds a minimal static HTTP-only nginx
    package with the local SwiftOS crossbuild overlay, and
    `scripts/build-sqlite.sh` cross-builds the static SQLite shell/library;
  - `make ports-catalog-test` and `make ports-recipe-test` keep the catalog and
    checked recipe package/repository paths machine-readable;
  - `make ports-lua-repo-fixture` proves the Lua cross-build package and signed
    local repository fixture;
  - `make package-lua-repo-install-test` proves `pkg install lua`, `lua -v`,
    and a small Lua expression inside QEMU;
  - `make ports-seed-repo-fixture` publishes Lua, zlib, bzip2, zstd, xz,
    libarchive, ca-certificates, OpenSSL, pcre2, tzdata, nginx, and sqlite into one
    signed local seed repository, and `make package-ports-seed-repo-install-test`
    proves installing all twelve packages plus the `minigzip`, bzip2, zstd, and
    xz round trips, `bsdtar` tar create/list smoke, CA bundle marker, OpenSSL
    version/digest smoke, `pcre2grep` pattern match, zoneinfo marker, nginx version/marker, and SQLite SQL smoke
    inside QEMU;
  - `make ports-static-host-publish` emits a deployable static-host root for
    the seed repository, and `make package-static-host-repo-install-test`
    proves SwiftOS can install all twelve packages from that published layout;
  - `make ports-hosted-url-verify-test` proves the host-side verifier can check
    a served static-host root;
  - `make package-static-host-dns-repo-install-test` proves `/bin/pkg` can
    install Lua, zlib, bzip2, zstd, xz, libarchive, ca-certificates, OpenSSL, pcre2,
    tzdata, nginx, and sqlite from a DNS-resolved HTTP repository URL.
- The Node.js application-hosting intake is now tracked as scaffolded, blocked
  ports:
  - `ports/lang/nodejs/Port.json` pins the current LTS source tarball and records
    the static runtime/V8/libuv policy blockers;
  - `ports/lang/npm/Port.json` tracks npm as an explicit package, separate from
    Node.js, so registry access, cache, and global-prefix policy are reviewable;
  - `ports/sysutils/pm2/Port.json` tracks the process-manager layer separately
    from the runtime and records service/signal/persistence blockers;
  - `make ports-catalog-test` and `make ports-recipe-test` validate these intake
    records without claiming the runtime is built yet.
- Public production binary repository publishing, target-side HTTPS transport,
  version-constraint solving, remove, upgrade, rollback, broad source-port
  coverage, package publication, and streaming large-package downloads remain
  future work.

## Workstreams

The package ecosystem splits into four independent workstreams that can run in
parallel.

### 1. Package Manager Path

Lives in `swift-os`.

Milestones:

1. Package payload overlays: mount verified package payload images as read-only
   VFS overlays. (DONE)
2. Package-store boot activation: persistent package store and boot activation
   generations. (DONE)
3. Local target-side install: `/bin/pkg install FILE` and `pkg list`. (DONE)
4. Complete local package lifecycle: files, remove, rollback, and diagnostics.
5. Signed repository catalogs and network fetch: configured repository URLs,
   name-based dependency installation, and signed static HTTP repository
   fixtures are implemented; public hosted channels remain future work.

### 2. Ports Catalog

The current seed catalog and twelve checked recipes live in this repository under
`ports/`; the full ports tree should move to `swift-os-ports` once
cross-building, testing, publishing, and broader package maintenance are ready.

Outputs:

- prioritized server software catalog;
- one `Port.json` per package;
- patches and static-link build flags;
- QEMU smoke tests;
- first real packages: `lua`, `zlib`, `ca-certificates`, `pcre2`; next packages
  are compression/build helpers and the web stack.

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
- Bootstrap HTTP repository URL for the current `/bin/pkg` transport, for
  example `http://pkg.swift-os.org/aarch64/current`.
- Signing-key policy:
  - local offline root key;
  - CI publishing key;
  - key rotation and revocation process.
- CI runner model:
  - GitHub-hosted runner if toolchain/QEMU setup is fast enough;
  - self-hosted runner if large packages such as Node.js, OpenJDK, Swift, and
    PostgreSQL need heavier build resources.

Until those are known, the implementation should build a local static
repository fixture and a static-host web root that behave exactly like the
final hosted repository. The current bootstrap root is
`build/ports-static-host-root`.

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
