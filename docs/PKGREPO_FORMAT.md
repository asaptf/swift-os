# SwiftOS Static Package Repository

P5b provides the first network repository format for `pkg`: a signed, static HTTP
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
{"channel":"current","expires":4102444800,"format":1,"generation":1,"packages":[{"abi":"swos-0","arch":"aarch64","depends":[],"linkage":"static","name":"pkghello","revision":1,"sha256":"...","size":21406,"target":"swift-os","url":"packages/<sha256>.swpkg","version":"1.0.0"}],"repository":"swift-os-current","root_key_id":"swos-test-root"}
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

The P5b target-side flow is explicit about the repository URL so QEMU tests can
use a random host port:

```sh
pkg update http://10.0.2.2:<port>/aarch64/current
pkg search pkghello
pkg info pkghello
pkg install pkghello
```

`pkg update URL` downloads `catalog.signed`, verifies the Ed25519 signature
against `/etc/pkg/repo-root.pub`, rejects expired catalogs, rejects package
entries for the wrong `arch`/`target`/`abi`/`linkage`, then caches the catalog
and URL in `/tmp`.

`pkg install NAME` loads the verified cached catalog, downloads the
content-addressed `.swpkg` listed by `url`, verifies SHA-256, then reuses the
local `pkg install FILE` path.

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
  user networking, proves expired/wrong-arch/bad-hash repos are rejected, runs
  `pkg update/search/info/install pkghello`, then executes `/usr/bin/pkghello`.

## Known Limits

- HTTP is used for transport; integrity comes from Ed25519 metadata and SHA-256
  package hashes.
- Dependencies and upgrades are not solved yet.
- Downloaded packages are cached in tmpfs before install. P5b grows tmpfs files
  as needed, but large server packages still need a streaming store-write path.
