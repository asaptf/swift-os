# SwiftOS Ports Seed Catalog

`ports/catalog.json` is the P6a seed for the future `swift-os-ports`
repository. It is intentionally small and machine-readable: it records the
first package priorities, dependency names, OS prerequisite bundles, blocked
state, and the first smoke test each package must eventually pass.

This is not a full ports tree yet. Real `Port.toml` recipes, patches, distfile
fetching, package builds, QEMU smoke tests, and publishing workflows still
belong to the planned `swift-os-ports` repository. The seed catalog keeps that
work ordered and reviewable while the target-side package manager is still
being hardened inside `swift-os`.

Validate the catalog:

```sh
make ports-catalog-test
```

Useful inspection commands:

```sh
make swport
build/swport catalog list ports/catalog.json
build/swport catalog inspect nginx ports/catalog.json
build/swport catalog inspect nodejs ports/catalog.json
```

Catalog rules enforced by `swport catalog validate`:

- target must be `aarch64` / `swift-os` / `swos-0` / `static`;
- package names and `portPath` values must be unique;
- `status` must be `candidate`, `planned`, or `blocked`;
- `difficulty` must be `S`, `M`, `L`, or `XL`;
- runtime dependencies must name another catalog package;
- prerequisite bundles must be declared by the catalog;
- blocked packages must list concrete `blockedBy` reasons.
