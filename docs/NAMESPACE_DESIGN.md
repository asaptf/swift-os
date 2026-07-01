# Per-Process Namespace Design Note

> **Design note — RECORD ONLY. Not a Phase-1 item.** No kernel changes are
> proposed for now. This note records intent so a future reader can pick it up;
> it does not schedule work. The active plan is Phase 1 in
> [Risk Remediation Roadmap](RISK_REMEDIATION_ROADMAP.md) — complete the
> capability/handle model, deliver SMP, move drivers toward restartable userland
> services. The generalization sketched here would be scheduled there later, if
> and when a concrete driver exists.

This note records a future generalization of SwiftOS's existing per-process
filesystem confinement into true per-process *namespaces* — a per-process root
plus a real mount table — and adopts a *lexical path-boundary* naming idea as a
cosmetic convention. It is written against the live source so the citations can
be checked; re-grep before acting on them, since the tree moves.

## What we have today

SwiftOS already ships real per-process filesystem confinement, enforced in the
kernel — not a path-syntax convention layered over a shared tree. The pieces, as
they exist in [`kernel/vfs/vfs.swift`](../kernel/vfs/vfs.swift) and
[`userland/lib/syscall.h`](../userland/lib/syscall.h):

- **Per-process confinement state.** `VFSProcessState.confine`, stored in the
  `vfsProcessStates` array keyed by VFS slot, is the current confinement root.
  Access goes through the small `confineNode` / `setConfineNode` helpers in
  `vfs.swift`. A value of `0` means *unconfined* (the whole namespace, the
  compatibility default); a non-zero value is the vnode index this process is
  confined to.
- **`SYS_CONFINE = 50`**, defined at `userland/lib/syscall.h:59`; the userland
  wrapper at `syscall.h:236` calls `__syscall3(SYS_CONFINE, (long)path, 0, 0)`.
- **`vfsConfine(path:)`** resolves the path, requires a directory, and is
  **confine-only / monotonic**: the new root must be a descendant of the current
  confinement (`isDescendant(node, of: confineNode(proc))`), so a confined process
  can never widen its own reach. It also pulls cwd inside the new root if cwd would
  fall outside it.
- **Inheritance across the process lifecycle.** On fork/spawn the child inherits
  the parent's confinement in `vfsProcessInit` by copying the parent's leader
  `cwdNode` and `confineNode` ("a confined parent's child stays confined"). The
  unconfined paths reset the slot to `0`.
- **Enforcement is pervasive, not advisory.** `confineRootForCurrentProcess()`
  and `confinedAllows(_)` feed confinement checks into `vfsOpen` and into the
  mutating and stat paths. This is the **C3** capability described in
  [Capabilities](CAPABILITIES.md) §6.

What is **missing** for true per-process namespaces is the structure underneath:

- There is **one global vnode tree**. The fixed node table
  (`private let maxNodes = 6144`, `nodes`, `nodeCount` at `vfs.swift:80`–`82`)
  is a single shared graph. The existing "mount" machinery —
  `buildBaseFromDisk` (`vfs.swift:666`), `mountPackageImages` (`vfs.swift:700`),
  `vfsMountDataFs` (`vfs.swift:1718`) — performs **build-time grafts into that
  one tree** (base image, package images, the `/data` datafs tier). It is not a
  per-process, runtime, namespace-scoped mount table: there is no
  `(namespaceId, mountpoint) → subtree` mapping and no per-process view
  divergence.

## Comparison to prior art

A well-known convention puts the container boundary in the path itself — a
lexical syntax such as `/ns::container/...`, where a `::`-delimited segment names
a sandbox inline in the pathname. It reads as a self-documenting way to say "this
path is rooted inside container X." In practice that syntax is usually **design
intent only**: the typical implementation behind it has one global archive (a
single tar), one shared open-file table, and no per-process root — the `::` is
cosmetic, not an isolation mechanism.

SwiftOS's implemented confinement **already exceeds a path-syntax-only design's
isolation**: `VFSProcessState.confine` is a per-process, inherited,
kernel-enforced, monotonic ceiling on what a process can name, checked on every
open and mutation — not a string convention. We therefore adopt only the
*naming-convention idea* from that prior art, never its implementation.

## The future generalization

Three pieces, sketched as a proposal — not a build plan.

1. **Per-process root override.** Generalize `VFSProcessState.confine` from a monotonic
   *ceiling* into a per-process *root* that can be rebased (chroot / pivot-root
   grade), so a process sees its namespace root as `/`. This is roughly **~90%
   present** already: the per-process slot, inheritance, and pervasive
   enforcement all exist. The remaining **~10%** is the ability to *rebase* `/`
   per process — to resolve `/` to a process-specific node and let the mount
   table below diverge — rather than only *narrow* the reachable set as
   `vfsConfine` does today.

2. **A real mount table keyed by `(namespaceId, mountpoint)`.** A small, fixed
   table mapping `(namespaceId, mountpoint vnode) → subtree root`, consulted
   during path walk, so two processes in different namespaces can see different
   trees at the same path. Today's grafts are global and build-time; this would
   be per-namespace and runtime. It must follow the allocation-free, fixed-table
   style the kernel already uses for `nodes` and VFS process state (bounded,
   no heap growth on the path walk hot path) and be touched only under `vfsLock`
   — the same discipline that protects the existing tables — so the future
   implementer inherits the right SMP/locking constraints from the start.

3. **The lexical-boundary path idea as a *convention*.** Adopt the `::`-style
   namespace-in-path notation purely as a **userland / tooling display and
   diagnostic convention** — e.g. how `ps`, logs, or a shell prompt might render
   a confined process's root — and **not** as a kernel parsing rule. The kernel
   never parses `::` to grant or restrict access. Authority stays
   capability/handle-based (C1–C3 and handles remain the only authority); the
   syntax is cosmetic naming for humans and tools, never a security boundary.
   Path strings neither grant nor restrict reach.

**No syscall is added by this note.** For a future implementer's reference only:
the syscall table is in [`userland/lib/syscall.h`](../userland/lib/syscall.h);
the highest number currently in use is `SYS_DEVICE_MMAP = 101`
(`syscall.h:110`), so a future namespace/mount syscall would take the next free
number there and be mirrored in the kernel dispatch. Nothing is allocated or
wired now.

## Relationship to existing docs

[Capabilities](CAPABILITIES.md) already covers the surrounding picture: §6
documents the C3 object-scoped confinement summarized above, and the **Cells**
discussion (§5, around lines 497–585, with the `CellId` tag at line 224) sketches
the longer-horizon per-process VFS namespace + root view and resource domain. It
notes that "the **namespace** already lives per-process (cwd/root in
`vfs.swift`)" (`CAPABILITIES.md:539`). This note does not restate that; it points
to it and focuses specifically on the mount-table + per-process-root
generalization and the lexical-boundary convention. Any real work would be
scheduled in [Risk Remediation Roadmap](RISK_REMEDIATION_ROADMAP.md), not here.

## Non-goals / when to revisit

- No syscalls, no ABI changes, no kernel work are part of recording this.
- Revisit only when there is a concrete driver for divergent `/` views — e.g.
  multi-tenant hosting that needs two processes to see different filesystems at
  the same path. Until then, the existing monotonic confinement is sufficient,
  and adding a per-namespace mount table would be unjustified complexity.
