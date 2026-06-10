# SwiftOS Ports Seed Catalog

`ports/` is the checked seed for the future `swift-os-ports` repository. It is
small on purpose: the catalog records the first server-package priorities,
dependency names, OS prerequisite bundles, blockers, and smoke tests, while the
checked recipes prove the package format and repository flow against real
artifacts.

This is not a full ports tree yet. The checked-in recipes are `lang/lua`,
`archivers/zlib`, `archivers/bzip2`, `security/ca-certificates`, `devel/pcre2`,
`sysutils/tzdata`, `www/nginx`, and `databases/sqlite`, with validation,
manifest generation, checksum-verified distfile fetching, `.swpkg` creation
from clean staged roots, and signed static repository fixture generation.
`make ports-lua-repo-fixture` cross-builds real AArch64 static Lua against the
local newlib sysroot and packages the runtime interpreter.
`make ports-zlib-repo-fixture` cross-builds static zlib, headers, pkgconf
metadata, and the small `minigzip` smoke-test helper.
`make ports-bzip2-repo-fixture` cross-builds static bzip2, bunzip2, bzcat,
bzip2recover, libbz2, headers, and pkgconf metadata.
`make ports-ca-certificates-repo-fixture` packages the pinned Mozilla CA bundle
as a data-only trust-store package. `make ports-pcre2-repo-fixture`
cross-builds static PCRE2 libraries, headers, pkgconf metadata, and
`pcre2grep`. `make ports-tzdata-repo-fixture` compiles portable IANA TZif
zoneinfo files and packages the `/usr/share/zoneinfo` tree.
`make ports-nginx-repo-fixture` cross-builds a minimal static HTTP-only nginx
package. `make ports-sqlite-repo-fixture` cross-builds static SQLite,
`libsqlite3.a`, headers, pkgconf metadata, and the `sqlite3` CLI.
`make ports-seed-repo-fixture` publishes all eight packages into one signed
seed repository. `make ports-static-host-publish` copies that seed repository
into a deployable static-host web root with `hosted-repo.json`,
`repo-root.pub`, and `SHA256SUMS`.
Patches, QEMU smoke tests, and trusted public publishing workflows still belong
to the planned `swift-os-ports` repository. The seed catalog keeps that work
ordered and reviewable while the target-side package manager is still being
hardened inside `swift-os`.

## Checked Seed Packages

| Package | Path | Current result |
| --- | --- | --- |
| Lua | `ports/lang/lua/Port.json` | Static AArch64 `lua` runtime package and signed repository fixture |
| zlib | `ports/archivers/zlib/Port.json` | Static `libz.a`, headers, pkgconf metadata, and `minigzip` |
| bzip2 | `ports/archivers/bzip2/Port.json` | Static bzip2 CLI tools, `libbz2.a`, header, and pkgconf metadata |
| ca-certificates | `ports/security/ca-certificates/Port.json` | Data-only Mozilla CA bundle under packaged `/usr` paths |
| PCRE2 | `ports/devel/pcre2/Port.json` | Static PCRE2 libraries, headers, pkgconf metadata, and `pcre2grep` |
| tzdata | `ports/sysutils/tzdata/Port.json` | IANA TZif zoneinfo tree compiled with host `zic` |
| nginx | `ports/www/nginx/Port.json` | Minimal static HTTP-only nginx package |
| SQLite | `ports/databases/sqlite/Port.json` | Static SQLite CLI, library, headers, and pkgconf metadata |

`make ports-seed-repo-fixture` publishes all eight packages into one signed local
repository. `make ports-static-host-publish` turns that seed into a deployable
static-host web root containing `hosted-repo.json`, `repo-root.pub`, and
`SHA256SUMS`.

## Common Checks

```sh
make ports-catalog-test
make ports-recipe-test
make ports-lua-repo-fixture
make ports-zlib-repo-fixture
make ports-bzip2-repo-fixture
make ports-ca-certificates-repo-fixture
make ports-pcre2-repo-fixture
make ports-tzdata-repo-fixture
make ports-nginx-repo-fixture
make ports-sqlite-repo-fixture
make ports-seed-repo-fixture
make ports-static-host-publish
make ports-hosted-url-verify-test
build/swport recipe validate sysutils/tzdata
build/swport recipe validate www/nginx
build/swport recipe validate archivers/bzip2
build/swport recipe validate databases/sqlite
build/swport recipe manifest lang/lua --output build/lua-manifest.json
build/swport recipe manifest archivers/zlib --output build/zlib-manifest.json
build/swport recipe manifest archivers/bzip2 --output build/bzip2-manifest.json
build/swport recipe manifest security/ca-certificates --output build/ca-certificates-manifest.json
build/swport recipe manifest devel/pcre2 --output build/pcre2-manifest.json
build/swport recipe manifest sysutils/tzdata --output build/tzdata-manifest.json
build/swport recipe manifest www/nginx --output build/nginx-manifest.json
build/swport recipe manifest databases/sqlite --output build/sqlite-manifest.json
build/swport recipe fetch lang/lua --cache build/swport-distfiles
build/swport recipe package lang/lua --root <staged-root> --output build/lua.swpkg
build/swport recipe repo-fixture lang/lua --root <staged-root> --output build/lua-repo-root
```

The Lua, zlib, bzip2, pcre2, nginx, and sqlite cross-build targets require
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
