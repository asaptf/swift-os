# SwiftOS Package Build Automation Guide

This guide describes the package maintainer workflow for SwiftOS: how source
ports should become verified `.swpkg` artifacts, how QEMU smoke tests prove
those artifacts, and how trusted automation should publish a binary repository.

It is written for package maintainers, release owners, and infrastructure
engineers. User-facing package installation is covered in
[Package Guide](PACKAGE_GUIDE.md) and [Package Management](PACKAGE_MANAGEMENT.md).

## Current State

SwiftOS already has the package artifact and guest install primitives needed to
prove the package model locally:

| Area | Current status | Verification |
| --- | --- | --- |
| Host `.swpkg` tool | Implemented as `build/swpkg` | `make package-fixture` |
| Sample package | `build/pkghello.swpkg` with a deterministic payload | `build/swpkg verify build/pkghello.swpkg` |
| Direct payload overlay | Read-only package content mounted under `/usr` | `make package-overlay-test` |
| Package-store boot activation | Preseeded package-store image activates package payloads | `make package-store-test` |
| Guest local install | `/bin/pkg install FILE` appends a local `.swpkg` to a writable package store | `make package-local-install-test` |
| Static signed repository fixture | `build/pkgrepo` creates a signed HTTP catalog tree for `pkghello` | `make package-repo-fixture` |
| Guest repository install | `/bin/pkg update URL`, `search`, `info`, and `install NAME` work against the signed HTTP fixture | `make package-repo-install-test` |
| `swport` ports tool | Planned; not implemented in this repository yet | This guide defines the contract |
| Public hosted repository | Planned; production hosting, channels, key ceremony, and broad package publication are roadmap work | `PACKAGE_MANAGEMENT.md` tracks target-side milestones |

The automation below is the intended maintainer and CI layer around the
implemented `.swpkg`, package-store, local guest install, and P5a signed static
repository paths. Until `swift-os-ports`, `swport`, and public hosted channels
exist, maintainers should use the local fixture commands in this repository.

Use this guide with:

- [Package Guide](PACKAGE_GUIDE.md) for package commands that work today.
- [Package Management](PACKAGE_MANAGEMENT.md) for target-side package-manager
  design and roadmap boundaries.
- [SWPKG Format](SWPKG_FORMAT.md) for the `.swpkg` container contract.
- [Package Store Format](PKGSTORE_FORMAT.md) for package-store image and
  activation records.
- [Static Package Repository](PKGREPO_FORMAT.md) for the P5a signed HTTP
  catalog layout.
- [Server Software Catalog](SERVER_SOFTWARE_CATALOG.md) for package priorities
  and OS prerequisite bundles.
- [Porting Guide](PORTING_GUIDE.md) for source-level application porting.

## Maintainer Quick Start Today

Build and verify the current sample package:

```sh
make build base-image build/virt.dtb
make package-fixture
build/swpkg inspect build/pkghello.swpkg
build/swpkg verify build/pkghello.swpkg
```

Prove every implemented package path:

```sh
make package-overlay-test
make package-store-test
make package-local-install-test
make package-repo-install-test
```

Inspect the signed repository fixture:

```sh
make package-repo-fixture
build/pkgrepo inspect build/pkgrepo-root/aarch64/current/catalog.signed
```

For a new experimental port before `swport` exists, keep the same discipline:

1. Cross-build the program statically against the current SwiftOS ABI.
2. Stage the installed files under a clean package root.
3. Generate a `.swpkg` with `build/swpkg create`.
4. Verify it with `build/swpkg verify`.
5. Boot QEMU and run a command that proves the installed binary works.
6. Record any missing syscall, libc, service, or filesystem requirement in the
   port notes before treating the package as publishable.

## Planned Maintainer Experience

The package ecosystem should make the maintainer path almost as simple as the
user path:

```sh
swport new lang/lua
$EDITOR ports/lang/lua/Port.toml
swport test lang/lua
git push
```

After review and merge, automation should fetch source, verify checksums,
cross-build, package, smoke-test in QEMU, sign metadata, publish content blobs,
regenerate the catalog, and make the package available through:

```sh
pkg update
pkg install lua
```

Manual package uploads, hand-edited catalogs, and target-side source builds are
out of scope for the normal path.

## Repository Roles

Use three repositories once the package ecosystem leaves the single-repository
fixture stage:

- `swift-os`: OS, target-side `/bin/pkg`, `.swpkg` host tools while they are
  tightly coupled to the image format, default root keys, and in-QEMU package
  acceptance tests.
- `swift-os-ports`: port recipes, patches, `swport`, build containers or build
  images, FreeBSD ports importer, PR CI, and bulk build workflows.
- `swift-os-packages`: published repository metadata, generation history,
  channel policy, signing workflow, and static hosting deployment scripts.

The binary blobs can live outside git once they grow: GitHub Releases, S3,
Cloudflare R2, or a plain nginx-backed object directory are all valid because
integrity comes from signed catalogs and content hashes.

## Initial Software Catalog

Start with a server-focused package set, but stage it by OS readiness. The first
packages should prove the machinery, not stress every missing POSIX surface.

### Wave 0: Pipeline Fixtures

- `pkghello`: tiny local package used by every format, store, and repository
  test.
- `lua`: first real user-facing package; small, useful, and friendly to static
  linking.
- `zlib`: common dependency and a good test of library packaging.
- `ca-certificates`: data package needed before useful HTTPS clients.

### Wave 1: Operator Tools

- `ncurses` and `terminfo`: terminal data for shells, editors, and `mc`.
- `oksh` or another small shell: backup shell and script portability exercise.
- `nano` or `mg`: small editor before heavier full-screen tools.
- `midnight-commander`: useful operator tool once terminal and file APIs are
  good enough.
- `curl`: network, DNS, certificates, and TLS integration exercise.

### Wave 2: Web Hosting

- `nginx`: primary static/reverse-proxy server target.
- `pcre2`: likely nginx dependency depending on selected build options.
- `openssl` or `libressl`: TLS provider until a smaller target-native TLS story
  exists.
- `acme-client` or another small ACME tool: Let's Encrypt certificate issuance.
- `cron`-like timer service or package service timers: required for certificate
  renewal if renewal is not driven externally.

### Wave 3: Data Stores

- `sqlite`: first database package; low daemon complexity.
- `postgresql`: important server target, but waits for stronger process, file,
  socket, mmap, fsync, user/group, and service semantics.
- `mariadb`: later than PostgreSQL unless its portability story proves simpler.

### Wave 4: Heavy Runtimes

- `swift`: native Swift application runtime and tools. Split runtime, standard
  libraries, and compiler pieces if needed.
- `nodejs`: requires careful work on libuv, sockets, timers, mmap, signals,
  threading, and static linking policy.
- `openjdk`: JVM target; likely needs the strongest syscall, memory, threading,
  signal, and filesystem compatibility work.

Every package in the catalog should carry one of these maturity states:

- `scaffolded`: recipe exists, known TODOs remain.
- `fetches`: distfiles and checksums are valid.
- `builds`: cross-build completes.
- `packages`: `.swpkg` is produced and verified.
- `smoke-tested`: QEMU command passes.
- `published`: trusted workflow has published it to a channel.

## Port Tree Shape

`swift-os-ports` should be regular and easy to bulk-process:

```text
ports/
  lang/
    lua/
      Port.toml
      patches/
      files/
      tests/
  www/
    nginx/
      Port.toml
      patches/
      files/
Mk/
  defaults.toml
  build-systems/
    configure.toml
    cmake.toml
    make.toml
tools/
  swport
  freebsd-import
ci/
  pr.yml
  publish.yml
```

Only `Port.toml`, patches, files, and small helper scripts are maintained by
humans. Generated manifests, work directories, distfiles, packages, and catalogs
must not be committed to `swift-os-ports`.

## `Port.toml` Lifecycle

A new port moves through a predictable lifecycle:

```sh
swport new lang/lua
swport fetch lang/lua
swport build lang/lua
swport test lang/lua
swport package lang/lua
```

From FreeBSD metadata:

```sh
swport import-freebsd www/nginx
$EDITOR ports/www/nginx/Port.toml
swport lint www/nginx
swport test www/nginx
```

Version bumps:

```sh
swport bump lang/lua 5.4.8
swport fetch lang/lua --update-checksum
swport test lang/lua
```

The recipe should be declarative enough that most ports need no custom build
script:

```toml
name = "lua"
version = "5.4.8"
revision = 1
category = "lang"
summary = "Small embeddable scripting language"
homepage = "https://www.lua.org/"
license = ["MIT"]
maturity = "smoke-tested"

[source]
url = "https://www.lua.org/ftp/lua-5.4.8.tar.gz"
sha256 = "..."

[target]
arch = "aarch64"
os = "swift-os"
abi = "swos-0"
libc = "newlib-4.6-swos"
linkage = "static"

[build]
system = "make"
args = ["posix"]
env = {
  "CC" = "swos-cc",
  "AR" = "llvm-ar rcu",
  "RANLIB" = "llvm-ranlib"
}

[install]
destdir = true
command = ["make", "install", "INSTALL_TOP=${DESTDIR}/usr"]

[package]
depends = []
paths = [
  { from = "destdir/usr/bin/lua", to = "/usr/bin/lua", mode = "0755" },
  { from = "destdir/usr/bin/luac", to = "/usr/bin/luac", mode = "0755" }
]

[test]
qemu = [
  "/usr/bin/lua -v",
  "/usr/bin/lua -e 'print(1 + 2)'"
]
```

Required fields:

- package identity: `name`, `version`, `revision`, `category`, `summary`,
  `license`;
- source: URL and SHA-256 for every distfile;
- target ABI: architecture, OS ABI, libc ABI, and static-linkage policy;
- build system and environment;
- package paths or generated plist mapping;
- at least one smoke test before publication.

Optional fields:

- `features`: named variants, disabled in v1 publication unless explicitly
  allowed;
- `conflicts`, `provides`, `replaces`;
- service declarations;
- reverse smoke test hints;
- FreeBSD origin metadata.

## `swport` Command Contract

`swport` is the single maintainer interface. It should print exact output paths,
use stable exit codes, and be scriptable by CI.

Common commands:

```sh
swport new <category/name> [--from-freebsd <origin>]
swport import-freebsd <origin> [--as <category/name>]
swport lint [<port>|--all]
swport fetch <port> [--update-checksum]
swport extract <port>
swport patch <port>
swport configure <port>
swport build <port>
swport install <port>
swport manifest <port>
swport package <port>
swport verify <path/to/pkg.swpkg>
swport test <port> [--qemu] [--host-only]
swport clean <port>|--all
swport shell <port>
swport bump <port> <version>
swport bulk [--changed] [--all] [--smoke] [--jobs N]
swport publish <port>|--manifest <path> --channel current
```

Important semantics:

- `package` depends on fetch, extract, patch, configure, build, install,
  normalize, manifest generation, payload image creation, and `.swpkg`
  verification.
- `test` depends on `package`, boots a test swift-os image in QEMU, installs or
  mounts the produced package, and runs the recipe's QEMU commands.
- `bulk --changed` detects changed ports from git diff, then includes direct
  dependencies and a small reverse-dependency smoke set when available.
- `publish` is disabled by default for local developers. In CI it should hand
  artifacts to the trusted publish workflow instead of uploading directly from a
  laptop.
- `shell` enters the exact sanitized build environment for debugging.

Suggested exit codes:

- `0`: success;
- `2`: usage error;
- `3`: unknown port;
- `4`: checksum failure;
- `5`: build failure;
- `6`: package verification failure;
- `7`: QEMU smoke failure;
- `8`: publish/signing failure.

## Deterministic Work Directories

Builds must not depend on the developer's current directory, username, umask, or
clock. `swport` should derive every path from the port identity, target ABI, and
recipe digest.

Default local layout:

```text
.swport/
  cache/
    distfiles/
      sha256/<first-two>/<sha256>/<filename>
    freebsd-ports/
    toolchains/
  work/
    aarch64-swift-os/
      lang/lua/5.4.8_1/<recipe-sha256>/
        source/
        build/
        destdir/
        logs/
        manifest.json
        payload.swosbase
  packages/
    aarch64-swift-os/
      lua-5.4.8_1-<pkg-sha256>.swpkg
```

CI may use the same logical layout under its runner workspace. The absolute path
must not appear in produced binaries, package manifests, or logs used for
reproducibility comparison.

Normalization rules:

- set `SOURCE_DATE_EPOCH` from the upstream release timestamp or the git commit
  timestamp of the recipe;
- sort file lists by bytewise UTF-8 path;
- set packaged owner/group to `0:0` until swift-os has a richer identity model;
- make directory modes deterministic;
- strip debug sections unless a separate `-debug` package is declared;
- reject files outside the declared package prefix;
- reject host shebangs, host library paths, and host rpaths;
- record toolchain, sysroot, source, patch, and recipe digests in the generated
  build manifest.

## Distfile Cache

Distfile handling should be content-addressed and mirror-friendly.

Fetch order:

1. local content-addressed cache;
2. project mirror, if configured;
3. upstream URLs from `Port.toml`;
4. FreeBSD distcache URL, only when imported metadata declares a compatible
   distfile.

Rules:

- each distfile is accepted only after SHA-256 verification;
- cache keys are hashes, not mutable filenames;
- downloads write to a temporary file and atomically rename after verification;
- `swport fetch --offline` may use only the local cache;
- failed checksum updates must show both expected and observed hashes;
- CI should restore the distfile cache by hash, but a cache hit never replaces
  checksum verification.

When a distfile disappears upstream, maintainers can promote the verified blob
to the project mirror without changing the package recipe.

## Cross Toolchain and Sysroot

The build side needs a pinned SDK manifest, not ad hoc environment variables.
The exact Embedded Swift flags and target triple remain toolchain-version
specific and should be read from the SDK manifest generated by `swift-os`.

Proposed SDK layout:

```text
sdk/
  manifest.json
  bin/
    swos-cc
    swos-c++
    swos-ar
    swos-ranlib
    swos-strip
  sysroot/
    usr/include/
    usr/lib/
  pkgtools/
    swpkg
    basepack
```

`sdk/manifest.json` records:

- SDK version;
- swift-os git revision;
- architecture and OS ABI;
- libc name and version;
- compiler versions;
- supported build systems;
- package format version;
- default QEMU image used for smoke tests.

`swport sdk install` should download or build the SDK, verify its hash, and put
it under `.swport/cache/toolchains/<sdk-id>`. CI should use the same SDK
artifact for every job in a given workflow run.

The build environment should include only explicit variables:

```text
CC=swos-cc
CXX=swos-c++
AR=swos-ar
RANLIB=swos-ranlib
STRIP=swos-strip
PKG_CONFIG_SYSROOT_DIR=<sdk>/sysroot
PKG_CONFIG_LIBDIR=<sdk>/sysroot/usr/lib/pkgconfig
DESTDIR=<work>/destdir
SOURCE_DATE_EPOCH=<deterministic timestamp>
```

Target ABI mismatches are hard failures. A package built against one OS ABI or
libc ABI must not publish to a catalog for another ABI.

## FreeBSD Ports Importer

FreeBSD ports should be treated as a scaffolding source, not as a runtime
compatibility target.

```sh
swport import-freebsd www/nginx
swport import-freebsd shells/bash --as shells/bash
```

The importer can derive:

- upstream distfile URLs and checksums;
- license metadata;
- maintainer notes as comments;
- patches from `files/`;
- configure, cmake, and make options;
- package plist path hints;
- dependency hints;
- known test commands when obvious.

The importer must mark uncertainty explicitly:

```toml
[freebsd]
origin = "www/nginx"
imported_at = "2026-06-09T00:00:00Z"
warnings = [
  "Review FreeBSD-specific kqueue assumptions.",
  "Dynamic module options were disabled for static linking.",
  "Package plist needs manual pruning."
]
```

Automatic rewrites should be conservative:

- disable shared libraries and dynamic modules by default;
- prefer bundled or sysroot libraries only when declared;
- remove Linux/FreeBSD-specific service scripts;
- translate plist paths into `[package].paths` TODOs;
- refuse to claim `smoke-tested` maturity.

The importer should support a local checkout or shallow cache of the FreeBSD
ports tree. It must not require network access when that cache is already
present.

## Build Pipeline

The canonical package build is:

```text
resolve recipe
resolve SDK
fetch distfiles
verify distfile hashes
unpack source
apply patches
configure for swift-os
build static artifacts
install into DESTDIR
normalize DESTDIR
generate manifest
build payload.swosbase
build .swpkg
verify .swpkg
boot QEMU smoke image
install or mount package
run smoke commands
emit build report
```

Each stage writes a machine-readable status file under `work/.../logs/` so CI
can publish useful annotations without scraping terminal output.

The build report should include:

- port name, version, revision, and recipe digest;
- SDK id and OS ABI;
- source hash list;
- patch hash list;
- produced `.swpkg` hash and size;
- installed file list diff;
- smoke test commands and serial log excerpt;
- reproducibility result when a second build was requested.

## QEMU Smoke Tests

Every publishable port needs at least one QEMU smoke test. Host-only build tests
are useful, but they do not prove the binary runs on swift-os.

Test flow:

1. build a fresh package;
2. boot the current test swift-os image in QEMU;
3. make the package available either through local `pkg install ./x.swpkg` or a
   temporary static HTTP repository fixture;
4. run every `[test].qemu` command;
5. capture serial output;
6. fail on timeout, non-zero command exit, kernel panic, package verification
   failure, or missing expected output.

Example:

```toml
[test]
timeout_seconds = 30
qemu = [
  "/usr/bin/lua -v",
  "/usr/bin/lua -e 'print(21 * 2)'"
]
expect = [
  "Lua 5.4",
  "42"
]
```

Service packages should use host port forwarding:

```toml
[test.service]
start = "service nginx start"
host_forward = ["tcp:18080:80"]
host_checks = [
  "curl -fsS http://127.0.0.1:18080/"
]
```

The first QEMU test harness can be simple serial scripting. Later, a small
guest-side test runner can reduce fragile shell parsing.

## GitHub Actions: Pull Requests

PR workflows are untrusted. They must build and test, but they must not receive
signing keys or publish to the public repository.

Suggested PR workflow:

```text
checkout swift-os-ports
checkout swift-os at pinned ref or requested compatibility ref
restore distfile cache
install verified SDK
swport lint --changed
swport bulk --changed --smoke --jobs N
upload build reports
upload preview .swpkg artifacts
comment package manifest diffs and QEMU results
```

PR CI should validate:

- recipe schema and style;
- no generated files committed;
- distfile checksums;
- patch application;
- static-linking policy;
- generated manifest contents;
- `.swpkg` verifier result;
- QEMU smoke tests;
- reverse dependency smoke tests for small packages;
- license metadata presence.

Preview artifacts must be labeled untrusted. They are for reviewer inspection
only and should not be consumed by users through `pkg`.

## GitHub Actions: Publish

The publish workflow is trusted and runs only after merge to `main`, a tag, or a
maintainer-approved workflow dispatch.

Suggested publish workflow:

```text
checkout swift-os-ports at trusted commit
checkout swift-os-packages
install verified SDK
swport bulk --changed-since-last-publish --smoke --rebuild-clean
rebuild selected packages a second time when reproducibility policy requires it
compare package hashes
upload missing blobs by sha256
regenerate catalog.json
sign catalog
commit catalog generation to swift-os-packages
deploy static repository
run end-to-end pkg update/install smoke test
```

Publish jobs must rebuild from source. They must not promote PR artifacts
directly.

Signing policy:

- catalog signing uses Ed25519 as the default;
- root keys are offline and pinned in the base OS;
- online channel keys sign routine `current` and `stable` catalogs;
- key ids and expiration are recorded in every catalog;
- key rotation is a repository-generation event and must be testable by
  target-side `pkg`;
- package blobs may also carry per-package signatures, but the v1 trust path is
  signed catalog plus content hash.

GitHub secrets can hold the initial online channel key, but the preferred long
term shape is OIDC to a signing service or KMS-backed signer so raw keys are not
exported to CI runners.

## Published Repository Layout

The repository must be static-hosting friendly:

```text
https://pkg.swift-os.org/
  keys/
    root-2026.pub
    current-2026.pub
  aarch64/
    current/
      catalog.json
      catalog.sig
      catalog.signed
      snapshots/
        00000042/
          catalog.json
          catalog.sig
      packages/
        sha256/
          ab/
            abcd....swpkg
    stable/
      catalog.json
      catalog.sig
      catalog.signed
      packages/
        sha256/
```

Blob path is derived from SHA-256. Upload blobs first, verify that the hosted
hash matches, then publish the new catalog. A catalog must never reference a
blob that is not already reachable.

`catalog.json` should be canonical JSON:

```json
{
  "format": 1,
  "repository": "swift-os",
  "channel": "current",
  "generation": 42,
  "created_at": "2026-06-09T00:00:00Z",
  "expires_at": "2026-07-09T00:00:00Z",
  "arch": "aarch64",
  "os": "swift-os",
  "abi": "swos-0",
  "libc": "newlib-4.6-swos",
  "root_key_id": "root-2026",
  "channel_key_id": "current-2026",
  "packages": [
    {
      "name": "lua",
      "version": "5.4.8",
      "revision": 1,
      "summary": "Small embeddable scripting language",
      "license": ["MIT"],
      "sha256": "...",
      "size": 123456,
      "url": "packages/sha256/ab/abcd....swpkg",
      "depends": []
    }
  ]
}
```

`catalog.signed` can be an envelope containing the canonical catalog bytes,
signature, and key id. Keeping separate `catalog.json` and `catalog.sig` files
is useful for inspection and mirrors.

## Hosting and Deployment

The first deployment can be plain static hosting:

- nginx on a small VPS;
- Let's Encrypt certificate for privacy and normal browser behavior;
- repository files synced from `swift-os-packages` publish workflow;
- immutable cache headers for package blobs;
- short cache headers for `catalog.signed`;
- access logs retained for basic download diagnostics.

Integrity must not depend on TLS. `pkg` verifies signatures and content hashes
even when the repository is served over HTTP in a QEMU test.

Deployment steps:

```text
publish workflow builds repository generation
upload blobs to object directory
upload snapshot catalog
upload channel catalog to a temporary path
verify hosted bytes
atomically rename or promote channel catalog
run external pkg update/install smoke test
```

Rollback is catalog-level: republish an older signed generation for the channel
or update the channel pointer to an older snapshot. Content-addressed blobs do
not need rollback.

## Target-Side `pkg` Integration

The hosted repository feeds target-side `pkg` through a small number of files:

```sh
pkg repo list
pkg update
pkg search nginx
pkg install nginx
```

`pkg update`:

1. downloads `catalog.signed` for each configured repository;
2. verifies root/channel key chain against pinned base-image keys;
3. checks expiration, architecture, OS ABI, libc ABI, and monotonic generation;
4. stores the verified catalog in the package store.

`pkg install <name>`:

1. resolves the package and dependencies from verified catalogs;
2. downloads each `.swpkg` from its content-addressed URL;
3. verifies the blob SHA-256 against the signed catalog;
4. verifies the `.swpkg` container and manifest;
5. writes blobs and payload images to the package store;
6. creates a new activation generation;
7. switches the active generation atomically.

The target never needs to understand the ports tree, FreeBSD metadata, build
logs, or CI provenance to install a package.

## Reproducibility and Provenance

The publish workflow should eventually require reproducible builds for core
packages. The first version can be softer: record all inputs and make
non-reproducibility visible.

Recommended phases:

1. record source, patch, recipe, SDK, and tool hashes in every build report;
2. rebuild small packages twice in CI and compare `.swpkg` hashes;
3. require reproducibility for packages in `bootstrap` and `stable`;
4. publish provenance/SBOM sidecars for large packages and runtime stacks.

Sidecar files can live beside blobs:

```text
packages/sha256/ab/abcd....swpkg
packages/sha256/ab/abcd....build.json
packages/sha256/ab/abcd....sbom.json
```

The signed catalog should include sidecar hashes if `pkg` or auditors rely on
them.

## Failure Handling

Common failure modes should have boring outcomes:

- checksum mismatch: fail before extraction and keep the previous cache entry;
- build failure: upload logs, no package artifact;
- package verification failure: fail the job, no publish;
- QEMU smoke failure: fail the port, keep artifact only as an untrusted PR
  artifact;
- signing failure: do not upload or modify channel catalogs;
- blob upload failure: do not publish the catalog;
- catalog publish failure: old generation remains active;
- post-publish smoke failure: automatically roll channel back to the previous
  signed generation and open an incident issue.

## Milestones

### A1: `swport` Skeleton

- Create `swift-os-ports` layout.
- Add recipe parser and `swport lint/new/fetch`.
- Support `pkghello` and `lua` recipes.

Acceptance: `swport fetch lang/lua` verifies the distfile checksum.

### A2: Local Package Build

- Add SDK discovery.
- Add deterministic work directories.
- Implement build/install/normalize/package.

Acceptance: `swport package lang/lua` emits a verified `.swpkg`.

### A3: QEMU Smoke

- Add temporary local package repository fixture.
- Run package smoke commands in QEMU.

Acceptance: `swport test lang/lua` boots swift-os and runs `lua -v`.

### A4: PR CI

- Add changed-port detection.
- Upload build reports and preview artifacts.
- Run QEMU smoke tests.

Acceptance: a ports PR shows lint, build, manifest diff, and serial log.

### A5: Publish CI

- Rebuild trusted packages after merge.
- Upload content-addressed blobs.
- Regenerate and sign catalog.
- Commit/publish repository generation.

Acceptance: public `current` repository contains `pkghello` and `lua`.

### A6: End-to-End Hosted Install

- Configure `pkg.swift-os.org` or equivalent static host.
- Add target-side repository config.
- Run an external QEMU test against the hosted repository.

Acceptance:

```sh
pkg update
pkg install lua
lua -v
```

works on a fresh swift-os image.
