# Package Manager Implementation Plan

Concrete readiness plan for package-management milestones P1-P5 from
`docs/PACKAGE_MANAGEMENT.md`.

This document is scoped to the `swift-os` repository. It does not define the
future `swift-os-ports` package catalog or public hosting automation, except
where P5 needs a small static repository fixture for tests.

## Current Repo Facts

- P1 is already partially implemented:
  - `tools/swpkg.swift` creates, inspects, and verifies `.swpkg` files.
  - `tools/packfs.swift` contains the shared host packed-filesystem builder and
    parser.
  - `tools/basepack.swift` is only a thin CLI around `buildPackedFS`.
  - `fixtures/pkghello/` provides a P1 manifest and a text-script payload.
  - `tests/swpkg_tool_test.swift` checks deterministic output and corrupted
    manifest/payload rejection.
  - `Makefile` builds `build/swpkg` and runs the host test from `make test`.
- The base image flow is:
  - `Makefile` stages `base/` plus compiled userland ELFs into
    `build/base-root`.
  - `tools/basepack.swift` emits `build/base.img`.
  - QEMU attaches `build/base.img` as one read-only virtio-blk device.
  - `kernel/drivers/virtio_blk.swift` currently selects one block device and
    exposes singleton read helpers.
  - `kernel/vfs/vfs.swift` parses the selected `SWOSBASE` image into a fixed
    vnode table and reads file bytes through `virtioBlkReadRange`.
- The VFS is still a single read-only base tree plus `/tmp`:
  - `maxNodes` is 96, which is too small for real package overlays.
  - Disk-backed vnodes store only one `diskOffset` and rely on the singleton
    virtio-blk reader.
  - The namespace has no generation, image identity, or conflict validation.
- `kernel/user/exec.swift` is still path-whitelisted:
  - `execResolve` matches known paths such as `/bin/ls` and `/bin/busybox`.
  - A package executable under `/usr/bin` will not run until exec becomes
    generic over VFS-backed executable files, or until P2 adds a temporary test
    special case.
- Target userland has important constraints:
  - Embedded Swift userland has no Foundation.
  - The small `userland/lib` bridge exposes syscalls and simple helpers, but no
    package-store API yet.
  - Newlib exists for some C programs, but the bottom end is intentionally small.
  - TCP, DNS, and a demo TLS client exist; HTTP package fetch should start as a
    tiny HTTP/1.0 client inside `pkg`.
- Existing QEMU tests are shell/FIFO driven. New package tests should follow the
  same pattern as `tests/disk_exec_test.sh`, `tests/busybox_test.sh`, and
  `tests/tcp_connect_test.sh`.

## Cross-Cutting Rules

- Land one package milestone at a time, with build, QEMU boot test, `make test`,
  commit, and stop for review.
- Keep package images immutable. Activation should be a namespace/store state
  change, not unpacking into mutable `/usr`.
- Keep package parsing out of the kernel where possible. The kernel should mount
  verified payload images and activation manifests; `pkg` should verify package
  containers and catalogs.
- Prefer uncompressed payloads through P5.
- Keep target-side parsers deliberately tiny. Host tools may use Foundation;
  `/bin/pkg` cannot.
- Do not make public package hosting or the large server software catalog part
  of P1-P5. P5 should prove the repo protocol with `pkghello`; the real catalog
  belongs to P6+ and `swift-os-ports`.

## P1: Host-Only Package Format

Goal: finish and harden the host-only `.swpkg` artifact milestone. No kernel or
target userland changes.

Current state: mostly implemented by `tools/swpkg.swift`.

Likely files/modules:

- `tools/swpkg.swift`
  - Keep the P1 container writer/verifier here.
  - Add any missing validation without changing the kernel.
- `tools/packfs.swift`
  - Shared packed-image build/parse code.
  - Do not duplicate file walking in package tools.
- `tools/basepack.swift`
  - Should remain a small wrapper; only touch if common packfs options need
    factoring.
- `fixtures/pkghello/`
  - Keep the host-only fixture.
  - Add a future ELF fixture only in P2, not as part of P1 cleanup.
- `tests/swpkg_tool_test.swift`
  - Add focused negative cases.
- `Makefile`
  - Keep `$(SWPKG)` and `swpkg` target wired into `make test`.
- `docs/SWPKG_FORMAT.md`
  - Update only if the actual P1 format changes.

Tests to add or extend:

- Reject a package whose manifest has the wrong `arch`.
- Reject a package whose manifest has the wrong `target`.
- Reject a package whose `abi.linkage` is not `static`.
- Reject payload entries outside `/usr`.
- Reject a malformed embedded `SWOSBASE` payload.
- Assert `inspect` prints stable name/version/revision/path/hash data.

Smallest acceptance criteria:

- `make swpkg` builds `build/swpkg`.
- `build/swpkg create --manifest fixtures/pkghello/manifest.json --root
  fixtures/pkghello/root --output <tmp>/pkghello.swpkg` is deterministic.
- `build/swpkg verify <tmp>/pkghello.swpkg` succeeds.
- Corrupted manifest and corrupted payload tests fail verification.
- `make test` runs `tests/swpkg_tool_test.swift`.

Risks:

- Host Foundation JSON support can hide target-side parser costs. Do not infer
  target feasibility from P1.
- `docs/BASE_IMAGE.md` describes an older format shape while code uses
  `SWOSBASE` version 2 with owner/mode. Keep future docs aligned before using
  them as a spec source.
- P1 signatures are reserved fields only. Do not let later milestones treat P1
  hashes as publisher authentication.

## P2: VFS Package Image Overlay

Goal: boot with base image plus one or more verified package payload images and
execute `/usr/bin/pkghello` from the package namespace. No persistent package
store, no `pkg` CLI, no downloads.

Likely files/modules:

- `kernel/drivers/virtio_blk.swift`
  - Refactor the singleton block device state into a small table of block
    devices.
  - Keep the existing base-image discovery behavior working.
  - Add read-range helpers that take a device/image identifier.
  - Do not add writes in P2 unless P3 work is intentionally pulled forward.
- `kernel/vfs/vfs.swift`
  - Replace `VNode.onDisk` plus singleton `diskOffset` with enough image identity
    to read from multiple packed images.
  - Add a small package-image metadata table: device id, data offset, node range,
    priority, package name for diagnostics.
  - Raise `maxNodes` or move the vnode table to a larger allocation. A realistic
    P2 value can still be fixed-size, but 96 is already too tight.
  - Teach packed-image mounting to add package paths under `/usr`.
  - Validate conflicts before linking package nodes into the live tree.
  - Keep base paths higher priority than packages unless a later milestone adds
    explicit replacement declarations.
  - Preserve `/tmp` writable behavior.
- `kernel/user/exec.swift`
  - Replace the long path whitelist with a generic VFS-backed executable load, or
    at minimum add a P2-only narrow path for `/usr/bin/pkghello`.
  - The better P2 result is generic absolute-path exec for regular files with an
    execute bit.
- `tools/swpkg.swift`
  - Add an `extract-payload` command if tests need to attach only
    `payload.swosbase` as a virtio-blk disk.
- `Makefile`
  - Add a test-only package payload build target, for example
    `build/pkghello.payload.img`.
  - Keep normal `build/base.img` behavior unchanged.
- `tests/`
  - Add `tests/package_overlay_test.sh`.
  - Add a conflict test if it can stay cheap; otherwise make conflict rejection a
    host/kernel unit test inside the P2 branch.
- `fixtures/pkghello/`
  - Replace or supplement the current text-script payload with a real static ELF
    for P2. The current fixture is useful for P1 hashing but is not directly
    executable by the kernel.

Tests to add:

- QEMU boot with `build/base.img` plus `build/pkghello.payload.img` attached as
  a second read-only virtio-blk disk.
- Shell-driven execution:
  - login as root;
  - `ls /usr/bin`;
  - run `/usr/bin/pkghello`;
  - assert a stable output marker.
- Conflict rejection:
  - attach a package that tries to provide a base path such as `/bin/ls`;
  - assert the kernel rejects the package image and base `/bin/ls` still works.

Smallest acceptance criteria:

- Existing `tests/vfs_disk_test.sh` and `tests/disk_exec_test.sh` still pass.
- `tests/package_overlay_test.sh` can execute `/usr/bin/pkghello` from a package
  payload image.
- A package/base path conflict does not silently shadow base files.
- `make test` includes the new P2 acceptance.

Risks:

- The current virtio-blk singleton cannot read two images. P2 must not break
  base image selection while adding package images.
- The current VFS node budget is a hard ceiling. Increasing only the constant
  may be enough for `pkghello`, but real packages need a more deliberate budget.
- Generic exec is a behavior change. It should remain restricted to executable
  regular files visible in the VFS and preserve busybox `/proc/self/exe` handling.
- Package overlay activation must not mutate the base tree in a way that makes
  rollback impossible in P3.

## P3: Package Store

Goal: add a narrow persistent package store with activation generations. This
is the storage and activation substrate for P4, not the final user-facing CLI.

Current state: P3a and the narrow P3b local-install path are implemented. The
kernel can discover one `SWPKGST1` package-store disk, scan
payload/activation/active-pointer records, and mount payloads from the active
generation at boot. `tools/pkgstore.swift` can create a preseeded store image
from `.swpkg` artifacts, initialize an empty writable store image, and inspect
records. `/bin/pkg install FILE` can install the test `pkghello.swpkg` from the
base image into a writable package store, switch the active generation, and
live-mount `/usr/bin/pkghello`. Remaining P3/P4 work is rollback, remove,
history, garbage collection, and broadening the package CLI beyond the first
local install/list commands.

Likely files/modules:

- `kernel/drivers/virtio_blk.swift`
  - Write support for the selected writable package-store block device exists.
  - Each discovered virtio-blk device has private queue state so base-image
    reads and package-store writes can interleave without resetting devices.
  - Keep base/package payload disks read-only by policy.
  - Expose device identity and capability flags: read-only image vs writable
    store.
- `kernel/pkg/store.swift`
  - Parse a minimal store superblock.
  - Append records for verified local package payloads, activations, and active
    pointers.
  - Track active generation.
  - Implement rollback by selecting a previous activation.
- `kernel/vfs/vfs.swift`
  - Load active activation manifests at boot.
  - Mount payload images listed by the active generation.
  - Live-mount the newly active package-store payload after local install.
- `kernel/syscall/syscall.swift`
  - Coarse package-store syscalls currently cover install and active package
    listing.
  - Add rollback/history/remove syscalls before exposing those CLI commands.
- `userland/lib/syscall.h`
  - Mirror any new syscall numbers.
- `userland/lib/swift_user.h` and `userland/lib/swift_user.c`
  - Add thin bridges for package-store operations if the P3 test helper or P4
    `/bin/pkg` is Swift.
- `tools/`
  - Add a host package-store image tool if needed, for example
    `tools/pkgstore.swift`, to create and inspect test store images.
- `Makefile`
  - Add `build/pkgstore.img` or a test-specific package-store image.
  - Add QEMU flags for a writable package-store disk in package tests without
    perturbing every existing test until the store is stable.
- `tests/`
  - `tests/pkg_store_boot_test.sh` covers boot activation from a preseeded
    store.
  - `tests/pkg_local_install_test.sh` covers `/bin/pkg install FILE`, live
    activation, `pkg list`, and execution of `/usr/bin/pkghello`.

Tests to add:

- Host test for package-store image initialization, creation, record checksums,
  and active generation selection is wired through `tests/pkgstore_tool_test.swift`.
- QEMU tests already cover boot generation N containing `pkghello` and local
  install into an empty writable store.
- Remaining tests should cover remove generation, boot persistence after local
  install, rollback to a previous generation, and garbage collection safety.

Smallest acceptance criteria:

- Boot activation mounts package payloads from the active generation.
- Local `/bin/pkg install FILE` writes a package payload into a writable store
  and live-mounts it.
- Existing base image and `/tmp` tests still pass.
- Next acceptance: a package-store disk survives a QEMU reboot after target-side
  install, and rollback restores a previous package namespace.

Risks:

- The project currently has no general persistent writable filesystem. P3 must
  stay narrower than a filesystem and avoid growing into one accidentally.
- Virtio-blk write support introduces corruption and cache-maintenance risks.
  Add minimal write/read-back tests before trusting activation.
- Atomicity needs a simple, testable rule. Prefer double superblocks or
  append-only "last valid generation wins" records with checksums over in-place
  mutation.
- Live activation is easy to overbuild. It is acceptable for P3 to require a
  reboot if P4 prints that clearly, but P5 should aim for live activation.

## P4: Local `/bin/pkg`

Goal: ship a target-side package manager in the base image that installs local
`.swpkg` files into the package store and activates them. No network repository
catalogs yet.

Current state: the smallest local subset is implemented: `pkg install FILE` and
`pkg list`. It uses a tiny target manifest scanner for canonical P1 JSON and
delegates hash verification/store append/live activation to the kernel. P4
proper should add the remaining local commands, sharper exit codes, and negative
fixtures.

Required commands:

- `pkg install ./name.swpkg`
- `pkg list`
- `pkg info <name>` (remaining)
- `pkg files <name>` (remaining)
- `pkg remove <name>` (remaining)
- `pkg history` (remaining)
- `pkg rollback [generation]` (remaining)

Likely files/modules:

- New target tool, likely `userland/pkg.swift`
  - Parse command-line arguments.
  - Parse the fixed `.swpkg` header.
  - Verify manifest and payload SHA-256.
  - Parse only the manifest fields needed for local install.
  - Check `arch`, `target`, `abi.os`, and `abi.linkage`.
  - Ask the package-store syscall layer to write blobs and activate generations.
- `kernel/crypto/sha256.swift`
  - Reuse from target userland as existing Swift tools already do.
- `userland/lib/swift_user.h` and `userland/lib/swift_user.c`
  - Package-store bridge calls.
  - Small helpers only; do not put package policy in the bridge.
- `userland/lib/syscall.h`
  - Any syscall constants needed by the bridge.
- `kernel/syscall/syscall.swift`
  - Dispatch package-store syscalls introduced in P3 or finalized in P4.
- `kernel/pkg/store.swift`
  - Enforce store invariants. `pkg` can request activation, but the kernel/store
    layer should reject malformed generation references.
- `Makefile`
  - Add build rules for `build/pkg.elf`.
  - Add `USER_PKG_ELF` to `BASE_EXEC_ELFS`.
  - Copy `build/pkg.elf` to `build/base-root/bin/pkg`.
  - Include any package tool sources, such as `kernel/crypto/sha256.swift`, in
    the compile rule.
- `base/`
  - Add package configuration only if needed for P4. Repository config belongs
    to P5.
- `tests/`
  - Add `tests/pkg_local_test.sh`.
  - Optionally add host parser tests for the target-compatible manifest scanner.
- `fixtures/pkghello/`
  - Use an ELF payload, not the P1 shell-script fixture, for local install tests.

Target parser recommendation:

- Do not port Foundation JSON.
- Start with a byte scanner that extracts required string/number fields and the
  file list from canonical P1 JSON.
- Treat unknown fields as ignored but preserve strict validation for required
  ABI fields.
- Keep dependency solving out of P4. Reject packages with unsatisfied
  dependencies unless all dependencies are already installed.

Tests to add:

- Boot with:
  - base image containing `/bin/pkg`;
  - writable package-store disk;
  - a local `.swpkg` available somewhere read-only, for example
    `/pkghello.swpkg` in the base image for the test.
- Shell-driven flow:
  - `pkg install /pkghello.swpkg`;
  - `pkg list`;
  - `pkg info pkghello`;
  - `pkg files pkghello`;
  - `/usr/bin/pkghello`;
  - `pkg remove pkghello`;
  - assert `/usr/bin/pkghello` no longer executes;
  - `pkg rollback`;
  - assert `/usr/bin/pkghello` executes again.
- Negative flows:
  - bad hash exits with code 5;
  - wrong ABI exits with code 6;
  - missing package exits with code 3.

Smallest acceptance criteria:

- `/bin/pkg` is present in the base image.
- Local install of `pkghello.swpkg` activates `/usr/bin/pkghello`.
- `pkg list` reports the installed package.
- Next acceptance: `pkg remove pkghello` creates a new active generation without
  it, and `pkg rollback` restores the previous generation.
- `make test` includes the local package flow.

Risks:

- The target-side manifest parser can easily become the largest fragile part of
  P4. Keep it narrow and test it with generated canonical fixtures.
- Store syscalls must not let a compromised `pkg` activate arbitrary unchecked
  payload references. The kernel/store layer should validate generation records
  against already-written verified payload hashes.
- Large packages will not fit in a tiny one-shot buffer. Even if P4 tests use
  `pkghello`, design store writes as streaming records or chunked writes.
- The current shell PATH and busybox behavior may not include `/usr/bin`.
  Tests should execute `/usr/bin/pkghello` explicitly until PATH policy is set.

## P5: Repository Catalogs and Network Fetch

Goal: install packages by name from a signed static HTTP repository. Integrity
comes from signed metadata and content hashes; HTTPS is not required for P5.

Current state: the P5c bootstrap path is implemented. `tools/pkgrepo.swift`
builds a signed static repository fixture, the base image ships
`/etc/pkg/repo-root.pub`, and `/bin/pkg` can update/search/info/install from an
explicit or configured HTTP repository URL. It rejects expired catalogs,
incompatible arch/target/ABI/linkage entries, validates dependency names against
the catalog, resolves dependencies by package name, and rejects downloaded
packages whose SHA-256 does not match the signed catalog. See
`docs/PKGREPO_FORMAT.md`.

Required commands:

- `pkg repo set <url>` and `pkg repo show` (implemented for P5c)
- `pkg update [url]` (implemented for P5c; explicit URL still keeps QEMU tests
  deterministic when needed)
- `pkg search <text>`
- `pkg info <name>`
- `pkg install <name>`
- `pkg upgrade` remains deferred until version-constraint and transaction rules
  are ready.

Likely files/modules:

- `userland/pkg.swift`
  - Add repository config loading. (implemented for one active URL)
  - Add HTTP GET over `swiftos_socket_stream`, `swiftos_connect`, read/write,
    and optionally `swiftos_resolve`.
  - Parse `catalog.json` or a canonical catalog subset.
  - Verify catalog signature and expiration.
  - Verify package blob SHA-256 against the signed catalog.
  - Resolve package-name dependencies from the signed catalog.
  - Reuse the P4 local install path after download.
- New userland or shared crypto verifier
  - Add Ed25519 verification if the project keeps the design default.
  - Keep verification in userland `pkg`; the kernel only needs hashes/store
    invariants.
- `tools/`
  - Add a host repository tool, for example `tools/pkgrepo.swift`, to build
    `catalog.json`, sign it, and lay out a static repo fixture.
  - Reuse `kernel/crypto/sha256.swift` for host hashes if practical.
- `base/etc/pkg/`
  - Add pinned root public key.
  - Add default repository config only when the public URL shape is stable.
    P5c already supports `/etc/pkg/repo-url` fallback plus `pkg repo set`.
- `Makefile`
  - Build any host repo tool.
  - Stage base package keys/config.
  - Add a static-repo fixture build target for tests.
- `tests/`
  - `tests/pkg_repo_install_test.sh`
  - `tests/pkgrepo_tool_test.swift`

Repository fixture shape:

```text
build/pkgrepo-root/
  aarch64/current/catalog.json
  aarch64/current/catalog.signed
  aarch64/current/packages/<sha256>.swpkg
```

Tests to add:

- Host-side catalog tests:
  - valid catalog verifies (implemented);
  - tampered catalog fails (implemented);
  - negative fixture generation for expired, wrong-arch, and bad-hash catalogs
    is covered by `tests/pkgrepo_tool_test.swift`.
- QEMU network test:
  - start a host static HTTP server from the fixture directory;
  - boot QEMU with user networking;
  - reject an expired catalog;
  - reject an incompatible arch catalog;
  - reject a package whose downloaded SHA-256 differs from the signed catalog;
  - configure a default repo URL and run `pkg update`;
  - run `pkg search pkghello`;
  - run `pkg install pkghello` and prove `pkgdep` is resolved first;
  - run `/usr/bin/pkghello`;
  - assert the package was fetched from the host server and activated.

Smallest acceptance criteria:

- `pkg update` fetches and verifies a catalog from a static HTTP server.
- `pkg install pkghello` downloads the content-addressed `.swpkg`, verifies its
  hash, installs its dependency first, installs through the P4 path, and
  executes `/usr/bin/pkghello`.
- Signature tampering is tested host-side.
- `make package-repo-install-test` covers the positive and negative QEMU
  repository flow; `make test` includes the host repository tool test.

Risks:

- Ed25519 is present and covered by `tests/ed25519_test.swift`; repository
  signing uses the same implementation.
- Userland TLS exists only as a demo without certificate verification. P5 should
  use HTTP plus signatures for integrity, exactly as the design says.
- Catalog parsing must stay bounded. Reject oversized catalogs in P5 rather
  than trying to support the future full public repository immediately.
- Repository package installs now stream payload bytes directly into the package
  store. Keep this path covered before attempting large packages such as
  Node.js, Swift, PostgreSQL, or a JVM.
- DNS is available, but the QEMU acceptance should use `10.0.2.2:<port>` first
  to keep failures focused on package logic.

## Readiness Checklist Before Starting P2

- P1 tests pass in the current branch.
- There is a real static ELF `pkghello` payload for `/usr/bin/pkghello`.
- Decide whether P2 package images are extra virtio-blk disks or payload images
  embedded in a test-only base path and loaded by the kernel. Extra virtio-blk
  disks are closer to P3, but require the block-driver refactor immediately.
- Decide whether P2 must implement generic exec now. The recommended answer is
  yes, because every later package depends on it.
- Confirm the package overlay node budget target. `maxNodes = 96` is not enough
  beyond toy fixtures.

## Top Risks Across P1-P5

1. Multi-image storage remains a central architectural risk. P3b gives
   virtio-blk per-device queue state and package-store writes, but larger
   packages will stress streaming and VFS overlay limits.
2. Generic executable loading from VFS is required for packages. The current
   path whitelist will block `/usr/bin/*`.
3. Persistent writes must stay narrower than a filesystem. P3 should implement a
   package store, not a mutable `/usr`.
4. Target-side JSON/catalog/signature parsing can grow too large. Keep P4/P5
   parsers bounded and heavily fixture-tested.
5. Real server packages are much larger than `pkghello`. P5 must not bake in
   all-in-memory download/store assumptions that would make Node.js, Swift,
   PostgreSQL, MariaDB, nginx, or a JVM impossible later.
