# Static Package Repository Format

SwiftOS uses a signed static HTTP repository for package distribution. The
repository is just files: a signed catalog plus content-addressed `.swpkg`
package blobs. Any ordinary static web server can host it; target-side
authenticity comes from the Ed25519 catalog signature and per-package SHA-256
hashes, not from the transport.

The current repository format is produced by `build/pkgrepo`, consumed by
`/bin/pkg update` and `/bin/pkg install NAME`, and used by the ports seed
repository fixtures for Lua, zlib, bzip2, ca-certificates, pcre2, tzdata, nginx, and sqlite.

Use this document with:

- [Package Guide](PACKAGE_GUIDE.md) for end-to-end package workflows.
- [SWPKG Package Format](SWPKG_FORMAT.md) for package blobs stored in the
  repository.
- [Package Store Format](PKGSTORE_FORMAT.md) for the writable activation store
  used after packages are downloaded.
- [Host Tool Reference](HOST_TOOL_REFERENCE.md) for `build/pkgrepo` and hosted
  URL verifier syntax.
- [Ports Seed Catalog](../ports/README.md) for recipe-driven repository
  fixtures.

## User Model

The repository has two roles:

| Role | Current Path |
| --- | --- |
| Local signed repository fixture | `build/pkgrepo-root/aarch64/current` |
| Ports seed repository fixture | `build/ports-seed-repo-root/aarch64/current` |
| Static-host publish root | `build/ports-static-host-root` |
| Guest trust root | `/etc/pkg/repo-root.pub` in the base image |
| Guest configured repository URL | `/tmp/pkg-repo-url`, falling back to `/etc/pkg/repo-url` |
| Guest cached catalog | tmpfs cache populated by `pkg update` |

The current target-side transport is HTTP. Integrity and authenticity come from
the signed catalog and package hashes. HTTPS transport, public hosted channels,
version-constraint solving, package removal, package upgrade, and package
rollback commands are future work.

## Repository Layout

A channel repository has this layout:

```text
<repo-root>/
  aarch64/current/
    catalog.json
    catalog.signed
    packages/
      <sha256>.swpkg
      <sha256>.swpkg
```

`catalog.json` is the canonical JSON body. `catalog.signed` is the same body with
a 64-byte Ed25519 signature prepended. Target-side `pkg` downloads and verifies
`catalog.signed`; `catalog.json` is useful for host inspection and debugging.

The content-addressed package filename is the SHA-256 of the full `.swpkg`
container, not only the payload image.

## Static-Host Publish Root

The ports workflow can publish a deployable static web root:

```text
build/ports-static-host-root/
  hosted-repo.json
  SHA256SUMS
  repo-root.pub
  aarch64/current/
    catalog.json
    catalog.signed
    packages/
      <sha256>.swpkg
```

Build it with:

```sh
make ports-static-host-publish
```

Serve `build/ports-static-host-root` with any static server. The guest repository
URL points at the channel directory:

```text
http://<host>/aarch64/current
```

The host-side verifier accepts either the publish root URL or the channel URL:

```sh
make ports-hosted-url-verify PKG_HOSTED_REPO_URL=http://127.0.0.1:8080
make ports-hosted-url-verify PKG_HOSTED_REPO_URL=http://127.0.0.1:8080/aarch64/current
```

`hosted-repo.json` must identify the publish root as a SwiftOS static-host
repository and point at `aarch64/current/catalog.signed`. `SHA256SUMS` covers the
catalog, public key, and package blobs so operators can validate the served root
before pointing a guest at it.

## Signed Catalog Envelope

`catalog.signed` is a detached-signature envelope:

```text
0   u8[64]  Ed25519 signature over the JSON body
64  ...     canonical compact JSON catalog
```

The public key is staged in the base image as:

```text
/etc/pkg/repo-root.pub
```

The development fixture key is deterministic and generated from
`PKGREPO_SEED_HEX` in the top-level `Makefile`. It is test/bootstrap material,
not a production signing ceremony.

Generate the public key:

```sh
make pkgrepo
build/pkgrepo pubkey \
  --seed-hex 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f \
  --output build/pkgrepo-root.pub
```

Verify a signed catalog:

```sh
build/pkgrepo verify \
  --catalog-signed build/pkgrepo-root/aarch64/current/catalog.signed \
  --pubkey build/pkgrepo-root.pub
```

Expected output:

```text
signature: OK
```

## Catalog JSON

`build/pkgrepo create` writes compact JSON with sorted keys and unescaped
slashes. The target-side parser intentionally accepts only the small canonical
subset needed for bootstrap.

Top-level fields:

| Field | Meaning | Current Value Or Rule |
| --- | --- | --- |
| `format` | Catalog format version | `1` |
| `repository` | Repository identity | `swift-os-current` |
| `channel` | Channel name | `current` |
| `generation` | Catalog generation integer | Defaults to `1`; configurable by `--generation` |
| `expires` | Unix timestamp expiration | Defaults to `4102444800`; configurable by `--expires` |
| `root_key_id` | Human-readable key identifier | `swos-test-root` |
| `packages` | Package entries | Sorted by package name |

Package entry fields:

| Field | Meaning |
| --- | --- |
| `name` | Package name |
| `version` | Package version |
| `revision` | SwiftOS package revision |
| `arch` | Target architecture, currently `aarch64` |
| `target` | Target OS, currently `swift-os` |
| `abi` | ABI family, currently `swos-0` |
| `linkage` | Linkage model, currently `static` |
| `sha256` | SHA-256 of the full `.swpkg` container |
| `size` | `.swpkg` byte size |
| `url` | Relative URL such as `packages/<sha256>.swpkg` |
| `depends` | Array of dependency objects |

Dependency objects are normalized from package manifests. They must have a
non-empty `name`; `constraint` is preserved when present but is not interpreted
by the current resolver beyond dependency-name validation and install order.

Example shape:

```json
{
  "channel": "current",
  "expires": 4102444800,
  "format": 1,
  "generation": 1,
  "packages": [
    {
      "abi": "swos-0",
      "arch": "aarch64",
      "depends": [
        {
          "constraint": ">=1.0.0",
          "name": "pkgdep"
        }
      ],
      "linkage": "static",
      "name": "pkghello",
      "revision": 1,
      "sha256": "<64 hex chars>",
      "size": 21406,
      "target": "swift-os",
      "url": "packages/<sha256>.swpkg",
      "version": "1.0.0"
    }
  ],
  "repository": "swift-os-current",
  "root_key_id": "swos-test-root"
}
```

## Host Tool

`build/pkgrepo` has four commands:

```text
pkgrepo pubkey --seed-hex HEX --output <pubkey>
pkgrepo create --package <pkg.swpkg> [--package <pkg.swpkg> ...] --output <repo-dir> --seed-hex HEX [--generation N] [--expires UNIX] [--arch ARCH] [--target TARGET] [--abi ABI] [--linkage LINKAGE] [--sha256-override HEX]
pkgrepo verify --catalog-signed <catalog.signed> --pubkey <pubkey>
pkgrepo inspect <catalog.signed>
```

Create, inspect, and verify the sample repository:

```sh
make pkgrepo package-fixture
build/pkgrepo create \
  --package build/pkghello.swpkg \
  --output build/pkgrepo-root \
  --seed-hex 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f \
  --generation 1
build/pkgrepo pubkey \
  --seed-hex 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f \
  --output build/pkgrepo-root.pub
build/pkgrepo inspect build/pkgrepo-root/aarch64/current/catalog.signed
build/pkgrepo verify \
  --catalog-signed build/pkgrepo-root/aarch64/current/catalog.signed \
  --pubkey build/pkgrepo-root.pub
```

`--expires`, `--arch`, and `--sha256-override` are used by negative tests to
produce expired, incompatible, or bad-hash repositories. They should not be used
to publish normal repositories.

## Target Flow

Configure a repository URL explicitly:

```sh
pkg repo set http://10.0.2.2:8080/aarch64/current
pkg repo show
pkg update
```

Or update from a URL directly:

```sh
pkg update http://10.0.2.2:8080/aarch64/current
```

Search, inspect, and install:

```sh
pkg search pkghello
pkg info pkghello
pkg install pkghello
pkg list
```

`pkg update [URL]` downloads `catalog.signed`, verifies the Ed25519 signature
against `/etc/pkg/repo-root.pub`, rejects expired catalogs, rejects package
entries for the wrong `arch`, `target`, `abi`, or `linkage`, validates that every
dependency names another catalog package, and caches the catalog and URL in
tmpfs.

If no URL is passed, `pkg update` uses `/tmp/pkg-repo-url`, falling back to
`/etc/pkg/repo-url` when the base image provides one. A custom base image can
bake in that default:

```sh
make BASE_IMG=build/base-hosted-url.img \
  PKG_DEFAULT_REPO_URL=http://packages.swift-os.test:8080/aarch64/current \
  PKG_DEFAULT_DNS_SERVER=10.0.2.3 \
  base-image
```

`pkg install NAME` loads the verified cached catalog, resolves dependencies by
package name, downloads each content-addressed `.swpkg`, verifies SHA-256, and
then reuses the local install path into the writable package-store image.

Repository URLs currently use `http://`. The host can be an IPv4 literal or a
DNS hostname. Hostname resolution uses the kernel resolver; when a deployment or
QEMU test needs an explicit DNS server, place `IP[:port]` in
`/etc/pkg/dns-server` through `PKG_DEFAULT_DNS_SERVER`.

## Verification Matrix

| Concern | Command |
| --- | --- |
| Host tool build | `make pkgrepo` |
| Signed catalog creation, inspection, verification, negative fixtures, tamper rejection | `build/pkgrepo_tool_test` after compiling `tests/pkgrepo_tool_test.swift` |
| Sample repository fixture | `make package-repo-fixture` |
| Target-side repository install by name, dependency resolution, expired/wrong-arch/bad-hash rejection | `make package-repo-install-test` |
| Ports static-host publish root | `make ports-static-host-publish` |
| Host-side hosted URL verification | `make ports-hosted-url-verify-test` |
| Target-side static-host repository install | `make package-static-host-repo-install-test` |
| Target-side DNS-resolved hosted-style repository install | `make package-static-host-dns-repo-install-test` |
| Documentation and link coverage | `make docs-test` |

For a narrow repository-format documentation change, run:

```sh
make pkgrepo package-fixture package-repo-fixture
/usr/bin/swiftc tests/pkgrepo_tool_test.swift -o build/pkgrepo_tool_test
build/pkgrepo_tool_test
make docs-test
```

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `pkgrepo: at least one --package is required` | Repository creation was called without packages | Pass one or more `--package` arguments |
| `pkgrepo: package signatures are reserved` | Input `.swpkg` has non-zero reserved signature fields | Recreate an unsigned v1 `.swpkg`; publisher authenticity comes from the catalog signature |
| `signature: INVALID` | Catalog bytes, signature, or public key do not match | Rebuild the repository and use the matching `repo-root.pub` |
| `pkg update` rejects the catalog as expired | `expires` is in the past | Publish a catalog with a future expiration |
| `pkg update` rejects package metadata | Catalog entry has wrong architecture, target, ABI, or linkage | Rebuild with the default `aarch64`, `swift-os`, `swos-0`, `static` values |
| `pkg update` reports missing dependency | A dependency names a package not present in the same catalog | Publish all dependency packages in the same repository generation |
| `pkg install NAME` reports a package SHA-256 mismatch | Package blob does not match the catalog hash | Rebuild or republish the repository root |
| `pkg update` cannot resolve a hostname | Guest DNS was not configured for that test | Bake `/etc/pkg/dns-server` with `PKG_DEFAULT_DNS_SERVER` or use an IPv4 URL |
| Static-host verifier fails on `SHA256SUMS` | Served files changed after publishing | Rerun `make ports-static-host-publish` and redeploy the whole root |

## Security Notes

- HTTP transport is currently allowed because catalog signatures and package
  hashes provide integrity. HTTPS transport is still future work.
- The repository public key in the base image is the trust anchor for repository
  metadata. Production use needs controlled release keys and rotation policy.
- `.swpkg` package-level signature fields remain reserved. Do not rely on
  package blobs alone for publisher identity.
- The catalog signature covers package metadata and hashes. Package blobs are
  verified against catalog SHA-256 before installation.
- Catalog expiration is enforced, but monotonic generation rollback protection
  and public channel policy are not implemented yet.

## Source Of Truth

The implementation and tests that define this document are:

- `tools/pkgrepo.swift` for repository creation, signature verification, and
  inspection.
- `userland/pkg.swift` for target-side repository configuration, update,
  search, info, dependency install, and package hash verification.
- `Makefile` targets `package-repo-fixture`, `ports-static-host-publish`, and
  hosted URL tests.
- `scripts/verify-ports-hosted-url.sh` for host-side static-host validation.
- `tests/pkgrepo_tool_test.swift` for host tool coverage.
- `tests/pkg_repo_install_test.sh` for target-side repository install and
  negative repository rejection.
- `tests/pkg_hosted_url_verify_test.sh`,
  `tests/pkg_static_host_repo_install_test.sh`, and
  `tests/pkg_static_host_dns_repo_install_test.sh` for hosted/static-root paths.
