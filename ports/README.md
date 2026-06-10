# SwiftOS Ports Seed Catalog

`ports/catalog.json` is the P6a seed for the future `swift-os-ports`
repository. It is intentionally small and machine-readable: it records the
first package priorities, dependency names, OS prerequisite bundles, blocked
state, and the first smoke test each package must eventually pass.

This is not a full ports tree yet. The first checked-in recipes are `lang/lua`,
`archivers/zlib`, `security/ca-certificates`, `devel/pcre2`, and
`sysutils/tzdata`, with
validation, manifest generation, checksum-verified distfile fetching, `.swpkg`
creation from clean staged roots, and signed static repository fixture
generation. `make
ports-lua-repo-fixture` cross-builds real AArch64 static Lua against the local
newlib sysroot and packages the runtime interpreter. `make
ports-zlib-repo-fixture` cross-builds static zlib, headers, pkgconf metadata,
and the small `minigzip` smoke-test helper. `make
ports-ca-certificates-repo-fixture` packages the pinned Mozilla CA bundle as a
data-only trust-store package. `make ports-pcre2-repo-fixture` cross-builds
static PCRE2 libraries, headers, pkgconf metadata, and `pcre2grep`. `make
ports-tzdata-repo-fixture` compiles portable IANA TZif zoneinfo files and
packages the `/usr/share/zoneinfo` tree. `make ports-seed-repo-fixture`
publishes all five packages into one signed seed
repository. `make ports-static-host-publish`
copies that seed repository into a deployable static-host web root with
`hosted-repo.json`, `repo-root.pub`, and `SHA256SUMS`.
Patches, QEMU smoke tests, and trusted public publishing workflows still belong
to the planned `swift-os-ports` repository. The seed catalog keeps that work
ordered and reviewable while the target-side package manager is still being
hardened inside `swift-os`.

Validate the catalog:

```sh
make ports-catalog-test
make ports-recipe-test
make ports-lua-repo-fixture
make ports-zlib-repo-fixture
make ports-ca-certificates-repo-fixture
make ports-pcre2-repo-fixture
make ports-tzdata-repo-fixture
make ports-seed-repo-fixture
make ports-static-host-publish
make package-ports-seed-repo-install-test
make package-static-host-repo-install-test
```

Useful inspection commands:

```sh
make swport
build/swport catalog list ports/catalog.json
build/swport catalog inspect nginx ports/catalog.json
build/swport catalog inspect nodejs ports/catalog.json
build/swport recipe validate lang/lua
build/swport recipe validate archivers/zlib
build/swport recipe validate security/ca-certificates
build/swport recipe validate devel/pcre2
build/swport recipe validate sysutils/tzdata
build/swport recipe manifest lang/lua --output build/lua-manifest.json
build/swport recipe manifest archivers/zlib --output build/zlib-manifest.json
build/swport recipe manifest security/ca-certificates --output build/ca-certificates-manifest.json
build/swport recipe manifest devel/pcre2 --output build/pcre2-manifest.json
build/swport recipe fetch lang/lua --cache build/swport-distfiles
build/swport recipe package lang/lua --root <staged-root> --output build/lua.swpkg
build/swport recipe repo-fixture lang/lua --root <staged-root> --output build/lua-repo-root
```

The Lua, zlib, and pcre2 cross-build targets require
`sysroot/aarch64-elf/lib/libc.a`; create it with `make newlib` if the generated
sysroot is not present.

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
