# SwiftOS Static Package Repository

P5c provides the first network repository format for `pkg`: a signed, static HTTP
layout that can be served by any ordinary web server.

## Layout

```text
<repo-root>/
  aarch64/current/
    catalog.json
    catalog.signed
    packages/
      <sha256>.swpkg
```

For tests, `make package-repo-fixture` builds this layout under
`build/pkgrepo-root`.

The ports bootstrap path can also publish a deployable static web root:

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

Build it with `make ports-static-host-publish`. Serve that directory with
nginx, object storage, GitHub Pages, or a local `python3 -m http.server`; the
guest repository URL is `http://<host>/aarch64/current`.

## Signed Catalog

`catalog.signed` is a detached-signature envelope:

```text
bytes 0..63      Ed25519 signature over the JSON bytes
bytes 64..end    canonical compact JSON catalog
```

The root public key is shipped in the base image at:

```text
/etc/pkg/repo-root.pub
```

The current development key is deterministic and produced by `tools/pkgrepo.swift`
from `PKGREPO_SEED_HEX` in the top-level `Makefile`. This is test/bootstrap
material, not a production signing ceremony.

## Catalog JSON

The host tool writes compact JSON with sorted keys and unescaped slashes. The
target-side parser intentionally accepts only the small canonical subset needed
for bootstrap.

Example:

```json
{"channel":"current","expires":4102444800,"format":1,"generation":1,"packages":[{"abi":"swos-0","arch":"aarch64","depends":[{"constraint":">=1.0.0","name":"pkgdep"}],"linkage":"static","name":"pkghello","revision":1,"sha256":"...","size":21406,"target":"swift-os","url":"packages/<sha256>.swpkg","version":"1.0.0"}],"repository":"swift-os-current","root_key_id":"swos-test-root"}
```

Each package entry currently carries:

- `name`
- `version`
- `revision`
- `arch`
- `target`
- `abi`
- `linkage`
- `sha256`
- `size`
- `url`
- `depends`

## Target Commands

The P5c target-side flow supports either an explicit URL or a configured
repository URL:

```sh
pkg repo set http://10.0.2.2:<port>/aarch64/current
pkg update
pkg repo show
pkg update http://10.0.2.2:<port>/aarch64/current
pkg repo set http://pkg.test.swos:<port>/aarch64/current
pkg search pkghello
pkg info pkghello
pkg install pkghello
```

`pkg repo set URL` writes the active repository URL to `/tmp/pkg-repo-url`.
`pkg repo show` prints the configured URL. `pkg update [URL]` downloads
`catalog.signed`, verifies the Ed25519 signature against `/etc/pkg/repo-root.pub`,
rejects expired catalogs, rejects package entries for the wrong
`arch`/`target`/`abi`/`linkage`, validates that every dependency names another
catalog package, then caches the catalog and URL in `/tmp`. If no URL is passed,
`pkg update` uses `/tmp/pkg-repo-url`, falling back to `/etc/pkg/repo-url` when a
base image or deployment provides one.

Repository URLs currently use `http://`. The host part can be a numeric IPv4
address or a DNS hostname. Hostname resolution uses the kernel resolver; when a
deployment or QEMU test needs an explicit DNS server, place `IP[:port]` in
`/etc/pkg/dns-server` through the base-image `PKG_DEFAULT_DNS_SERVER` make
variable. Target-side HTTPS transport is future work; repository authenticity
comes from signed catalogs and content hashes.

`pkg install NAME` loads the verified cached catalog, resolves dependencies by
name, downloads each content-addressed `.swpkg` listed by `url`, verifies
SHA-256, then reuses the local `pkg install FILE` path. The package store
activation keeps prior active payloads mounted while adding the new payload, so
dependency packages remain visible after the dependent package is installed.

## Host Tool

```sh
make pkgrepo
build/pkgrepo pubkey --seed-hex <hex32> --output build/pkgrepo-root.pub
build/pkgrepo create --package build/pkghello.swpkg --output build/pkgrepo-root --seed-hex <hex32>
build/pkgrepo create --package build/pkghello.swpkg --output /tmp/expired --seed-hex <hex32> --expires 1
build/pkgrepo create --package build/pkghello.swpkg --output /tmp/wrongarch --seed-hex <hex32> --arch riscv64
build/pkgrepo create --package build/pkghello.swpkg --output /tmp/badhash --seed-hex <hex32> --sha256-override 0000000000000000000000000000000000000000000000000000000000000000
build/pkgrepo verify --catalog-signed build/pkgrepo-root/aarch64/current/catalog.signed --pubkey build/pkgrepo-root.pub
build/pkgrepo inspect build/pkgrepo-root/aarch64/current/catalog.signed
```

## Tests

- `tests/pkgrepo_tool_test.swift` verifies creation, inspection, valid signature
  verification, negative fixture generation, and tamper rejection.
- `tests/pkg_repo_install_test.sh` starts a host HTTP server, boots QEMU with
  user networking, proves expired/wrong-arch/bad-hash repos are rejected,
  configures a default repo URL, proves dependency resolution with
  `pkgdep -> pkghello`, then executes `/usr/bin/pkghello`.
- `tests/pkg_static_host_repo_install_test.sh` serves
  `build/ports-static-host-root`, verifies the hosted sidecar manifest and
  checksums, then boots QEMU and installs Lua and zlib from `/aarch64/current`.
- `tests/pkg_hosted_url_verify_test.sh` serves `build/ports-static-host-root`
  and proves the host-side hosted URL verifier fetches and verifies the served
  root.
- `tests/pkg_static_host_dns_repo_install_test.sh` serves the same root through
  a hostname URL, answers DNS inside the QEMU user-networking path, and proves
  `/bin/pkg` installs Lua and zlib from that DNS-resolved repository URL.

## Known Limits

- HTTP is used for transport; integrity comes from Ed25519 metadata and SHA-256
  package hashes.
- Version constraints are recorded but not interpreted beyond dependency names.
- `pkg upgrade`, removal, and rollback commands are not implemented yet.
- Downloaded packages are cached in tmpfs before install. P5c grows tmpfs files
  as needed, but large server packages still need a streaming store-write path.
