# SwiftOS Package Guide

This guide explains the package workflows that work in the current checked-in
SwiftOS tree. It is the practical companion to the package design documents: use
it when you want to build the sample package, inspect artifacts, boot package
content, and collect support evidence.

SwiftOS packages follow the system's immutable-image model. A package is built
on the host, verified on the host, and exposed to the guest as read-only package
content under `/usr`. The current target-side package manager supports local
file install, `pkg install FILE`, into a writable package-store disk, plus a
P5c signed static HTTP repository fixture with `pkg repo set`, `pkg update [URL]`,
and `pkg install NAME`. Repository installs resolve dependencies by package
name. Public hosted repositories, version-constraint solving, remove, upgrade,
and rollback are staged work, not current behavior. The ports workflow can
cross-build static AArch64 Lua and zlib packages on the host, publish them into
signed local repository fixtures, install Lua by package name in QEMU, and boot
SwiftOS with a default repository URL to install both Lua and zlib from one
seed repository. It can also produce a static-hostable web root for that seed
repository and prove that SwiftOS installs from that published layout.

Use this guide with:

- [Package Management](PACKAGE_MANAGEMENT.md) for the long-term package manager
  design and roadmap.
- [Package Build Automation Guide](PACKAGE_BUILD_AUTOMATION.md) for package
  recipe, CI smoke-test, and repository publishing plans.
- [SWPKG Format](SWPKG_FORMAT.md) for the `.swpkg` container format.
- [Package Store Format](PKGSTORE_FORMAT.md) for the P3a package-store image.
- [Static Package Repository](PKGREPO_FORMAT.md) for the P5c signed HTTP
  repository layout.
- [Server Software Catalog](SERVER_SOFTWARE_CATALOG.md) for prioritized server
  packages and porting prerequisites.
- [Operations Guide](OPERATIONS_GUIDE.md) for QEMU boot profiles.
- [Application Cookbook](APPLICATION_COOKBOOK.md) for package authoring context.
- [Troubleshooting](TROUBLESHOOTING.md) for package failure diagnosis.

## Current Package State

| Capability | Status |
| --- | --- |
| Host `.swpkg` tool | Implemented as `build/swpkg` |
| Deterministic sample package | Implemented as `build/pkghello.swpkg` |
| Payload extraction | Implemented as `build/pkghello-payload.img` |
| Direct payload overlay boot | Implemented and proven by `make package-overlay-test` |
| Package-store bootstrap image | Implemented as `build/pkgstore-pkghello.img` |
| Package-store boot activation | Implemented and proven by `make package-store-test` |
| Target-side `/bin/pkg install FILE` | Implemented for local `.swpkg` files and proven by `make package-local-install-test` |
| Target-side `/bin/pkg list` | Implemented for the active package-store records |
| Host static repository tool | Implemented as `build/pkgrepo` |
| Signed static HTTP repository fixture | Implemented as `build/pkgrepo-root` and proven by `make package-repo-fixture` |
| Target-side `pkg repo set`, `pkg update [URL]`, `search`, `info`, and `install NAME` | Implemented for the signed HTTP fixture and proven by `make package-repo-install-test` |
| Target-side dependency resolution by package name | Implemented for signed repository catalogs |
| Ports catalog and Lua/zlib recipe checks | Implemented with `ports/catalog.json`, `ports/lang/lua/Port.json`, `ports/archivers/zlib/Port.json`, and `build/swport` |
| Lua cross-build repository fixture | Implemented as `make ports-lua-repo-fixture` |
| Target-side `pkg install lua` from the signed Lua repository fixture | Implemented and proven by `make package-lua-repo-install-test` |
| zlib cross-build repository fixture | Implemented as `make ports-zlib-repo-fixture` |
| Multi-package ports seed repository fixture | Implemented as `make ports-seed-repo-fixture`; guest install smoke is `make package-ports-seed-repo-install-test` |
| Static-host publish root | Implemented as `make ports-static-host-publish`; guest install smoke is `make package-static-host-repo-install-test` |
| Target-side remove, upgrade, rollback, version-constraint solving | Not implemented yet |
| Public hosted domain and channel policy | Not implemented yet |
| Streaming large-package downloads | Not implemented yet |

The current user-visible package fixture is `/usr/bin/pkghello`. It is not part
of the base image. It appears when a package payload image is attached at boot,
when a preseeded package-store image is attached at boot, or after
`pkg install /packages/pkghello.swpkg` succeeds against a writable package-store
disk. It can also be installed by name from the P5c signed HTTP fixture after
`pkg repo set URL && pkg update` or `pkg update URL` caches a verified repository
catalog.

The current real source-port fixtures are Lua and zlib. They are useful for
package maintainers and release owners because they prove source fetch,
checksum verification, static cross-build, `.swpkg` creation, signed local
repository publication, target-side Lua install from a signed repository, and
target-side Lua+zlib install from a default repository URL. They are still local
fixtures, not public hosted channels.

## Mental Model

SwiftOS does not install packages by unpacking files into a mutable root
filesystem. The current model is:

```text
read-only base image
  + active read-only package payloads
  + RAM tmpfs scratch
  = guest VFS namespace
```

The three package artifact types have different jobs:

| Artifact | Built by | Used for |
| --- | --- | --- |
| `build/pkghello.swpkg` | `build/swpkg create` | Host package container with manifest and payload |
| `build/pkghello-payload.img` | `build/swpkg extract-payload` | Sector-aligned read-only payload image attached as a virtio-blk disk |
| `build/pkgstore-pkghello.img` | `build/pkgstore create` | P3a package-store image with payload records and an active generation |
| `build/pkgstore-install.img` | `make package-local-install-fixture` | Empty writable package-store image for target-side local install tests |
| `build/pkgrepo-root` | `build/pkgrepo create` | P5c signed static HTTP repository tree |
| `build/pkgrepo-root.pub` | `build/pkgrepo pubkey` | Public key copied into the base image as `/etc/pkg/repo-root.pub` |
| `build/ports-seed-repo-root` | `make ports-seed-repo-fixture` | Signed local repository containing the checked Lua and zlib packages |
| `build/ports-static-host-root` | `make ports-static-host-publish` | Deployable static web root containing the ports seed repository, public key, sidecar manifest, and SHA-256 sums |

Use the direct payload overlay when you want the simplest package-content boot.
Use the package-store image when you want to test the current activation-record
path. Use the local install path when you want to prove the guest can append a
local `.swpkg` payload to a writable package-store disk and live-mount it.
Use the ports seed repository path when you want to prove the first multi-package
hosted-style workflow.

## Quick Start

Build the kernel, base image, DTB, host package tools, and sample package:

```sh
make build base-image build/virt.dtb
make package-fixture
```

Inspect and verify the `.swpkg` artifact:

```sh
build/swpkg inspect build/pkghello.swpkg
build/swpkg verify build/pkghello.swpkg
```

Inspect the package-store image:

```sh
make package-store-fixture
build/pkgstore inspect build/pkgstore-pkghello.img
```

Inspect the signed repository fixture:

```sh
make package-repo-fixture
build/pkgrepo inspect build/pkgrepo-root/aarch64/current/catalog.signed
```

Build and inspect the Lua port repository fixture:

```sh
make ports-lua-repo-fixture
build/swpkg inspect build/lua.swpkg
build/pkgrepo inspect build/lua-repo-root/aarch64/current/catalog.signed
```

Build the deployable static-host repository root:

```sh
make ports-static-host-publish
shasum -a 256 -c build/ports-static-host-root/SHA256SUMS
build/pkgrepo inspect build/ports-static-host-root/aarch64/current/catalog.signed
```

Run the acceptance tests:

```sh
make package-overlay-test
make package-store-test
make package-local-install-test
make package-repo-install-test
make ports-catalog-test
make ports-recipe-test
```

## Host Tools

### `build/swpkg`

`build/swpkg` is the host-side package container tool.

```sh
make swpkg

build/swpkg create --manifest fixtures/pkghello/manifest.json --root build/pkghello-root --output build/pkghello.swpkg
build/swpkg inspect build/pkghello.swpkg
build/swpkg verify build/pkghello.swpkg
build/swpkg extract-payload build/pkghello.swpkg build/pkghello-payload.img
```

The package fixture target runs the correct sequence for the sample package.
Most users should start with:

```sh
make package-fixture
```

### `build/pkgstore`

`build/pkgstore` is the host-side P3a package-store image tool.

```sh
make pkgstore

build/pkgstore create --package build/pkghello.swpkg --output build/pkgstore-pkghello.img --generation 1
build/pkgstore inspect build/pkgstore-pkghello.img
```

The package-store fixture target builds and inspects the sample store:

```sh
make package-store-fixture
```

Build an empty writable store for local guest installs:

```sh
make package-local-install-fixture
```

### `build/pkgrepo`

`build/pkgrepo` is the host-side P5c static repository tool.

```sh
make pkgrepo

SEED=000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
build/pkgrepo pubkey --seed-hex "$SEED" --output build/pkgrepo-root.pub
build/pkgrepo create \
  --package build/pkghello.swpkg \
  --output build/pkgrepo-root \
  --seed-hex "$SEED" \
  --generation 1
build/pkgrepo verify --catalog-signed build/pkgrepo-root/aarch64/current/catalog.signed --pubkey build/pkgrepo-root.pub
build/pkgrepo inspect build/pkgrepo-root/aarch64/current/catalog.signed
```

Most users should start with:

```sh
make package-repo-fixture
```

## Boot A Direct Package Payload

This is the P2 overlay path. Build the fixture:

```sh
make build base-image build/virt.dtb
make package-fixture
```

Boot QEMU with the base image plus the package payload image:

```sh
qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -global virtio-mmio.force-legacy=false \
  -device loader,file=build/virt.dtb,addr=0x4FF00000,force-raw=on \
  -drive file=build/base.img,format=raw,if=none,id=swosbase,readonly=on \
  -device virtio-blk-device,drive=swosbase \
  -drive file=build/pkghello-payload.img,format=raw,if=none,id=swospkg0,readonly=on \
  -device virtio-blk-device,drive=swospkg0 \
  -kernel build/kernel.elf
```

Log in as `root` and run:

```sh
/usr/bin/pkghello
```

Expected output:

```text
pkghello: hello from package overlay
```

Proof:

```sh
make package-overlay-test
```

## Boot A Package Store

This is the P3a package-store activation path. Build the fixture:

```sh
make build base-image build/virt.dtb
make package-store-fixture
```

Boot QEMU with the base image plus the package-store image:

```sh
qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -global virtio-mmio.force-legacy=false \
  -device loader,file=build/virt.dtb,addr=0x4FF00000,force-raw=on \
  -drive file=build/base.img,format=raw,if=none,id=swosbase,readonly=on \
  -device virtio-blk-device,drive=swosbase \
  -drive file=build/pkgstore-pkghello.img,format=raw,if=none,id=swpkgstore \
  -device virtio-blk-device,drive=swpkgstore \
  -kernel build/kernel.elf
```

The serial log should include package-store activation markers:

```text
P3: package store active generation
P3: package store payload mounted
```

Log in as `root` and run:

```sh
/usr/bin/pkghello
```

Expected output:

```text
pkghello: hello from package overlay
```

The program text still says "package overlay" because the final VFS result is
the same: a read-only package payload mounted under `/usr`.

Proof:

```sh
make package-store-test
```

## Install A Local Package In The Guest

This is the current P3b local install path. It does not fetch from a repository
and it does not resolve dependencies. It verifies a local `.swpkg`, appends its
payload to a writable package-store disk, activates a new generation, and
live-mounts the payload under `/usr`.

Build the package fixture, base image, and writable package-store image:

```sh
make build base-image build/virt.dtb
make package-fixture
make package-local-install-fixture
```

Boot QEMU with the base image plus the writable store image:

```sh
qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -global virtio-mmio.force-legacy=false \
  -device loader,file=build/virt.dtb,addr=0x4FF00000,force-raw=on \
  -drive file=build/base.img,format=raw,if=none,id=swosbase,readonly=on \
  -device virtio-blk-device,drive=swosbase \
  -drive file=build/pkgstore-install.img,format=raw,if=none,id=swpkgstore \
  -device virtio-blk-device,drive=swpkgstore \
  -kernel build/kernel.elf
```

Log in as `root`, then run:

```sh
pkg list
pkg install /packages/pkghello.swpkg
pkg list
/usr/bin/pkghello
```

Expected output includes:

```text
no packages installed
pkg: installed pkghello-1.0.0_1
pkghello-1.0.0_1
pkghello: hello from package overlay
```

The `.swpkg` file is staged in the read-only base image under `/packages` for
the fixture. Repository install tests use the signed HTTP fixture described in
the next section.

Proof:

```sh
make package-local-install-test
```

## Install From A Signed HTTP Repository Fixture

This is the current P5c repository path. It uses an explicit or configured
repository URL, verifies `catalog.signed` with `/etc/pkg/repo-root.pub`,
rejects expired or incompatible catalogs, resolves dependencies by package
name, downloads content-addressed `.swpkg` files, verifies SHA-256, then reuses
the local install path to activate the payloads.

Build the repository fixture and writable package-store image:

```sh
make build base-image build/virt.dtb
make package-repo-fixture
make package-local-install-fixture
```

The acceptance test starts a host HTTP server and drives QEMU automatically:

```sh
make package-repo-install-test
```

Inside the guest, the tested flow first rejects negative fixtures:

```sh
pkg update http://10.0.2.2:<port>/expired/aarch64/current
pkg update http://10.0.2.2:<port>/wrongarch/aarch64/current
```

Then it installs from the valid repository:

```sh
pkg update http://10.0.2.2:<port>/good/aarch64/current
pkg search pkghello
pkg info pkghello
pkg install pkghello
/usr/bin/pkghello
```

Expected output includes:

```text
pkg: catalog expired
pkg: catalog incompatible
pkg: catalog updated http://10.0.2.2:<port>/good/aarch64/current
pkghello-1.0.0_1
sha256:
pkg: installed pkghello-1.0.0_1
pkghello: hello from package overlay
```

The same test later points the guest at a bad-hash repository and expects
`pkg: package SHA-256 mismatch` before the package is allowed to install.

## Build The Lua Port Repository Fixture

This is the Lua-specific P6e/P6f source-port path. It cross-builds real static
AArch64 `lua` and `luac` binaries against the local newlib sysroot, packages
them into `build/lua.swpkg`, and publishes a signed local repository fixture
under `build/lua-repo-root`. The P6f QEMU smoke then installs `lua` from that
repository and runs it inside SwiftOS.

If the generated sysroot is missing, build it first:

```sh
make newlib
```

Then build the Lua fixture:

```sh
make ports-lua-repo-fixture
```

Expected host artifacts:

| Artifact | Purpose |
| --- | --- |
| `build/lua.swpkg` | `.swpkg` containing `/usr/bin/lua` and `/usr/bin/luac` |
| `build/lua-repo-root/aarch64/current/catalog.signed` | Signed local repository catalog for the Lua package |
| `build/lua-repo-root.pub` | Public key for verifying the Lua repository fixture |
| `build/swport-distfiles/lua-5.4.8.tar.gz` | Checksum-verified upstream source tarball cache |

Inspect the result:

```sh
build/swpkg verify build/lua.swpkg
build/pkgrepo verify \
  --catalog-signed build/lua-repo-root/aarch64/current/catalog.signed \
  --pubkey build/lua-repo-root.pub
build/pkgrepo inspect build/lua-repo-root/aarch64/current/catalog.signed
```

Run the target-side Lua repository smoke:

```sh
make package-lua-repo-install-test
```

The guest-side flow exercised by the test is:

```sh
pkg repo set http://10.0.2.2:<port>/aarch64/current
pkg update
pkg search lua
pkg info lua
pkg install lua
/usr/bin/lua -v
/usr/bin/lua -e 'print(21 * 2)'
```

## Build The Ports Seed Repository Fixture

P7 adds zlib and publishes the checked Lua and zlib source-port packages into
one signed local seed repository. This is the closest current stand-in for the
future hosted package channel: the guest boots with a default repository URL,
runs `pkg update`, installs both packages by name, and exercises the installed
programs.

```sh
make ports-zlib-repo-fixture
make ports-seed-repo-fixture
build/swpkg verify build/zlib.swpkg
build/pkgrepo inspect build/ports-seed-repo-root/aarch64/current/catalog.signed
make package-ports-seed-repo-install-test
```

Expected additional artifacts:

| Artifact | Purpose |
| --- | --- |
| `build/zlib.swpkg` | `.swpkg` containing zlib headers, pkgconf metadata, and `/usr/bin/minigzip` |
| `build/zlib-repo-root` | Signed local repository fixture for the standalone zlib package |
| `build/ports-seed-repo-root` | Signed local repository fixture containing both Lua and zlib |

The seed smoke reuses `build/pkgstore-lua-install.img` as its writable
package-store image.

The guest-side flow exercised by the seed smoke is:

```sh
pkg update
pkg install lua
pkg install zlib
/usr/bin/lua -e 'print(21 * 2)'
echo zlib-ok > /tmp/zlib.txt
/usr/bin/minigzip /tmp/zlib.txt
/usr/bin/minigzip -d /tmp/zlib.txt.gz
cat /tmp/zlib.txt
```

## Package Fixture Anatomy

The sample fixture is intentionally small so it can run in every acceptance
gate.

| Path | Purpose |
| --- | --- |
| [fixtures/pkghello/manifest.json](../fixtures/pkghello/manifest.json) | Package manifest used by `build/swpkg create` |
| [userland/pkghello.swift](../userland/pkghello.swift) | Guest program source |
| `build/pkghello-root/usr/bin/pkghello` | Staged package root file |
| `build/pkghello.swpkg` | Host package artifact |
| `build/pkghello-payload.img` | Sector-aligned direct package payload image |
| `build/pkgstore-pkghello.img` | Package-store bootstrap image |
| `build/pkgrepo-root` | Signed static HTTP repository fixture |
| `build/pkgrepo-root.pub` | Public key for repository catalog verification |
| `build/lua.swpkg` | P6e/P6f Lua package artifact from the source-port workflow |
| `build/lua-repo-root` | P6e/P6f signed local repository fixture for Lua |
| `build/pkgstore-lua-install.img` | Writable package-store image used by the Lua repository install smoke |
| `build/zlib.swpkg` | P7 zlib package artifact from the source-port workflow |
| `build/zlib-repo-root` | P7 signed local repository fixture for zlib |
| `build/ports-seed-repo-root` | P7 signed local repository fixture containing Lua and zlib |

Package files install under `/usr`. The current package verifier rejects package
payload paths outside `/usr`.

## Creating Your Own Local Package Fixture

For a local experiment, follow the fixture shape:

1. Build a static SwiftOS executable.
2. Stage it under a package root, usually `build/<name>-root/usr/bin/<name>`.
3. Write a manifest with `target: "swift-os"` and static linkage metadata.
4. Run `build/swpkg create`.
5. Run `build/swpkg verify`.
6. Extract a payload image or create a package-store image.
7. Boot QEMU with the resulting image and run the program from `/usr/bin`.
8. For repository testing, publish it into a local `build/pkgrepo-root` fixture
   and prove `pkg repo set URL && pkg update && pkg install NAME` in QEMU.

Keep current package experiments simple:

- Install real executable paths such as `/usr/bin/tool`.
- Do not rely on symlinks, maintainer scripts, or dynamic libraries.
- Keep dependency metadata simple: P5c resolves package names, but does not
  interpret version constraints yet.
- Do not expect files to persist in `/tmp` after reboot.
- Treat P5c repository signatures as catalog signatures. `.swpkg` reserved
  signature fields are still not package-level publisher signatures.

For reusable application recipes, see
[APPLICATION_COOKBOOK.md](APPLICATION_COOKBOOK.md).

## Verification Matrix

Run the narrowest proof for the path you changed:

| Area | Command |
| --- | --- |
| Host `.swpkg` create/inspect/verify | `make package-fixture` |
| Host package-store create/inspect | `make package-store-fixture` |
| Direct payload overlay boot | `make package-overlay-test` |
| Package-store activation boot | `make package-store-test` |
| Local target-side `.swpkg` install | `make package-local-install-test` |
| Signed static HTTP repository install | `make package-repo-install-test` |
| Ports catalog and checked recipe validation | `make ports-catalog-test`; `make ports-recipe-test` |
| Lua cross-build repository fixture | `make ports-lua-repo-fixture` |
| Target-side Lua repository install/run smoke | `make package-lua-repo-install-test` |
| zlib cross-build repository fixture | `make ports-zlib-repo-fixture` |
| Target-side ports seed repository install/run smoke | `make package-ports-seed-repo-install-test` |
| Static-host repository publish root | `make ports-static-host-publish` |
| Target-side install from static-host publish root | `make package-static-host-repo-install-test` |
| Full package tooling in the full gate | `make test` |

The underlying host tests are:

- [tests/swpkg_tool_test.swift](../tests/swpkg_tool_test.swift)
- [tests/pkgstore_tool_test.swift](../tests/pkgstore_tool_test.swift)
- [tests/pkgrepo_tool_test.swift](../tests/pkgrepo_tool_test.swift)
- [tests/swport_catalog_test.swift](../tests/swport_catalog_test.swift)
- [tests/swport_recipe_test.swift](../tests/swport_recipe_test.swift)

The QEMU tests are:

- [tests/package_overlay_test.sh](../tests/package_overlay_test.sh)
- [tests/pkg_store_boot_test.sh](../tests/pkg_store_boot_test.sh)
- [tests/pkg_local_install_test.sh](../tests/pkg_local_install_test.sh)
- [tests/pkg_repo_install_test.sh](../tests/pkg_repo_install_test.sh)
- [tests/pkg_lua_repo_install_test.sh](../tests/pkg_lua_repo_install_test.sh)
- [tests/pkg_ports_seed_repo_install_test.sh](../tests/pkg_ports_seed_repo_install_test.sh)
- [tests/pkg_static_host_repo_install_test.sh](../tests/pkg_static_host_repo_install_test.sh)

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `/usr/bin/pkghello` is missing | The package image was not attached, the wrong image was attached, or the fixture is stale | Run `make package-fixture`; boot with either `build/pkghello-payload.img` or `build/pkgstore-pkghello.img` |
| QEMU boots but no package-store markers appear | The package-store image was not attached with the expected virtio-blk device | Use the package-store boot profile or run `make package-store-test` |
| `build/swpkg verify` fails | Manifest and payload do not match, hashes are stale, or paths are outside `/usr` | Rebuild the package root and run `make package-fixture` |
| `build/pkgstore inspect` fails | Store image is stale, missing, or corrupt | Rebuild with `make package-store-fixture` |
| Guest command says `/bin/pkg` is missing | The base image is stale or was not rebuilt after `/bin/pkg` was added | Run `make build base-image` |
| `pkg install /packages/pkghello.swpkg` says `cannot open package` | The base image does not contain the fixture package, or the path is wrong | Run `make package-fixture base-image` and use `/packages/pkghello.swpkg` |
| `pkg: install failed` | The writable package-store disk is missing, read-only, full, or corrupt | Attach `build/pkgstore-install.img` without `readonly=on` or rebuild it with `make package-local-install-fixture` |
| `pkg update URL` fails signature verification | The base image key and repository fixture key do not match, or the catalog was modified | Rebuild with `make package-repo-fixture base-image` |
| `pkg install NAME` says the package is not found | The catalog has not been updated in this boot, the URL is wrong, or the fixture lacks that package | Run `pkg update http://10.0.2.2:<port>/good/aarch64/current` in the acceptance fixture, or the matching `/aarch64/current` URL when serving `build/pkgrepo-root` directly |
| `pkg: package SHA-256 mismatch` | The downloaded package blob does not match the signed catalog entry | Rebuild the repository fixture with `make package-repo-fixture` and rerun `make package-repo-install-test` |
| `make ports-lua-repo-fixture` cannot find newlib | The generated cross sysroot is missing | Run `make newlib`, then rerun `make ports-lua-repo-fixture` |
| `pkg install lua` fails in the guest | The Lua repository was not served, `pkg update` did not cache its catalog, or the writable Lua package-store image is missing | Rebuild with `make ports-lua-repo-fixture package-lua-install-fixture`, then run `make package-lua-repo-install-test` |
| `pkg install zlib` fails in the seed smoke | The seed repository was not rebuilt, the default repository URL was not injected, or the writable seed package-store image is missing | Rebuild with `make ports-seed-repo-fixture package-lua-install-fixture`, then run `make package-ports-seed-repo-install-test` |
| `make ports-static-host-publish` fails SHA-256 checks | The seed repository was modified after signing or a copied package blob is stale | Rebuild with `make ports-seed-repo-fixture ports-static-host-publish` |
| Package content disappears after reboot | The package image or writable package-store image was not attached to the new boot | Attach the same package payload, package-store, or writable install-store image each time |

For general package diagnosis, see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md#package-problems).

## Security And Product Limits

Current limits that matter for package use:

- Package content is read-only in the guest.
- The current target-side write paths are local `.swpkg` install and P5c
  repository install into a writable package-store disk.
- The Lua/zlib port fixtures and static-host publish path prove source
  packaging, signed repository publication, target-side repository install, and
  guest execution through `make package-lua-repo-install-test`,
  `make package-ports-seed-repo-install-test`, and
  `make package-static-host-repo-install-test`.
- `.swpkg` hashes prove container integrity. P5c catalog signatures prove the
  repository metadata used to find and hash package blobs; package SHA-256
  checks prove the downloaded blob matches the catalog.
- Public hosted channels, package-level publisher signatures, version-constraint
  solving, remove, upgrade, and rollback commands are future milestones.
- Packages cannot grant themselves process capabilities. Authority remains a
  property of the process identity and launch path.
- The base image remains immutable and wins over package content unless future
  conflict rules explicitly allow replacement.

Do not use current package images as a production software update mechanism.
They are the verified bring-up path for the package format, VFS overlay model,
package-store activation substrate, and local install plumbing.
