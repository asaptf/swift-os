# Package Management

Design for binary package installation on SwiftOS.

> Status: host package tooling, read-only package payload overlays,
> package-store boot activation, local `/bin/pkg install FILE`, and signed
> static HTTP repository install are implemented. `pkg repo set`,
> `pkg update [URL]`, `pkg search`, `pkg info`, and `pkg install NAME` work
> against signed fixture catalogs, including name-based dependency resolution,
> and reject expired catalogs, incompatible catalog entries, and package
> SHA-256 mismatches. The ports seed fixture cross-builds Lua, zlib, bzip2,
> pcre2, nginx, and sqlite, packages ca-certificates and tzdata, publishes all
> nine into one signed local repository, and can boot SwiftOS with
> `/etc/pkg/repo-url` so `pkg update` works without a manual `pkg repo set`.
> `make ports-static-host-publish` turns that seed into a deployable static web
> root, and `make package-static-host-repo-install-test` proves install from
> that published layout. `/bin/pkg` accepts DNS hostnames in HTTP repository
> URLs, `make ports-hosted-url-verify` checks a deployed static-host URL from
> the host, and `make package-static-host-dns-repo-install-test` proves
> target-side install through a DNS-resolved hosted-style URL. Rollback, remove,
> upgrade, public production channels, target-side HTTPS transport,
> version-constraint solving, and large-package streaming downloads are still
> staged work.
> The package work should continue to follow the project rule: one milestone at
> a time, build, boot, test, commit, then stop for review.

## Goals

The package system should make installing software feel no harder than Ubuntu:

```sh
pkg update
pkg search curl
pkg install curl
pkg upgrade
pkg remove curl
```

The user should not need to build from source on the target machine. Source
builds belong in a separate ports/build repository and in CI. The target OS
downloads signed binary packages, verifies them, activates them atomically, and
keeps enough history for rollback.

The design must preserve the existing swift-os stance:

- no Linux ABI;
- static linking only until the project explicitly chooses otherwise;
- rebuilt userland against the swift-os syscall/libc surface;
- read-only base image plus tmpfs scratch at runtime;
- small trusted core;
- signed immutable updates rather than mutating the root filesystem in place.

Related package ecosystem documents:

- [PACKAGE_ECOSYSTEM_GOAL.md](PACKAGE_ECOSYSTEM_GOAL.md) - active end-to-end
  goal, workstreams, and deployment inputs.
- [SWPKG_FORMAT.md](SWPKG_FORMAT.md) - implemented `.swpkg` container.
- [PKGSTORE_FORMAT.md](PKGSTORE_FORMAT.md) - implemented package-store
  bootstrap image and activation records.
- [PACKAGE_MANAGER_IMPLEMENTATION_PLAN.md](PACKAGE_MANAGER_IMPLEMENTATION_PLAN.md)
  - historical package-manager implementation readiness plan.
- [PACKAGE_BUILD_AUTOMATION.md](PACKAGE_BUILD_AUTOMATION.md) - `swport`, CI,
  and repository publishing automation.
- [SERVER_SOFTWARE_CATALOG.md](SERVER_SOFTWARE_CATALOG.md) - staged server
  package catalog and porting prerequisites.
- [PACKAGE_MANAGER_SESSION_PROMPTS.md](PACKAGE_MANAGER_SESSION_PROMPTS.md) -
  ready-to-paste prompts for future milestone sessions.

## Non-Goals

- No Linux package compatibility (`.deb`, `.rpm`, APK, pkgsrc binaries).
- No FreeBSD runtime ABI compatibility.
- No dynamic loader as a prerequisite.
- No arbitrary maintainer scripts running with ambient root authority.
- No mutable `/usr` filesystem as the primary install mechanism.
- No dependency on HTTPS for integrity. HTTPS is useful for privacy and later
  repository hosting, but package authenticity comes from signatures and hashes.

## High-Level Model

Package installation has two halves:

1. **Ports and build side.** Maintainers use a ports tree to fetch upstream
   source, apply swift-os patches, cross-build static binaries, run checks, and
   emit signed package artifacts.
2. **Target install side.** Users run `pkg`. It talks to binary repositories,
   verifies metadata and package signatures, stores immutable package images, and
   atomically switches the active package generation.

The important difference from traditional Unix package managers is that
installation does not unpack files into a mutable root. A package is an immutable
filesystem image plus metadata. Activation is a manifest change that tells the
VFS which package images are visible in the namespace.

That gives the user a simple CLI while keeping the OS model simple:

```text
read-only base image
  + active package image set
  + RAM tmpfs scratch
  + VFS namespace
```

## Repository Layout

Use **three repositories** under the same GitHub organization or account at the
start. That is enough separation without turning the project into a federation
of half-empty repos:

1. `swift-os` - the OS and the target-side package manager.
2. `swift-os-ports` - source recipes, patches, and package build automation.
3. `swift-os-packages` - binary repository publishing metadata and release
   automation.

Do not create a separate `swift-os-pkg` or `swift-os-tools` repository in v1.
Keep `/bin/pkg` in `swift-os` and `swport` in `swift-os-ports` until they have
enough independent release pressure to justify a split.

Optional future repositories:

- `swift-os-distfiles` only if upstream source mirroring becomes necessary;
- `swift-os-infra` only if hosting/deployment scripts grow beyond repository
  publishing;
- `swift-os-toolchain` only if the cross toolchain/sysroot becomes a product in
  its own right.

Initial repository responsibilities:

### `swift-os`

The OS repository.

Owns:

- kernel and VFS support for package image mounting;
- base userland `/bin/pkg`;
- package-store support;
- tests that boot QEMU and install sample packages;
- base repository keys and default repository configuration.

Keep `pkg` here at first because its ABI expectations are tightly coupled to the
current syscall surface, filesystem model, TLS/network maturity, and libc port.

### `swift-os-ports`

The source porting tree.

Owns:

- one directory per port recipe;
- patches;
- build metadata;
- target ABI declarations;
- package manifests;
- port smoke tests;
- importer/conversion helpers for FreeBSD ports.

Suggested shape:

```text
ports/
  shells/
    oksh/
      Port.json
      patches/
      files/
  www/
    curl/
      Port.json
      patches/
      files/
Mk/
  swos.port.mk
  toolchains/
tools/
  swport
  freebsd-import
ci/
  bulk-build.yml
```

FreeBSD ports are a useful source of upstream metadata, patches, configure
flags, license notes, and porting knowledge. They should not become the runtime
package format. Prefer importing or translating useful data into explicit
swift-os recipes.

### `swift-os-packages`

The published binary repository control plane.

This repository should hold the scripts and generated metadata needed to publish
a repository. The binary blobs themselves may live in GitHub Releases, S3,
Cloudflare R2, or another static object host/CDN.

Suggested public URL layout:

```text
https://pkg.swift-os.org/
  aarch64/current/catalog.signed
  aarch64/current/catalog.json
  aarch64/current/packages/<sha256>.swpkg
  aarch64/current/snapshots/<generation>/catalog.signed
```

The current bootstrap artifact uses the same `aarch64/current` contract under
`build/ports-static-host-root`, with `hosted-repo.json`, `repo-root.pub`, and
`SHA256SUMS` at the web-root level:

```sh
make ports-static-host-publish
make ports-hosted-url-verify PKG_HOSTED_REPO_URL=http://pkg.swift-os.org
```

Channels:

- `current`: follows mainline OS development;
- `stable`: follows tagged OS releases;
- optional `bootstrap`: tiny packages used by bring-up tests.

## Target Filesystem Layout

Base system files remain in `/bin`, `/etc`, and other boot-critical locations.
Third-party packages install into `/usr` by default:

```text
/usr/bin
/usr/sbin
/usr/libexec
/usr/share
/usr/share/doc
/etc/pkg/repos.d
```

The package database is not the source of truth in a mutable POSIX directory.
It is stored in the persistent package store and exposed read-only for
inspection:

```text
/pkg/db/installed.json
/pkg/db/history.json
/pkg/images/<name>-<version>
```

Until symlinks exist, packages should install real executable paths such as
`/usr/bin/curl`. The shell can include `/usr/bin` in `PATH`.

## Package Artifact

Package files use a new container format with a deliberately small target-side
parser:

```text
*.swpkg
  header
  manifest.json
  payload.swosbase
  signature
```

The payload is a packed read-only filesystem image using the same family of
format as `SWOSBASE`. Reusing the packed image model keeps package activation
close to the existing base-image path.

`pkg` verifies the container, then stores the package metadata and payload image
as separate content-addressed records. The VFS should mount only the already
verified payload image, not the whole `.swpkg` container. That keeps signature,
catalog, and compression parsing out of the kernel.

Initial implementation should use uncompressed payloads. Add zstd later when
there is a small audited decoder or a ported library. Compression is a hosting
and bandwidth optimization, not a correctness requirement.

### Manifest Sketch

```json
{
  "format": 1,
  "name": "curl",
  "version": "8.10.1",
  "revision": 1,
  "summary": "Command line URL transfer tool",
  "license": ["curl"],
  "homepage": "https://curl.se/",
  "arch": "aarch64",
  "target": "swift-os",
  "abi": {
    "os": "swos-0",
    "syscall": 1,
    "libc": "newlib-4.6-swos",
    "linkage": "static"
  },
  "depends": [
    {"name": "ca-certificates", "constraint": ">=2026.01"}
  ],
  "provides": ["curl"],
  "conflicts": [],
  "files": [
    {"path": "/usr/bin/curl", "mode": "0755", "sha256": "..."}
  ],
  "capabilities": {
    "default": ["fs.read"],
    "services": []
  }
}
```

The final format can be CBOR or another compact binary encoding if target-side
JSON parsing becomes too large. The first milestone can still use JSON because
the same parser can be host-tested heavily.

## Repository Metadata

The repository publishes a signed catalog:

```json
{
  "format": 1,
  "repository": "swift-os-current",
  "channel": "current",
  "generation": 42,
  "expires": "2026-07-01T00:00:00Z",
  "root_key_id": "swos-root-2026",
  "packages": [
    {
      "name": "curl",
      "version": "8.10.1",
      "revision": 1,
      "arch": "aarch64",
      "abi": "swos-0",
      "sha256": "...",
      "size": 1234567,
      "url": "packages/<sha256>.swpkg",
      "depends": [
        {"name": "ca-certificates", "constraint": ">=2026.01"}
      ]
    }
  ]
}
```

Security rules:

- `pkg` ships with pinned repository root keys in the base image.
- Catalogs are signed with Ed25519.
- Package blobs are addressed by SHA-256 and listed in the signed catalog.
- Individual package signatures are optional in v1 but useful for mirroring.
- Catalogs have expiration times to limit replay.
- `pkg` refuses packages for the wrong architecture, OS ABI, libc ABI, or
  static-linkage policy.

This is intentionally simpler than full TUF, but it preserves the core
properties swift-os needs: trusted keys, signed metadata, content hashes,
expiration, and rollback resistance through monotonic generations.

## Persistent Package Store

swift-os currently avoids a general persistent writable filesystem. Package
management should keep that decision.

Add a narrow persistent package store with these logical records:

```text
blobs/<sha256>.swpkg
catalogs/<repo>/<generation>
activations/<generation>.json
active_generation
```

The store may be implemented as an append-only block format at first. It only
needs to support:

- write blob if absent;
- read blob by hash;
- write candidate activation manifest;
- atomically select active activation;
- enumerate history;
- garbage collect blobs not reachable from recent activations.

The current package-store boot path implements the read side of this model for
activation: a `SWPKGST1` block image contains payload records, activation
records, and an active pointer. The kernel mounts payload images referenced by
the active generation. The local install path adds the first target-side append
path for local `.swpkg` files and live activation. Later lifecycle and
repository work will broaden that into remove, rollback, history, repository
catalogs, downloads, and garbage collection.

Activation manifest:

```json
{
  "generation": 17,
  "created_by": "pkg install curl",
  "packages": [
    {
      "name": "ca-certificates",
      "version": "2026.01",
      "package": "sha256:...",
      "payload": "sha256:..."
    },
    {
      "name": "curl",
      "version": "8.10.1_1",
      "package": "sha256:...",
      "payload": "sha256:..."
    }
  ]
}
```

On boot, the kernel or an early package-store service reads the active
generation and mounts the listed package payload images into the VFS. For live
installation, `pkg` asks the service/kernel to activate the new generation
without reboot. If live activation is temporarily unsupported in an early
milestone, `pkg` should say exactly that:

```text
Installed curl-8.10.1_1.
Activation will complete after reboot.
```

The target should still move quickly to live activation because the user-facing
goal is Ubuntu-like installation.

## Namespace and Conflict Rules

Activation validates the full file namespace before switching generations.

Rules:

- base image wins over packages unless a package explicitly declares an allowed
  replacement path;
- two packages cannot install the same path unless one declares `replaces`;
- package files under `/usr` are preferred;
- `/etc` package defaults should live under `/usr/share/<pkg>` or
  `/etc/pkg/defaults/<pkg>` until a persistent config store exists;
- service state belongs in tmpfs for now, and later in a separate persistent
  data-volume design.

Removal is just a new activation generation without the package. Files vanish
atomically from the namespace; old package blobs can be garbage-collected later.

## CLI Specification

`pkg` should be quiet, predictable, and scriptable. Default output is concise;
`-v` gives detail.

### Commands

```sh
pkg update
pkg search <text>
pkg info <name>
pkg install <name>...
pkg remove <name>...
pkg upgrade
pkg list
pkg files <name>
pkg which <path>
pkg history
pkg rollback [generation]
pkg clean
pkg repo list
pkg repo add <name> <url>
pkg repo remove <name>
```

FreeBSD-style aliases can be added where they help:

```sh
pkg install
pkg delete        # alias for remove
pkg upgrade
pkg info
pkg query         # later, for formatted package DB queries
```

Avoid making the common path more complex than:

```sh
pkg update
pkg install nginx
```

### Install UX

Example:

```text
$ pkg install curl
Updating catalog: swift-os-current [ok]
The following packages will be installed:
  ca-certificates-2026.01
  curl-8.10.1_1

Download: 2.8 MiB
Install size: 7.4 MiB

Proceed? [Y/n] y
Fetching ca-certificates-2026.01 [ok]
Fetching curl-8.10.1_1 [ok]
Verifying signatures [ok]
Activating generation 18 [ok]
```

For non-interactive use:

```sh
pkg install -y curl
pkg upgrade -y
```

### Exit Codes

- `0`: success;
- `1`: generic failure;
- `2`: usage error;
- `3`: package not found;
- `4`: dependency conflict;
- `5`: signature/hash failure;
- `6`: ABI mismatch;
- `7`: store/activation failure;
- `8`: network failure.

## Dependency Solver

Start small:

- exact package names;
- semantic-ish version ordering with package revision suffixes;
- `>=`, `=`, `<` constraints;
- no optional features in v1;
- no SAT solver until real packages prove it is necessary.

Static linking means many runtime dependencies disappear. Most dependencies will
be data packages, service packages, certificate bundles, terminfo, timezone
data, or package-provided helper tools.

## Capabilities and Services

Packages must not grant themselves authority. A package can declare the
capabilities its service needs, but activation must route those declarations
through the OS service manager and policy model.

Target shape:

```json
{
  "services": [
    {
      "name": "httpd",
      "exec": "/usr/sbin/httpd",
      "args": ["-r", "/www"],
      "principal": "www",
      "capabilities": [
        "fs.read:/www",
        "net.listen:tcp:80"
      ]
    }
  ]
}
```

In the early capability-bitmask system this can only be approximated. The
manifest should still be written in the stronger future shape so the package
format does not have to change when handle-based capabilities arrive.

## No Maintainer Scripts by Default

Traditional package scripts are convenient, but they are also a large trusted
surface. The v1 target installer should support declarative actions only:

- install files;
- register service manifest;
- declare principals/groups needed by a service;
- declare config defaults;
- run package-provided smoke test only in CI, not on the user's machine by
  default.

If a later package genuinely needs install-time code, make it an explicit,
reviewed escape hatch with a constrained execution environment and visible user
approval.

## Ports Tree

A port recipe describes how to build a package from source for swift-os.

Example `Port.json`:

```json
{
  "schemaVersion": 1,
  "name": "curl",
  "version": "8.10.1",
  "revision": 1,
  "category": "www",
  "summary": "Command line URL transfer tool",
  "homepage": "https://curl.se/",
  "license": ["curl"],
  "maturity": "scaffolded",
  "source": {
    "url": "https://curl.se/download/curl-8.10.1.tar.xz",
    "sha256": "..."
  },
  "target": {
    "arch": "aarch64",
    "os": "swift-os",
    "abi": "swos-0",
    "libc": "newlib-4.6-swos",
    "linkage": "static"
  },
  "build": {
    "system": "configure",
    "args": ["--host=aarch64-swiftos", "--disable-shared", "--enable-static"],
    "env": {
      "AR": "llvm-ar",
      "CC": "swos-cc",
      "RANLIB": "llvm-ranlib"
    }
  },
  "install": {
    "destdir": true,
    "command": ["make", "install", "DESTDIR=${DESTDIR}"]
  },
  "package": {
    "depends": ["ca-certificates"],
    "provides": ["curl"],
    "conflicts": [],
    "files": [
      { "from": "destdir/usr/bin/curl", "to": "/usr/bin/curl", "mode": "0755" },
      { "from": "destdir/usr/share/man/man1/curl.1", "to": "/usr/share/man/man1/curl.1", "mode": "0644" }
    ],
    "capabilities": {
      "default": ["net.client"],
      "services": []
    }
  },
  "test": {
    "qemu": ["/usr/bin/curl --version"]
  },
  "notes": "Example only; exact curl flags depend on the selected TLS backend."
}
```

The recipe format should be boring. Most ports should not need custom code.
When custom build glue is required, keep it in small checked-in scripts under
the port directory.

## FreeBSD Ports Import

Build a helper, tentatively `freebsd-import`, that can scaffold a swift-os port
from a FreeBSD port:

```sh
swport import-freebsd www/curl
```

The importer can copy or translate:

- upstream source URL and checksums;
- license metadata;
- patches under `files/`;
- configure/cmake flags;
- package plist;
- dependency hints.

The importer must mark uncertain fields with review markers. It should not
pretend that a FreeBSD port is automatically valid for SwiftOS. Common manual
work will be:

- remove FreeBSD-specific assumptions;
- replace system calls not present on swift-os;
- force static linking;
- point to newlib/musl headers;
- disable plugins, NSS, PAM, dynamic modules, `dlopen`, locale features, or
  pthread features that are not ready yet;
- add a QEMU smoke test.

## Build Tool

Use a maintainer-side tool named `swport`:

```sh
swport fetch shells/oksh
swport build shells/oksh
swport test shells/oksh
swport package shells/oksh
swport publish shells/oksh --channel current
swport bulk --changed
```

Normal package maintenance should be almost fully automated:

```sh
swport new www/curl --from-freebsd www/curl
swport bump www/curl 8.10.1
swport build www/curl
swport test www/curl
swport package www/curl
```

In the common case, the maintainer edits only:

- `Port.json`;
- small patches under `patches/`;
- optional files under `files/`;
- the QEMU smoke test command.

Everything else is generated or derived: source fetches, checksum verification,
work directories, cross-toolchain environment, `DESTDIR`, file manifests,
payload image creation, package signing, catalog regeneration, and publishing.

Pipeline:

1. fetch distfiles;
2. verify checksums;
3. unpack into an isolated work directory;
4. apply patches;
5. configure with the swift-os cross toolchain and sysroot;
6. build static artifacts;
7. install into `DESTDIR`;
8. normalize ownership, modes, timestamps, and paths;
9. run host checks;
10. build a package payload image;
11. run QEMU smoke tests;
12. sign package metadata;
13. publish blobs and regenerate the signed catalog.

The build output should be reproducible when practical:

- deterministic timestamps;
- sorted file lists;
- fixed owners/groups in package images;
- recorded toolchain versions;
- source hashes in manifests.

### Automation Levels

The package pipeline has three automation levels.

**Level 1: local developer automation.** A maintainer can build one package from
one command:

```sh
swport package www/curl
```

This command must fetch, verify, patch, configure, build, install into `DESTDIR`,
normalize, create `.swpkg`, and print the exact output path.

**Level 2: pull request automation.** A ports PR automatically builds every
changed port and its reverse dependency smoke-test set when practical. The PR
must show:

- recipe lint result;
- source checksum result;
- build result;
- package manifest diff;
- QEMU smoke test log;
- produced `.swpkg` artifact for review.

**Level 3: repository publishing automation.** A merge to `main` or a maintainer
approval job performs a clean rebuild, signs package metadata, uploads blobs,
regenerates the signed catalog, and publishes a new repository generation.

Publishing must be content-addressed and idempotent: rerunning the same job
should produce the same package hash or fail loudly with a reproducibility
diagnostic.

## CI and Hosting

CI should build packages on every ports PR and run a bulk build on schedule.
The human should not manually upload package blobs or edit repository catalogs.

Recommended stages:

```text
lint recipe
fetch and checksum
cross-build
package
boot QEMU with package image
run package smoke test
publish on merge or maintainer approval
```

Recommended GitHub flow:

1. A maintainer opens a PR against `swift-os-ports`.
2. CI runs `swport bulk --changed --smoke`.
3. CI uploads preview `.swpkg` artifacts to the PR.
4. A maintainer reviews the recipe, patches, manifest diff, and QEMU logs.
5. After merge, a trusted publishing workflow rebuilds from scratch.
6. The workflow uploads package blobs to the binary host.
7. The workflow regenerates and signs `catalog.json`.
8. The workflow updates `swift-os-packages` with the new catalog generation.
9. Users receive the package through `pkg update`.

This means making a package should usually be:

```sh
git checkout -b ports/lua-5.4
swport new lang/lua
$EDITOR ports/lang/lua/Port.json
swport test lang/lua
git push
```

After review and merge, publication is automatic.

Hosting can start with GitHub Releases or GitHub Pages. Move large blobs to
object storage/CDN when packages grow, especially for Node.js, JVM, and larger
Swift runtimes.

## OS Work Needed

Package management requires new OS features, but they can land in small slices.
Ready-to-paste prompts for these slices live in
[PACKAGE_MANAGER_SESSION_PROMPTS.md](PACKAGE_MANAGER_SESSION_PROMPTS.md).

### Host-Only Package Format

Implemented in `tools/swpkg.swift`, `tools/packfs.swift`,
`docs/SWPKG_FORMAT.md`, and `tests/swpkg_tool_test.swift`.

Acceptance:

- host tests verify deterministic `.swpkg` creation, inspection, payload hash
  validation, manifest hash validation, and corrupt-package rejection.

### VFS Package Image Overlay

Implemented in `kernel/drivers/virtio_blk.swift`, `kernel/vfs/vfs.swift`,
`kernel/user/exec.swift`, `tools/swpkg.swift`, and
`tests/package_overlay_test.sh`.

Acceptance:

- QEMU boots with a base image and package payload image.
- VFS selects the base image by contents rather than virtio-mmio scan order.
- QEMU boot assertion runs `/usr/bin/pkghello` from the package image.

### Package Store

Implemented boot activation:

- `tools/pkgstore.swift` creates and inspects `SWPKGST1` package-store images.
- `kernel/pkg/store.swift` reads payload records, activation records, and the
  active-generation pointer at boot.
- `tests/pkg_store_boot_test.sh` boots a preseeded store image and runs
  `/usr/bin/pkghello` from the active package generation.

Implemented local target-side install:

- `/bin/pkg install FILE` parses a local `.swpkg` staged in the base image.
- The kernel verifies hashes, appends the payload to a writable package-store
  disk, switches the active generation, and live-mounts the payload.
- `/bin/pkg list` reports active package-store records.
- `tests/pkg_local_install_test.sh` installs `/packages/pkghello.swpkg` and
  runs `/usr/bin/pkghello` without rebooting.

Remaining local lifecycle work:

- `pkg files NAME`.
- `pkg remove NAME`.
- `pkg rollback [generation]`.
- Stronger user-facing diagnostics for failed local installs.

### Complete Local `pkg` Lifecycle

Extend the base-image `/bin/pkg` local-file workflow:

```sh
pkg install ./pkghello.swpkg
pkg list
```

Acceptance:

- QEMU test installs a local package, runs it, removes it, proves it is gone,
  then rolls back to the previous active generation.

### Repository Catalogs and Network Fetch

Implemented in `tools/pkgrepo.swift`, `userland/pkg.swift`,
`docs/PKGREPO_FORMAT.md`, `tests/pkgrepo_tool_test.swift`, and
`tests/pkg_repo_install_test.sh`.

```sh
pkg repo set http://10.0.2.2:<port>/aarch64/current
pkg update
pkg update http://10.0.2.2:<port>/aarch64/current
pkg search pkghello
pkg info pkghello
pkg install pkghello
```

The repository fixture is a static HTTP tree with `catalog.signed` plus
content-addressed `.swpkg` blobs. `/bin/pkg` verifies the catalog signature with
`/etc/pkg/repo-root.pub`, rejects expired and incompatible catalogs, verifies
the downloaded package SHA-256, resolves catalog dependencies by package name,
then reuses the local install path. The package-store activation path keeps
previous active payloads mounted while adding newly installed payloads, which is
the minimum needed for dependency packages to remain visible.

Acceptance:

- QEMU test starts a host HTTP server, rejects expired/wrong-arch/bad-hash
  repository fixtures, guest configures a default repo with `pkg repo set`, runs
  `pkg update && pkg install pkghello`, auto-installs `pkgdep`, then executes
  `/usr/bin/pkghello`.

Remaining repository work:

- add version-constraint solving and `pkg upgrade`;
- replace tmpfs package caching with streaming store writes for large packages;
- add HTTPS/certificate verification after the userland TLS stack is ready.

### Ports Tree Bootstrap

Current state: `swift-os` carries a checked machine-readable seed catalog,
`ports/catalog.json`, host-side `build/swport catalog validate/list/inspect`
commands, and checked recipes for Lua, zlib, bzip2, zstd, ca-certificates, pcre2,
tzdata, nginx, and sqlite. `swport recipe validate`, `swport recipe manifest`, checksum-verified
`swport recipe fetch`, staged-root `swport recipe package`, and signed
`swport recipe repo-fixture` exist for those checked paths. The seed targets
cross-build real static AArch64 packages where applicable, package data-only
artifacts for CA certificates and time zones, publish all nine packages into one
signed local seed repository, and install them by package name in QEMU. The
static-host targets publish that seed into a deployable web root and prove
installs from the hosted layout; the DNS hosted-repository smoke proves the same
path through a resolved repository hostname. This is deliberately not the full
ports tree yet; it makes package priorities, dependency names, OS prerequisite
bundles, blockers, and the recipe-to-repository contract reviewable before the
separate `swift-os-ports` repository exists.

- Keep `ports/catalog.json` valid with `make ports-catalog-test`.
- Keep the checked source recipe workflow valid with `make ports-recipe-test`.
- Keep the real Lua, zlib, bzip2, zstd, pcre2, nginx, and sqlite binary package paths plus
  the ca-certificates/tzdata data package path valid with
  `make ports-lua-repo-fixture`, `make ports-zlib-repo-fixture`,
  `make ports-bzip2-repo-fixture`,
  `make ports-ca-certificates-repo-fixture`, `make ports-pcre2-repo-fixture`,
  `make ports-tzdata-repo-fixture`, `make ports-nginx-repo-fixture`, and
  `make ports-sqlite-repo-fixture`
  when `make newlib` has populated the generated sysroot.
- Keep the first multi-package target install/run path valid with
  `make package-ports-seed-repo-install-test`.
- Keep the static-host publish/install path valid with
  `make ports-static-host-publish` and
  `make package-static-host-repo-install-test`.
- Move the seed catalog and recipes into `swift-os-ports` once real package
  builds land.
- Add full `swport` recipe commands: `new`, `build`, `test`, `package`, and
  `publish`.
- Port 3 to 5 small packages.
- Publish a bootstrap/current repository.

Good early candidates:

- `oksh` or another small shell;
- `lua`;
- `zlib` as a build/runtime dependency exercise;
- `curl` once sockets, DNS, certificates, and TLS expectations are clear;
- a small HTTP static server or benchmark utility.

Acceptance:

- `make ports-catalog-test` validates the seed catalog.
- `make ports-recipe-test` validates the checked Lua, zlib, bzip2,
  ca-certificates, pcre2, tzdata, nginx, and sqlite recipes and proves the generated manifest can feed
  `swport recipe package`,
  `swpkg verify`, and a signed local `pkgrepo` repository fixture.
- `make ports-lua-repo-fixture` builds real static AArch64 Lua and publishes
  the runtime interpreter into a signed local repository fixture.
- `make ports-zlib-repo-fixture` builds real static AArch64 zlib, headers,
  pkgconf metadata, and `minigzip`.
- `make ports-bzip2-repo-fixture` builds static AArch64 bzip2 CLI tools,
  `libbz2.a`, `bzlib.h`, pkgconf metadata, and a marker file.
- `make ports-ca-certificates-repo-fixture` packages the pinned Mozilla CA
  bundle as a data-only `.swpkg`.
- `make ports-pcre2-repo-fixture` builds real static AArch64 PCRE2 libraries,
  headers, pkgconf metadata, and `pcre2grep`.
- `make ports-tzdata-repo-fixture` compiles IANA TZif zoneinfo files and
  packages the `/usr/share/zoneinfo` tree.
- `make ports-nginx-repo-fixture` builds minimal static HTTP-only nginx and
  packages its default config and marker files.
- `make ports-sqlite-repo-fixture` builds static SQLite and packages the
  `sqlite3` shell, library, headers, pkgconf metadata, and marker files.
- `make package-ports-seed-repo-install-test` installs Lua, zlib, bzip2,
  ca-certificates, pcre2, tzdata, nginx, and sqlite from one signed local seed
  repository and runs their package smoke paths inside QEMU.
- `make ports-static-host-publish` creates a deployable static web root for the
  seed repository, and `make package-static-host-repo-install-test` installs
  Lua, zlib, bzip2, zstd, ca-certificates, pcre2, tzdata, nginx, and sqlite from that layout
  inside QEMU.
- CI builds and publishes packages.
- A fresh swift-os image installs one package from the public repository.

### Upgrade, History, and Garbage Collection

- Implement dependency upgrades.
- Keep activation history.
- Garbage-collect unreachable package blobs.

Acceptance:

- QEMU test upgrades `pkghello` from v1 to v2, rolls back to v1, then cleans
  unreachable blobs.

### Services and Declarative Policy

- Package manifests can register services.
- Service manager reads package service declarations.
- Capability declarations are displayed and enforced as far as the current
  security model allows.

Acceptance:

- Installing a packaged HTTP service registers it, starts it, and a host curl
  reaches it through QEMU port forwarding.

## First Public UX Target

The first public package demo should be:

```sh
pkg update
pkg install lua
lua -v
```

The test package can be `pkghello`, but the human-facing milestone should use a
real upstream package. `lua` is a good first candidate because it is small,
useful, and much less demanding than `curl`, Node.js, or the JVM.

## Open Decisions

- Exact package manifest encoding: JSON first, CBOR later?
- Exact package-store block format.
- Whether live activation is implemented directly in the kernel VFS or through
  a privileged package-store service.
- Repository key rotation policy.
- How much FreeBSD ports metadata should be imported automatically versus
  scaffolded with review markers.
- Whether the first hosted repository lives on GitHub Releases, GitHub Pages,
  or object storage.
- When to introduce compression.
- Whether `pkg` lives permanently in `swift-os` or later moves to a shared
  tools repository.

## Default Decisions

Unless changed by the maintainer, start with these defaults:

- package manager command: `pkg`;
- ports/build command: `swport`;
- package extension: `.swpkg`;
- package payload: uncompressed packed read-only image;
- target package prefix: `/usr`;
- binary repository URL: static HTTP with signed metadata;
- signature algorithm: Ed25519;
- hash algorithm: SHA-256;
- first real demo package: `lua`;
- no maintainer scripts in v1;
- no direct mutation of root or `/usr`.
