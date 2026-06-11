# SwiftOS Host Tool Reference

This reference describes the host-side tools that build SwiftOS images,
packages, repositories, model bundles, and the checked ports seed catalog,
recipes, and repository-publish artifacts. These commands run on the development
host, not inside the SwiftOS guest.

For guest commands, use [COMMAND_REFERENCE.md](COMMAND_REFERENCE.md). For the
end-to-end package workflow, use
[PACKAGE_BUILD_AUTOMATION.md](PACKAGE_BUILD_AUTOMATION.md).

## Choose A Host Workflow

Start from the artifact you need to produce or inspect. Prefer the Makefile
target for normal use; call the underlying tool directly when debugging a
format, manifest, signature, or fixture.

| Task | Preferred target | Underlying tool or script | Proof |
| --- | --- | --- | --- |
| Repack the immutable base image | `make base-image` | `build/basepack` | `./tests/boot_test.sh`, `./tests/vfs_disk_test.sh` |
| Build direct boot artifacts | `make build base-image build/virt.dtb` | Makefile, Swift compiler, linker | `./tests/boot_test.sh` |
| Build the UEFI disk image | `make disk base-image` | `build/BOOTAA64.EFI`, `build/kernelboot` | `UEFI_BOOT=disk ./tests/uefi_boot_test.sh` |
| Generate or derive SwiftOS SSHD seed material | `make sshkey` | `build/sshkey` | `make sshd-transport-test`, `make sshd-host-key-rotation-test`, `make sshd-kex-seed-test` |
| Create or inspect a `.swpkg` | `make package-fixture` | `build/swpkg` | `build/swpkg verify ...`, `make package-overlay-test` |
| Build a package-store image | `make package-store-fixture` | `build/pkgstore` | `make package-store-test` |
| Publish a signed repository fixture | `make package-repo-fixture` | `build/pkgrepo` | `make package-repo-install-test` |
| Validate or package a source port | Port-specific `make ports-*-repo-fixture` target | `build/swport`, `scripts/build-*.sh` | Port fixture target plus seed repository install test |
| Publish the static-host seed repository | `make ports-static-host-publish` | `scripts/publish-ports-static-host.sh` | `make package-static-host-repo-install-test` |
| Verify a hosted repository URL | `make ports-hosted-url-verify-test` | `scripts/verify-ports-hosted-url.sh` | Host URL verification plus DNS repository install test |
| Build AI model artifacts | `make model`, then `make base-image` | `build/quantize`, `build/modelmanifest`, `build/modelsign` | `./tests/llm_run_test.sh`, `./tests/llm_serve_test.sh` |

## Quick Map

| Tool or target | Build target | Purpose | Verification |
| --- | --- | --- | --- |
| `build/basepack` | `make base-image` | Pack a directory into a `SWOSBASE` read-only base image. | `./tests/boot_test.sh` |
| `build/updatestore` | `make updatestore` | Build an A/B `SWOSBOOT` update-store disk from two signed base images. | `tests/updatestore_test.swift`, `tests/ab_update_test.sh` |
| `build/kernelboot` | `make kernelboot` | Build the signed UEFI kernel A/B boot manifest consumed from the ESP. | `tests/uefi_kernel_ab_test.sh` |
| `build/sshkey` | `make sshkey` | Generate SwiftOS SSHD seed files and derive OpenSSH `ssh-ed25519` public keys and known_hosts lines from host-key seeds. | `make sshd-transport-test`, `make sshd-host-key-rotation-test`, `make sshd-kex-seed-test` |
| `build/swpkg` | `make swpkg` | Create, inspect, verify, and extract `.swpkg` package artifacts. | `tests/swpkg_tool_test.swift`, `make package-fixture` |
| `build/pkgstore` | `make pkgstore` | Create and inspect package-store disk images. | `tests/pkgstore_tool_test.swift`, `make package-store-test` |
| `build/pkgrepo` | `make pkgrepo` | Create and verify signed static HTTP package repositories. | `tests/pkgrepo_tool_test.swift`, `make package-repo-install-test` |
| `build/swport` | `make swport` | Validate/list/inspect the ports catalog, emit the catalog-driven packaged seed list, validate/fetch/manifest/package/repo-fixture the checked Lua, zlib, bzip2, zstd, xz, libarchive, ca-certificates, OpenSSL, pcre2, tzdata, nginx, and `databases/sqlite` recipes, and validate/manifest the `ports/lang/nodejs/Port.json`, `ports/lang/npm/Port.json`, and `ports/sysutils/pm2/Port.json` intake scaffolds. | `make ports-catalog-test`, `make ports-recipe-test` |
| `scripts/build-lua.sh` | `make ports-lua-repo-fixture` | Cross-build static AArch64 `lua`/`luac`, package them, and publish a signed local repository fixture. | `make ports-lua-repo-fixture`, `make package-lua-repo-install-test` |
| `scripts/build-zlib.sh` | `make ports-zlib-repo-fixture` | Cross-build static zlib, headers, pkgconf metadata, and `minigzip`, then publish a signed local repository fixture. | `make ports-zlib-repo-fixture` |
| `scripts/build-bzip2.sh` | `make ports-bzip2-repo-fixture` | Cross-build static bzip2 CLI tools, `libbz2.a`, header, and pkgconf metadata, then publish a signed local repository fixture. | `make ports-bzip2-repo-fixture` |
| `scripts/build-zstd.sh` | `make ports-zstd-repo-fixture` | Cross-build single-threaded static zstd CLI tools, `libzstd.a`, headers, and pkgconf metadata, then publish a signed local repository fixture. | `make ports-zstd-repo-fixture` |
| `scripts/build-xz.sh` | `make ports-xz-repo-fixture` | Cross-build static xz CLI tools, `liblzma.a`, headers, and pkgconf metadata, then publish a signed local repository fixture. | `make ports-xz-repo-fixture` |
| `scripts/build-libarchive.sh` | `make ports-libarchive-repo-fixture` | Cross-build static `bsdtar`, `libarchive.a`, headers, and pkgconf metadata against the packaged compression libraries, then publish a signed local repository fixture. | `make ports-libarchive-repo-fixture` |
| `scripts/build-ca-certificates.sh` | `make ports-ca-certificates-repo-fixture` | Package the pinned Mozilla CA bundle and publish a signed local repository fixture. | `make ports-ca-certificates-repo-fixture` |
| `scripts/build-openssl.sh` | `make ports-openssl-repo-fixture` | Cross-build the static OpenSSL CLI and version marker, then publish a signed local repository fixture. | `make ports-openssl-repo-fixture` |
| `scripts/build-pcre2.sh` | `make ports-pcre2-repo-fixture` | Cross-build static PCRE2 libraries, headers, pkgconf metadata, and `pcre2grep`, then publish a signed local repository fixture. | `make ports-pcre2-repo-fixture` |
| `scripts/build-tzdata.sh` | `make ports-tzdata-repo-fixture` | Compile IANA time zone data with host `zic`, package `/usr/share/zoneinfo`, and publish a signed local repository fixture. | `make ports-tzdata-repo-fixture` |
| `scripts/build-nginx.sh` | `make ports-nginx-repo-fixture` | Cross-build minimal static HTTP-only nginx, package it, and publish a signed local repository fixture. | `make ports-nginx-repo-fixture` |
| `scripts/build-sqlite.sh` | `make ports-sqlite-repo-fixture` | Cross-build static SQLite, package `sqlite3`, `libsqlite3.a`, headers, and pkgconf metadata, then publish a signed local repository fixture. | `make ports-sqlite-repo-fixture` |
| `scripts/build-ports-seed-repo.sh` | `make ports-seed-repo-fixture` | Publish every catalog entry with `status: "packages"` into one signed local seed repository. | `make package-ports-seed-repo-install-test` |
| `scripts/publish-ports-static-host.sh` | `make ports-static-host-publish` | Create a deployable static web root for the ports seed repository with manifest and checksums. | `make ports-static-host-publish`, `make package-static-host-repo-install-test` |
| `scripts/verify-ports-hosted-url.sh` | `make ports-hosted-url-verify` | Fetch and verify a deployed static-host package repository URL, including sidecar manifest, checksums, package blobs, and signed catalog. | `make ports-hosted-url-verify-test` |
| `build/modelmanifest` | `make base-image` | Generate verified model bundle manifests. | `./tests/llm_serve_test.sh` |
| `build/modelsign` | `make base-image` | Generate model signing keys and sign/verify manifests. | `./tests/llm_serve_test.sh` |
| `build/quantize` | `make model` | Quantize TinyStories checkpoints for AI inference. | `./tests/llm_run_test.sh` |

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

## SSH Host Key Helper

`sshkey` generates hex-encoded SSHD seed files and derives OpenSSH host-key
material from the same seed format loaded by `/bin/sshd`.

```text
sshkey seed --out PATH [--force]
sshkey pubkey --seed-file PATH [--comment TEXT]
sshkey pubkey --seed-hex HEX [--comment TEXT]
sshkey known-host --host HOST --seed-file PATH [--comment TEXT]
sshkey known-host --host HOST --seed-hex HEX [--comment TEXT]
```

Example:

```sh
make sshkey
build/sshkey seed --out support/keys/ssh_host_ed25519_seed
build/sshkey seed --out support/keys/ssh_kex_seed
make SSHD_HOST_SEED_FILE=support/keys/ssh_host_ed25519_seed \
  SSHD_KEX_SEED_FILE=support/keys/ssh_kex_seed \
  base-image
build/sshkey known-host \
  --host '[127.0.0.1]:2222' \
  --seed-file support/keys/ssh_host_ed25519_seed
```

`make sshd-transport-test` uses this tool to prove host OpenSSH can pin the
SwiftOS SSHD host key with `StrictHostKeyChecking=yes`. `make
sshd-host-key-rotation-test` builds a temporary base image with a generated seed
and proves the rotated key is what host OpenSSH pins. `make
sshd-kex-seed-test` uses the same seed generator for `/etc/ssh/ssh_kex_seed`;
that seed is mixed into the SSHD KEX pseudo-random context, but runtime entropy
remains separate work.

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

`swport` implements the checked ports catalog and recipe subcommands for the
current twelve-package seed: Lua, zlib, bzip2, zstd, xz, libarchive, ca-certificates, OpenSSL, pcre2,
tzdata, nginx, and sqlite. It also validates the blocked Node.js/npm/PM2 intake
recipes at `ports/lang/nodejs/Port.json`, `ports/lang/npm/Port.json`, and
`ports/sysutils/pm2/Port.json`.
The tool validates catalog metadata, emits the `status: "packages"` seed list,
validates recipes, emits `.swpkg`
manifests, verifies source checksums, packages clean staged roots, and publishes
signed local repository fixtures through `swpkg` and `pkgrepo`. The Makefile
targets cross-build or package the checked seed artifacts, publish them into one
signed repository, turn that repository into a static-hostable web root, verify
served hosted URLs, and prove target-side installs from local, hosted, and
DNS-resolved repository URLs. Generalized `swport build` and `swport test`
commands remain planned; today those orchestration steps live in the
package-specific scripts and Makefile targets.

```text
swport catalog validate [catalog.json]
swport catalog list [catalog.json]
swport catalog inspect <name> [catalog.json]
swport catalog packaged [catalog.json]
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
build/swport recipe validate archivers/zlib
build/swport recipe validate archivers/bzip2
build/swport recipe validate archivers/zstd
build/swport recipe validate archivers/xz
build/swport recipe validate archivers/libarchive
build/swport recipe validate security/ca-certificates
build/swport recipe validate devel/pcre2
build/swport recipe validate sysutils/tzdata
build/swport recipe validate www/nginx
build/swport recipe validate databases/sqlite
build/swport recipe validate lang/nodejs
build/swport recipe validate lang/npm
build/swport recipe validate sysutils/pm2
build/swport recipe manifest lang/lua --output build/lua-manifest.json
build/swport recipe manifest archivers/zlib --output build/zlib-manifest.json
build/swport recipe manifest archivers/bzip2 --output build/bzip2-manifest.json
build/swport recipe manifest archivers/zstd --output build/zstd-manifest.json
build/swport recipe manifest archivers/xz --output build/xz-manifest.json
build/swport recipe manifest archivers/libarchive --output build/libarchive-manifest.json
build/swport recipe manifest security/ca-certificates --output build/ca-certificates-manifest.json
build/swport recipe manifest devel/pcre2 --output build/pcre2-manifest.json
build/swport recipe manifest sysutils/tzdata --output build/tzdata-manifest.json
build/swport recipe manifest www/nginx --output build/nginx-manifest.json
build/swport recipe manifest databases/sqlite --output build/sqlite-manifest.json
build/swport recipe manifest lang/nodejs --output build/nodejs-manifest.json
build/swport recipe manifest lang/npm --output build/npm-manifest.json
build/swport recipe manifest sysutils/pm2 --output build/pm2-manifest.json
build/swport recipe fetch lang/lua --cache build/swport-distfiles
build/swport recipe package lang/lua --root <staged-root> --output build/lua.swpkg
build/swport recipe repo-fixture lang/lua --root <staged-root> --output build/lua-repo-root
make ports-lua-repo-fixture
make ports-zlib-repo-fixture
make ports-bzip2-repo-fixture
make ports-zstd-repo-fixture
make ports-xz-repo-fixture
make ports-libarchive-repo-fixture
make ports-ca-certificates-repo-fixture
make ports-pcre2-repo-fixture
make ports-tzdata-repo-fixture
make ports-nginx-repo-fixture
make ports-sqlite-repo-fixture
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
`ports/archivers/zlib/Port.json`, `ports/archivers/bzip2/Port.json`,
`ports/archivers/zstd/Port.json`, `ports/archivers/xz/Port.json`,
`ports/archivers/libarchive/Port.json`, `ports/security/ca-certificates/Port.json`,
`ports/security/openssl/Port.json`, `ports/devel/pcre2/Port.json`, `ports/sysutils/tzdata/Port.json`,
`ports/www/nginx/Port.json`, `ports/databases/sqlite/Port.json`,
`ports/lang/nodejs/Port.json`, `ports/lang/npm/Port.json`,
`ports/sysutils/pm2/Port.json`, or recipe handling. Use the package-specific fixture targets (`make ports-lua-repo-fixture`,
`make ports-zlib-repo-fixture`, `make ports-bzip2-repo-fixture`,
`make ports-zstd-repo-fixture`, `make ports-xz-repo-fixture`,
`make ports-libarchive-repo-fixture`, `make ports-ca-certificates-repo-fixture`,
`make ports-openssl-repo-fixture`, `make ports-pcre2-repo-fixture`, `make ports-tzdata-repo-fixture`,
`make ports-nginx-repo-fixture`, and `make ports-sqlite-repo-fixture`) plus
`make package-ports-seed-repo-install-test` before changing the checked port
packaging path. Use `make ports-static-host-publish` and
`make package-static-host-repo-install-test` before changing the static
repository publishing path. Use `make ports-hosted-url-verify-test` and
`make package-static-host-dns-repo-install-test` before changing hosted URL or
DNS repository handling.

## Model Bundle Tools

The model tools support the AI hosting workflow and verified model bundle path.
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
