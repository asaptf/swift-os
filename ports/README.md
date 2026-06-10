# SwiftOS Ports Seed Catalog

`ports/` is the checked seed for the future `swift-os-ports` repository. It is
small on purpose: the catalog records the first server-package priorities,
dependency names, OS prerequisite bundles, blockers, and smoke tests, while the
checked recipes prove the package format and repository flow against real
artifacts.

This is not a full ports tree. It is the contract that lets SwiftOS harden the
target-side package manager before broad public package publishing exists.

## Checked Seed Packages

| Package | Path | Current result |
| --- | --- | --- |
| Lua | `ports/lang/lua/Port.json` | Static AArch64 `lua` runtime package and signed repository fixture |
| zlib | `ports/archivers/zlib/Port.json` | Static `libz.a`, headers, pkgconf metadata, and `minigzip` |
| ca-certificates | `ports/security/ca-certificates/Port.json` | Data-only Mozilla CA bundle under packaged `/usr` paths |
| PCRE2 | `ports/devel/pcre2/Port.json` | Static PCRE2 libraries, headers, pkgconf metadata, and `pcre2grep` |
| tzdata | `ports/sysutils/tzdata/Port.json` | IANA TZif zoneinfo tree compiled with host `zic` |
| nginx | `ports/www/nginx/Port.json` | Minimal static HTTP-only nginx package |

`make ports-seed-repo-fixture` publishes all six packages into one signed local
repository. `make ports-static-host-publish` turns that seed into a deployable
static-host web root containing `hosted-repo.json`, `repo-root.pub`, and
`SHA256SUMS`.

## Common Checks

```sh
make ports-catalog-test
make ports-recipe-test
make ports-lua-repo-fixture
make ports-zlib-repo-fixture
make ports-ca-certificates-repo-fixture
make ports-pcre2-repo-fixture
make ports-tzdata-repo-fixture
make ports-nginx-repo-fixture
make ports-seed-repo-fixture
make ports-static-host-publish
make ports-hosted-url-verify-test
build/swport recipe validate sysutils/tzdata
build/swport recipe validate www/nginx
build/swport recipe manifest lang/lua --output build/lua-manifest.json
build/swport recipe manifest archivers/zlib --output build/zlib-manifest.json
build/swport recipe manifest security/ca-certificates --output build/ca-certificates-manifest.json
build/swport recipe manifest devel/pcre2 --output build/pcre2-manifest.json
build/swport recipe manifest sysutils/tzdata --output build/tzdata-manifest.json
build/swport recipe manifest www/nginx --output build/nginx-manifest.json
build/swport recipe fetch lang/lua --cache build/swport-distfiles
build/swport recipe package lang/lua --root <staged-root> --output build/lua.swpkg
build/swport recipe repo-fixture lang/lua --root <staged-root> --output build/lua-repo-root
```

The Lua, zlib, pcre2, and nginx cross-build targets require
`sysroot/aarch64-elf/lib/libc.a`; create it with `make newlib` if the generated
sysroot is not present.

## Catalog Rules

Catalog rules enforced by `swport catalog validate`:

- target must be `aarch64` / `swift-os` / `swos-0` / `static`;
- package names and `portPath` values must be unique;
- `status` must be `candidate`, `planned`, `blocked`, or `packages`;
- `difficulty` must be `S`, `M`, `L`, or `XL`;
- runtime dependencies must name another catalog package;
- prerequisite bundles must be declared by the catalog;
- blocked packages must list concrete `blockedBy` reasons.

Recipe rules enforced by `swport recipe validate`:

- package names must match package-manager naming rules;
- recipe dependencies must exist in `ports/catalog.json`;
- source checksums must be 64 lowercase SHA-256 hex characters;
- targets must be `aarch64` / `swift-os` / `swos-0` / `static`;
- staged package files must install under `/usr`;
- file modes must be four octal digits;
- duplicate staged package targets are rejected.

`swport recipe package` additionally rejects staged roots with missing,
undeclared, or mode-mismatched files before it calls `swpkg create` and
`swpkg verify`.

`swport recipe repo-fixture` builds on that same package path, creates a signed
static repository with `pkgrepo`, writes a public key next to the repository
root by default, and verifies the signed catalog.

## Current Limits

- Public production package channels are not published yet.
- Target-side HTTPS repository transport is still roadmap work.
- Generalized `swport build` and `swport test` commands are planned; current
  orchestration lives in package-specific scripts and Makefile targets.
- Broad upstream patch management and package maintainer workflows belong in the
  future external `swift-os-ports` repository.
