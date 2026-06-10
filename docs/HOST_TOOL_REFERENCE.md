# SwiftOS Host Tool Reference

This reference describes the host-side tools that build SwiftOS images,
packages, repositories, model bundles, and the P6-P11 ports seed catalog,
recipe, and repository-publish scaffolding. These commands run on the
development host, not inside the SwiftOS guest.

For guest commands, use [COMMAND_REFERENCE.md](COMMAND_REFERENCE.md). For the
end-to-end package workflow, use
[PACKAGE_BUILD_AUTOMATION.md](PACKAGE_BUILD_AUTOMATION.md).

## Quick Map

| Tool or target | Build target | Purpose | Verification |
| --- | --- | --- | --- |
| `build/basepack` | `make base-image` | Pack a directory into a `SWOSBASE` read-only base image. | `./tests/boot_test.sh` |
| `build/swpkg` | `make swpkg` | Create, inspect, verify, and extract `.swpkg` package artifacts. | `tests/swpkg_tool_test.swift`, `make package-fixture` |
| `build/pkgstore` | `make pkgstore` | Create and inspect package-store disk images. | `tests/pkgstore_tool_test.swift`, `make package-store-test` |
| `build/pkgrepo` | `make pkgrepo` | Create and verify signed static HTTP package repositories. | `tests/pkgrepo_tool_test.swift`, `make package-repo-install-test` |
| `build/swport` | `make swport` | Validate/list/inspect the ports catalog and validate/fetch/manifest/package/repo-fixture the checked Lua, zlib, ca-certificates, and pcre2 recipes. | `make ports-catalog-test`, `make ports-recipe-test` |
| `scripts/build-lua.sh` | `make ports-lua-repo-fixture` | Cross-build static AArch64 `lua`/`luac`, package them, and publish a signed local repository fixture. | `make ports-lua-repo-fixture`, `make package-lua-repo-install-test` |
| `scripts/build-zlib.sh` | `make ports-zlib-repo-fixture` | Cross-build static zlib, headers, pkgconf metadata, and `minigzip`, then publish a signed local repository fixture. | `make ports-zlib-repo-fixture` |
| `scripts/build-ca-certificates.sh` | `make ports-ca-certificates-repo-fixture` | Package the pinned Mozilla CA bundle and publish a signed local repository fixture. | `make ports-ca-certificates-repo-fixture` |
| `scripts/build-pcre2.sh` | `make ports-pcre2-repo-fixture` | Cross-build static PCRE2 libraries, headers, pkgconf metadata, and `pcre2grep`, then publish a signed local repository fixture. | `make ports-pcre2-repo-fixture` |
| `scripts/build-ports-seed-repo.sh` | `make ports-seed-repo-fixture` | Publish the checked Lua, zlib, ca-certificates, and pcre2 packages into one signed local seed repository. | `make package-ports-seed-repo-install-test` |
| `scripts/publish-ports-static-host.sh` | `make ports-static-host-publish` | Create a deployable static web root for the ports seed repository with manifest and checksums. | `make ports-static-host-publish`, `make package-static-host-repo-install-test` |
| `scripts/verify-ports-hosted-url.sh` | `make ports-hosted-url-verify` | Fetch and verify a deployed static-host package repository URL, including sidecar manifest, checksums, package blobs, and signed catalog. | `make ports-hosted-url-verify-test` |
| `build/modelmanifest` | `make base-image` | Generate verified model bundle manifests. | `./tests/llm_serve_test.sh` |
| `build/modelsign` | `make base-image` | Generate model signing keys and sign/verify manifests. | `./tests/llm_serve_test.sh` |
| `build/quantize` | `make model` | Quantize TinyStories checkpoints for the AI demo. | `./tests/llm_run_test.sh` |

## Base Image Packer

`basepack` packs a host directory into the immutable read-only base image used
by the guest VFS.

```text
basepack <root-dir> <output-image>
```

Normal use is through the Makefile:

```sh
make base-image
```

The generated image is `build/base.img`. Boot tests attach it as the base
virtio-blk device.

## Package Artifact Tool

`swpkg` is the host tool for `.swpkg` package containers.

```text
swpkg create --manifest <manifest.json> --root <root-dir> --output <out.swpkg>
swpkg inspect <package.swpkg>
swpkg verify <package.swpkg>
swpkg extract-payload <package.swpkg> <payload.img>
```

Example:

```sh
make package-fixture
build/swpkg inspect build/pkghello.swpkg
build/swpkg verify build/pkghello.swpkg
build/swpkg extract-payload build/pkghello.swpkg build/pkghello-payload.img
```

Important constraints:

- Package payload paths must live under `/usr`.
- Package payloads are packed read-only.
- Package-level publisher signatures are reserved; repository catalogs provide
  the current signed install path.

## Package Store Tool

`pkgstore` creates package-store disk images for boot activation and local
target-side installs.

```text
pkgstore init --output <store.img> [--size BYTES]
pkgstore create --package <pkg.swpkg> [--package <pkg.swpkg> ...] --output <store.img> [--generation N]
pkgstore inspect <store.img>
```

Example:

```sh
make pkgstore package-fixture
build/pkgstore init --output build/pkgstore-empty.img --size 1048576
build/pkgstore create --package build/pkghello.swpkg --output build/pkgstore-pkghello.img --generation 1
build/pkgstore inspect build/pkgstore-pkghello.img
```

Use `make package-store-test` to prove boot activation and
`make package-local-install-test` to prove target-side `pkg install FILE`.

## Signed Repository Tool

`pkgrepo` creates the signed static HTTP repository fixture consumed by
target-side `pkg update [URL]` and `pkg install NAME`.

```text
pkgrepo pubkey --seed-hex HEX --output <pubkey>
pkgrepo create --package <pkg.swpkg> [--package <pkg.swpkg> ...] --output <repo-dir> --seed-hex HEX [--generation N] [--expires UNIX] [--arch ARCH] [--target TARGET] [--abi ABI] [--linkage LINKAGE] [--sha256-override HEX]
pkgrepo verify --catalog-signed <catalog.signed> --pubkey <pubkey>
pkgrepo inspect <catalog.signed>
```

Example:

```sh
make package-repo-fixture
build/pkgrepo inspect build/pkgrepo-root/aarch64/current/catalog.signed
build/pkgrepo verify \
  --catalog-signed build/pkgrepo-root/aarch64/current/catalog.signed \
  --pubkey build/pkgrepo-root.pub
```

Negative fixtures use the same tool:

```sh
build/pkgrepo create --package build/pkghello.swpkg --output /tmp/expired \
  --seed-hex 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f \
  --expires 1
```

`make package-repo-install-test` proves expired-catalog, incompatible-catalog,
package-hash, dependency, repository configuration, and positive install paths
inside QEMU.

## Ports And Recipe Tool

`swport` currently implements the P6a catalog subcommands and the recipe
subcommands for the checked Lua, zlib, ca-certificates, and pcre2 recipes. P6e/P6f
prove the Lua cross-build and target install path. P7 adds zlib and a
multi-package seed repository fixture. P10 adds a data-only CA certificate
package to that seed: `make package-ports-seed-repo-install-test` boots SwiftOS
with a default repository URL, installs Lua, zlib, ca-certificates, and pcre2 by
package name, and runs their smoke commands. P11 adds static PCRE2 libraries
and `pcre2grep`, making nginx/lighttpd regex support a packaged dependency. P8 adds
`make ports-static-host-publish`, which turns the seed repository into a
deployable static web root, and `make package-static-host-repo-install-test`,
which installs from that web-root layout in QEMU. P9 adds
`make ports-hosted-url-verify-test` for host-side verification of a served
static root and `make package-static-host-dns-repo-install-test` for target-side
install through a DNS-resolved HTTP repository URL. Generalized `swport
build/test` commands remain planned.

```text
swport catalog validate [catalog.json]
swport catalog list [catalog.json]
swport catalog inspect <name> [catalog.json]
swport recipe validate <port|Port.json> [--catalog catalog.json]
swport recipe manifest <port|Port.json> [--output manifest.json] [--catalog catalog.json]
swport recipe fetch <port|Port.json> [--cache dir]
swport recipe package <port|Port.json> --root root-dir --output out.swpkg [--swpkg build/swpkg] [--catalog catalog.json]
swport recipe repo-fixture <port|Port.json> --root root-dir --output repo-root [--swpkg build/swpkg] [--pkgrepo build/pkgrepo] [--seed-hex hex] [--generation N]
```

Example:

```sh
make swport
build/swport catalog validate ports/catalog.json
build/swport catalog list ports/catalog.json
build/swport catalog inspect nginx ports/catalog.json
build/swport recipe validate lang/lua
build/swport recipe validate security/ca-certificates
build/swport recipe validate devel/pcre2
build/swport recipe manifest lang/lua --output build/lua-manifest.json
build/swport recipe manifest security/ca-certificates --output build/ca-certificates-manifest.json
build/swport recipe manifest devel/pcre2 --output build/pcre2-manifest.json
build/swport recipe fetch lang/lua --cache build/swport-distfiles
build/swport recipe package lang/lua --root <staged-root> --output build/lua.swpkg
build/swport recipe repo-fixture lang/lua --root <staged-root> --output build/lua-repo-root
make ports-lua-repo-fixture
make ports-zlib-repo-fixture
make ports-ca-certificates-repo-fixture
make ports-pcre2-repo-fixture
make ports-seed-repo-fixture
make ports-static-host-publish
make package-lua-repo-install-test
make package-ports-seed-repo-install-test
make package-static-host-repo-install-test
make ports-hosted-url-verify-test
make package-static-host-dns-repo-install-test
```

Expected catalog inspection output includes fields such as package name,
`portPath`, tier, status, difficulty, runtime dependencies, prerequisite
bundles, and the first smoke test. Expected recipe validation output confirms
the recipe identity and source path. `recipe manifest` emits the `.swpkg`
manifest JSON used by `build/swpkg create`; `recipe fetch` downloads the
distfile and verifies its SHA-256; `recipe package` validates a clean staged
root, calls `build/swpkg create`, and verifies the resulting package;
`recipe repo-fixture` publishes that package into a signed local `pkgrepo`
fixture and verifies the generated catalog.

Use `make ports-catalog-test` before changing `ports/catalog.json`, and
`make ports-recipe-test` before changing `ports/lang/lua/Port.json`,
`ports/archivers/zlib/Port.json`, `ports/security/ca-certificates/Port.json`,
`ports/devel/pcre2/Port.json`, or recipe handling. Use
`make ports-lua-repo-fixture`, `make ports-zlib-repo-fixture`,
`make ports-ca-certificates-repo-fixture`, `make ports-pcre2-repo-fixture`, and
`make package-ports-seed-repo-install-test` before changing the checked port
packaging path. Use `make ports-static-host-publish` and
`make package-static-host-repo-install-test` before changing the static
repository publishing path. Use `make ports-hosted-url-verify-test` and
`make package-static-host-dns-repo-install-test` before changing hosted URL or
DNS repository handling.

## Model Bundle Tools

The model tools support the AI hosting demo and verified model bundle path.
Normal users should prefer the Makefile targets, but the tools are useful when
debugging bundle generation.

```text
quantize <in-fp32.bin> <out-q8.bin>
modelmanifest <name> <generation> <model.bin> <tokenizer.bin> <out.toml>
modelsign keygen <seed-out> <pub-out>
modelsign sign <manifest.toml> <seed>
modelsign verify <manifest.toml> <pub>
```

Common targets:

```sh
make model
make base-image
./tests/llm_run_test.sh
./tests/llm_serve_test.sh
```

`modelsign sign` signs the manifest body and writes a `[signature]` table.
The trust root is staged in the base image as `/etc/swos/model-signing.pub`.

## Failure Rules

- Prefer Makefile targets for normal workflows; they build prerequisites in the
  expected order.
- Treat generated files under `build/` as disposable artifacts.
- Rebuild `build/base.img` after changing base files, model bundle inputs,
  package fixtures, or repository keys.
- Do not hand-edit `.swpkg`, `SWPKGST1`, `SWOSBASE`, or `catalog.signed`
  outputs; regenerate them from source inputs and rerun the relevant test.
