# CAPABILITIES

The forward design for swift-os authority: the object-capability **handle** model, **spawn-with-handles**,
handle-passing **IPC**, and the decision to make **Cells** a userland composition over small kernel
primitives rather than a fat in-kernel object.

> **Status: living design and implementation map.** C1-C5d now have checked-in
> slices: typed handle entries and rights, `spawn_handles`, object-scoped
> filesystem confinement, endpoint IPC with handle move semantics, a
> restartable driver-service smoke, pseudo/virtio-input discovery metadata,
> discovered MMIO metadata, and an opaque device-handle grant. The later parts of
> this note remain the target design for richer IPC rings/VMOs, real
> MMIO/IRQ/DMA driver handoff, and Cells.
> Future C-series work still lands one milestone at a time, each building,
> booting, passing a test, and stopping for review (per
> [CLAUDE.md](../CLAUDE.md)).

The maintainer should read this against the **current** model, not an idealized one. Where the current
model already does the right thing, this note says so; where it is a placeholder, this note says that too.

---

## 0. Where we are today (the honest baseline)

The current security core is `kernel/security/security.swift`:

```swift
struct ProcessSecurityContext {
    var principal: UInt32
    var session: UInt32
    var caps: UInt64          // flat bitmask
}

let capConsole: UInt64        = 1 << 0
let capSpawn: UInt64          = 1 << 1
let capFsRead: UInt64         = 1 << 2
let capTmpWrite: UInt64       = 1 << 3
let capProcessInspect: UInt64 = 1 << 4
let capNet: UInt64            = 1 << 5
let capLogExport: UInt64      = 1 << 6   // reserved; not boot-granted by default
```

Every process carries a `(principal, session, caps)` triple. `caps` is a single 64-bit word of permission
bits. Authorization is a bitmask test against the **running process's** word:

- `vfsOpen` checks `caps & capFsRead` / `caps & capTmpWrite` (`kernel/vfs/vfs.swift`);
- the namespace-mutating syscalls check `caps & capTmpWrite`;
- `vfsSocket` / `vfsResolve` check `caps & capNet`;
- `processLogin` is gated on `caps & capConsole`.
- the logging subsystem reserves `capLogExport` for future ring export / sink installation hooks, but
  no current process receives that bit by default.

Authority no longer flows only by ambient inheritance. `fork` still copies the
parent's handle table as the compatibility path, but `spawn(path)` starts with
stdio only, and `spawn_handles` starts with exactly the caller-provided handle
spec vector. The flat `(principal, session, caps)` context still gates coarse
classes such as filesystem, network, console, and login authority.

File descriptors are now the observable view of a typed handle table.
`kernel/vfs/handle.swift` defines `HandleKind`, `Rights`, `HandleEntry`, and
explicit inheritance specs. `kernel/vfs/vfs.swift` stores per-process
`HandleEntry` slots and reference-counted `OpenDescription` objects behind
them. C1 keeps POSIX fd numbering, but each fd now carries a kind and rights
mask: `.file`, `.tty`, `.pipe`, `.socket`, `.endpoint`, or `.device`.

Implemented C-series pieces:

- C1: fds-as-handles with per-handle rights and attenuation.
- C2: `spawn_handles` explicit inheritance, with `spawn` kept stdio-only and
  `fork` kept as the permissive compatibility path.
- C3: object-scoped filesystem confinement plus per-handle read/write checks,
  while the flat `caps` word remains a coarse class gate.
- C4a: `endpoint_create`, `ipc_send`, and `ipc_recv` with byte messages and
  one moved handle per message.
- C5a-C5d: `/bin/drvsvcdemo` supervises `/bin/drvinputd`, restarts it,
  discovers a `virtio-input.0` grant when QEMU exposes one or the
  `pseudo-input.0` fallback on headless boots, moves the opaque device grant
  over IPC, proves the grant is busy while owned by the service, surfaces
  discovered MMIO metadata without granting mapping authority, and reclaims it
  after exit.

This is still short of the full architecture. C5c/C5d discovery metadata and
grants deliberately do not expose MMIO ranges, IRQ endpoints, DMA windows, or
real virtio-input queue ownership, and C4a is not the future zero-copy ring/VMO
data path.

---

## 1. The gap: capability-as-flag vs. capability-as-reference

There are two distinct things the word "capability" means. SwiftOS still keeps
the weaker one as a coarse compatibility gate, while the C-series is moving
toward the stronger one as checked object references.

**Capability-as-permission-flag (today).** A capability is a *bit* in a process-global word that grants a
*class* of operation. `capFsRead` means "this process may read files" — all files the namespace can name.
`capNet` means "this process may open sockets" — any address, any port. The check is `subject has
permission P?`. This is, structurally, a refined uid: a per-process label that a central monitor consults.
It is ambient (held by the process, not attached to any object) and coarse (one bit covers an entire object
class).

**Capability-as-unforgeable-reference (the vision).** A capability *is* a typed, unforgeable handle to a
*specific* object, and it *carries* the rights you have on that object. Possessing the handle *is* the
authority — there is no separate "may I?" check against process identity, because holding the handle is the
proof. This is the seL4 / KeyKOS / Fuchsia-Zircon / Capsicum sense. The check becomes `does this handle
grant operation P on its referent?`. Authority is conferred by *having a reference*, not by *being a
subject*, and it is scoped to the one object the reference names.

The documented examples in ARCHITECTURE.md are all the *reference* kind, and a bitmask cannot express any
of them:

| Documented capability        | Why a global bit cannot express it                                              |
|------------------------------|---------------------------------------------------------------------------------|
| `fs:read:/models/llama-7b`   | Scoped to one subtree. A `capFsRead` bit grants the whole namespace.            |
| `net:listen:tcp:8080`        | Parameterized by protocol + port. `capNet` grants every socket on every port.   |
| `accel:use:gpu0`             | Names a specific device instance. A bit cannot say *which* GPU.                 |
| device MMIO range + IRQ endpoint (driver model) | These are object references, not booleans; you grant *this* IRQ line, not "may receive interrupts." |

The deeper problems with the bitmask are structural, not cosmetic:

- **No object scoping.** Rights apply to a class, never an instance. You cannot hand a process read access
  to one model bundle without handing it read access to everything readable.
- **No parameters.** `tcp:8080` and `gpu0` are data attached to a grant. A bit has no room for data.
- **No delegation or attenuation.** You cannot give a child *a subset* of what you hold, or hand one
  specific door to one specific service. Inheritance is all-or-nothing (the parent's whole word).
- **No revocation granularity.** You cannot revoke one grant; you can only clear a class-wide bit.
- **Confused-deputy exposure.** Because authority is ambient, a privileged service acts with *its* full
  authority on behalf of any caller. Reference-passing closes this: the caller hands the service the exact
  handle to act on, and the service can hold no more authority than it was given.

This is not an argument that the bitmask was wrong to ship. It is an argument
that it is a **floor**, and the ceiling is a handle table. The migration started
with C1-C5d and continues through the remaining target design below.

---

## 2. Handle table ABI (proposed target)

The target is a **per-process handle table**: a generalization of today's `(proc, fd)` → `OpenDescription`
table to every kind of kernel-managed object. A handle is a small, copyable *descriptor* that names a
kernel object and carries the rights the holder has on it. The kernel object itself lives in a per-kind
table behind the handle; the handle is the only way userland can refer to it.

### 2.1 Types (sketch)

These are illustrative Embedded-Swift shapes, not a committed ABI. They follow the kernel style in
[PHILOSOPHY.md](PHILOSOPHY.md): value types, typed ids over raw integers, no existentials on hot paths.

```swift
// Typed object ids. Strong types stop a FileId from being used as an EndpointId
// by accident; the on-the-wire syscall ABI still passes small integers.
struct FileId:     Equatable { let raw: UInt32 }
struct DirId:      Equatable { let raw: UInt32 }
struct SocketId:   Equatable { let raw: UInt32 }
struct EndpointId: Equatable { let raw: UInt32 }   // IPC endpoint
struct DeviceId:   Equatable { let raw: UInt32 }
struct ProcessId:  Equatable { let raw: UInt32 }
struct CellId:     Equatable { let raw: UInt32 }
struct VmoId:      Equatable { let raw: UInt32 }    // shared-memory region

enum HandleKind: UInt8 {
    case file        // a vnode or directory opened for I/O
    case dir         // a directory / namespace root
    case socket      // a network endpoint
    case pipe
    case tty         // console
    case ipcEndpoint // a message/door endpoint
    case vmo         // a shared-memory region       (future rich IPC path)
    case device      // an opaque device grant today; MMIO/IRQ/DMA later
    case process     // a process control handle
    case cell        // a cell control handle        (C6)
    case clock       // time source
}

// Rights are per-handle and per-kind. An OptionSet is a typed bitset: it reads
// like flags but is checked per *handle*, not per *process*. Some bits are
// generic (read/write/duplicate/transfer); others are kind-specific and only
// meaningful for one HandleKind.
struct Rights: OptionSet {
    let rawValue: UInt32
    static let read       = Rights(rawValue: 1 << 0)
    static let write      = Rights(rawValue: 1 << 1)
    static let execute    = Rights(rawValue: 1 << 2)
    static let map        = Rights(rawValue: 1 << 3)   // mmap a file/vmo
    static let duplicate  = Rights(rawValue: 1 << 4)   // may dup this handle
    static let transfer   = Rights(rawValue: 1 << 5)   // may pass over IPC
    static let getattr    = Rights(rawValue: 1 << 6)
    static let setattr    = Rights(rawValue: 1 << 7)
    // kind-specific, e.g. socket:
    static let listen     = Rights(rawValue: 1 << 8)
    static let connect    = Rights(rawValue: 1 << 9)
    // process control:
    static let waitOn     = Rights(rawValue: 1 << 10)
    static let kill       = Rights(rawValue: 1 << 11)
}

// One entry in a process's handle table. The `object` is a typed id into the
// per-kind object pool; `rights` is the authority THIS holder has; `badge` is an
// optional caller-set tag the holding object can read back (used by IPC: a server
// stamps each client's endpoint handle with a badge so it can tell callers apart
// without a separate identity lookup — the Zircon idea).
struct HandleEntry {
    var inUse  = false
    var kind   = HandleKind.file
    var object: UInt32 = 0      // FileId/SocketId/... raw, interpreted per kind
    var rights = Rights()
    var badge: UInt64 = 0
    var cloexec = false         // survives from today's fd flag
}
```

The syscall surface gains handle-generic calls that subsume the fd calls:

```text
handle_duplicate(h, newRights) -> h'     // newRights must be a subset (attenuation)
handle_close(h)
handle_rights(h) -> Rights
handle_transfer(...)                       // only via IPC send (see §4)
```

`open`, `socket`, `accept`, `pipe` become *constructors* that mint a handle of the right kind with rights
derived from the request (`O_RDONLY` → `.read`, etc.). `read`/`write`/`lseek`/`mmap` become operations that
look up the handle, **check the per-handle right**, then dispatch on `kind`.

### 2.2 The current fd table is a special case

The mapping is direct and is exactly why C1 is *behavior-preserving*:

| Former fd-table shape (`vfs.swift`)       | Current/generalized handle table                  |
|-------------------------------------------|---------------------------------------------------|
| `FDEntry { inUse, file, cloexec }`        | `HandleEntry { inUse, kind, object, rights, … }`  |
| fd-kind tag on the shared description     | `HandleEntry.kind` (`HandleKind`)                 |
| description-readable/writable booleans    | `rights.contains(.read/.write)`                   |
| `OpenDescription.refCount` + pool         | per-kind object pool with its own refcount        |
| `(proc, fd)` index                        | `(proc, handleIndex)` index                       |
| `dup` / `dup2` (bump `refCount`)          | `handle_duplicate` (with rights ⊆ source)         |
| `vfsCloseCloexec` on exec                 | drop handles with `cloexec` on exec               |

So fds keep working as small-integer handles to `kind ∈ {file, dir, pipe, tty, socket}`; nothing about the
busybox path changes at C1. The new object kinds (`ipcEndpoint`, `vmo`, `device`, `cell`) are simply more
`HandleKind` cases that arrive in later milestones. POSIX fd numbering (lowest-free, 0/1/2 = stdio) is kept
as the *fd view* of the handle table; non-POSIX handles (an IPC endpoint, a cell control handle) need not be
small dense integers and can live in a separate index range.

### 2.3 `~Copyable` handles: the Swift-specific advantage

seL4 proves capability non-duplication with a machine-checked proof over C. Fuchsia enforces it with kernel
bookkeeping and a userland that must be careful. swift-os can get a meaningful slice of that guarantee
**from the type system**, for free, at compile time.

A kernel-internal *owning* handle should be a move-only type:

```swift
struct OwnedHandle: ~Copyable {
    let index: UInt32
    consuming func transfer(to dst: inout HandleTable) -> UInt32 { /* move, do not copy */ }
    deinit { /* drop the underlying object reference exactly once */ }
}
```

Because `OwnedHandle` is `~Copyable`:

- it **cannot be silently duplicated** — duplication must be the explicit `handle_duplicate` call, which is
  the only place attenuation (`rights ⊆ source`) is enforced;
- it **cannot be dropped twice or leaked** — `deinit` runs exactly once when the binding ends, so the
  underlying refcount/ownership is balanced by construction. This is the same move-only discipline
  ARCHITECTURE.md already mandates for page frames and locks ("Zero-cost ownership… so lifetimes are
  static"), applied to capabilities;
- the compiler, not a runtime check, rejects the accidental-copy bugs that are the classic capability
  footgun.

This does not replace the runtime handle table (userland still holds integer handles, and a malicious or
buggy process can still pass a bad integer — that is checked at the syscall boundary). It hardens the
*kernel's own* manipulation of capabilities, which is where a confused-deputy or double-free in the
authority layer would be catastrophic. It is the concrete reason "capabilities in Swift" is more than
"capabilities in C with extra syntax."

**Non-goal for the ABI:** sparse/global capability spaces (CSpaces with guards, à la seL4) and capability
derivation trees with full revocation graphs. Start with a flat per-process table and explicit
duplicate/close; a revocation graph can come later if a milestone needs cascading revoke.

---

## 3. Spawn-with-handles (replacing ambient inheritance)

This is the keystone change to the process model, and the **single most expensive thing to retrofit**, so
it should land early (C2) before more code is written assuming the fork-inherits-everything shape.

### 3.1 The target call

```swift
struct ResourceLimits {
    var memoryBytes: UInt64
    var processCount: UInt32
    var handleCount: UInt32
    var cpuTimeBudget: UInt64    // accounting first; enforcement follows (PHILOSOPHY)
}

func spawn(image: ImageRef,
           argv: [String],
           env: [String],
           inheritedHandles: [HandleSpec],   // EXACTLY these, nothing else
           limits: ResourceLimits) -> ProcessId
```

The child's handle table starts **empty** and is populated *only* from `inheritedHandles`. The default for
an ordinary program is the three stdio handles and nothing more — no implicit copy of the parent's open
files, no implicit `capFsRead`-equivalent reach over the whole namespace, no socket authority unless a
socket/endpoint handle was explicitly passed. Each entry may be **attenuated** on the way in (pass a
read-only view of a handle the parent holds read-write). This is precisely the "grant explicit capabilities
and inherited handles" step the Identity-and-login model in ARCHITECTURE.md already specifies, and the shape
the Cells section already calls for ("M6 process launch should be shaped like `spawn(image, argv, env,
inheritedHandles, limits)`").

Current state: `processSpawnChild` uses the stdio-only inheritance mode,
`processSpawnChildWithHandles` uses the explicit handle vector, and `fork`
keeps the permissive "copy every handle" compatibility mode. `copyProcessSecurity`
still copies the parent's coarse caps word; object authority is increasingly
carried by the handle set.

### 3.2 Emulating `fork` on top

busybox `ash` needs `fork`. swift-os keeps it, but as a *library/compat* operation built on the primitive,
not as the foundation — matching ARCHITECTURE.md's Syscall ABI rule ("prefer `spawn` and explicit inherited
handles over making `fork` the central process primitive… `fork` may be emulated"). `fork` is the special
case of "spawn a copy of *this* image with *all of my current handles* duplicated and the same rights" —
i.e. fork is `spawn` with `inheritedHandles = (every handle I hold, duplicated)`. The existing
`processFork` address-space clone and trap-frame copy stay; what changes is that handle inheritance routes
through the same explicit-set mechanism (with "all" as the argument) instead of a bespoke table copy. That
keeps one code path for "what does a child start with," with fork passing the permissive argument and
`spawn` passing a tight one.

### 3.3 Why early

Every program written, every service manifest authored, and every driver launched encodes an assumption
about what its children start with. If that assumption is "inherits everything" and we flip it later, every
one of those call sites is a latent over-privilege bug that must be re-audited. Flipping the default *once,
early*, while the userland is still just busybox + a few `swift_user` programs, is cheap. Flipping it after
the driver framework, the network service, and the AI-serving cells exist is a system-wide rewrite. C2 is
deliberately sequenced right after the handle table and before IPC for this reason.

---

## 4. IPC: the keystone for everything restartable

### 4.1 Why IPC is load-bearing

ARCHITECTURE.md commits to a set of things that **cannot exist without local IPC that passes handles**:

- **Restartable userland driver services** ("Driver loading model", "Future hot update model"): clients
  "communicate with it through handle-based IPC"; the kernel grants the driver an "IRQ endpoint" and
  "DMA/shared-memory windows" — those *are* handles, delivered and used over IPC.
- **The userland TCP/IP service** ("Future network stack model"): "TCP/IP as a userland service, reachable
  only through capabilities," is an IPC server. Its performance non-negotiables (zero-copy, batching, async
  rings) are IPC design requirements, not afterthoughts (see §4.3).
- **The operator console / control plane** ("Reliability and control-plane model"): a small command channel
  separate from telemetry — two IPC endpoints with different rights.
- **AI serving cells** ("Future AI-hosting model"): one model server per cell, reached by local RPC, with
  hot reload draining old generations — supervisor↔cell and client↔cell IPC.

There is a standing contradiction worth stating plainly: **the current virtio
drivers (virtio-blk, virtio-net, virtio-input) live in the kernel**, which
contradicts the documented "restartable userland driver services" vision. That
is a reasonable bring-up choice. C4a/C5c now prove the IPC, discovery metadata,
and opaque-grant shape, but the documented architecture remains incomplete
until real IRQ/DMA/MMIO grants and a restartable userland driver land.

### 4.2 Minimal shape

Prior art to steal from, deliberately stripped down: **Solaris doors** (synchronous local RPC with
thread-handoff and credential passing), **QNX message passing** (the send/receive/reply core of a
microkernel), and **Zircon channels** (bidirectional message + handle transfer, with badges). The minimal
swift-os primitive:

```text
endpoint_create() -> (clientEnd: Handle, serverEnd: Handle)
ipc_send(endpoint, msgBytes, handles: [Handle])         // handles MOVE to receiver
ipc_recv(endpoint, into: buffer, outHandles: ...) -> (bytes, [Handle], badge)
ipc_call(endpoint, msg, handles) -> (reply, replyHandles) // send+block+reply, the doors fast path
```

Key properties:

- **Handle transfer, not copy.** A handle named in `ipc_send` is *removed* from the sender's table and
  *inserted* into the receiver's (subject to the `.transfer` right). This is how a name service hands a
  client a connected socket, how `spawn` could be expressed as "send the child its starting handles," and
  how a driver manager hands a driver its device/IRQ/DMA handles. The `~Copyable` `OwnedHandle.transfer`
  from §2.3 is exactly this move.
- **Badges** let a server distinguish clients without a side-channel identity lookup: each client's
  endpoint is minted with a server-chosen badge that `ipc_recv` reports. This is the structural defense
  against confused-deputy for servers.
- **Capability-reachable only.** An endpoint handle *is* the right to talk to the service. There is no
  global namespace of services that ambient authority can reach; you get a service by being handed its
  endpoint (typically by the supervisor / `init`).

### 4.3 Zero-copy, batching, async — tie to the network non-negotiables

The network "Performance model — non-negotiables" in ARCHITECTURE.md is, read carefully, a **specification
for the IPC layer**, because the userland network stack's data path *is* IPC. To avoid designing IPC twice,
those requirements are adopted here as first-class IPC features, not network-only optimizations:

- **Shared-memory regions (VMOs) as a handle kind.** Bulk data (packet buffers, model weight pages, file
  contents) lives in a shared region referenced by a `vmo` handle; only the *handle/descriptor* crosses the
  address-space boundary in a message, never the payload. This is requirement #1 (zero-copy, end to end).
- **Batched async rings + doorbells**, not a rendezvous per message. The control path uses
  virtio/io_uring-style shared descriptor rings: the sender enqueues N descriptors and rings a doorbell;
  the receiver drains in bulk on one wakeup. This is requirements #2 and #3 (batching everywhere; async
  notification, never sync-IPC-per-packet). Synchronous `ipc_call` remains available for control RPC (the
  doors model), but the *data* path is async rings.
- **Poll/event integration.** Doorbells must be pollable through the same event mechanism the rest of the
  system uses (today: `vfsPoll` over fds; an endpoint/ring is just another pollable handle). The network
  arc, libuv (Node), and serving loops all need one event surface.
- **Value-typed, no per-message allocation.** Preallocated message and ring slots; `~Copyable` ownership of
  buffer handles; no ARC on the send/recv path (requirement #5, and the PHILOSOPHY hot-path rule).

Designing IPC with these properties from the start is the difference between "userland services that are
multiples slower than an in-kernel monolith" and "userland services that match or beat one" (Arrakis, IX,
mTCP, Snap, cited in ARCHITECTURE.md). Retrofitting them means rewriting the data path, so they are C4
requirements, not C-later optimizations.

---

## 5. Cells — the decision

> **Recommendation: a Cell is a userland-supervisor composition over small kernel primitives, NOT a
> heavyweight in-kernel object.** The kernel keeps only a cheap per-process `CellId` tag (for accounting and
> namespace rooting); everything else that makes a "cell" is assembled in userland from primitives that
> already need to exist for other reasons.

### 5.1 The two options

**Option A — Cell as a fat kernel primitive.** Reify a `Cell` kernel object that owns the process group, the
namespace, the capability set, the resource counters, and the lifecycle state, the way **Solaris zones** and
**FreeBSD jails** are reified in their kernels. Authorization, resource control, and isolation all consult
this in-kernel object.

**Option B — Cell as a userland composition.** Define a Cell as a *bundle* of independently-useful kernel
primitives, assembled and supervised by a userland process (`init` / a cell supervisor):

```text
Cell  ≝  (a process-tree / job root)            // process control handles, supervision
       + (a set of handles / capabilities)       // §2 handle table — the cell's authority
       + (a resource-accounting domain)          // counters + limits keyed by a domain tag
       + (a VFS namespace + root view)           // per-process root/cwd, already in vfs.swift
```

The kernel does **not** have a `Cell` struct that owns all of that. It has a per-process `CellId` *tag* (one
`UInt32`, alongside today's `principal`/`session`) used for two cheap things: **resource accounting**
("charge this page/handle/CPU-tick to domain N") and **namespace rooting** ("this process's `/` resolves
within the cell's root"). This is the model **Fuchsia/Zircon** uses: there is no "container" object; a
"realm" is *composition* of jobs + handles + a namespace + a resource domain, assembled by component
manager in userland. **Genode** takes this even further — everything is recursive component composition over
capabilities, with no privileged container concept at all.

### 5.2 Why composition (the decision rationale)

This follows directly from PHILOSOPHY priority #1 ("Lightweight by design… every always-on subsystem must
justify its memory cost… and security surface") and #2 ("Simple enough to trust… avoid clever machinery when
a smaller explicit mechanism is enough"), and the decision rule "choose the smaller trusted surface."

A fat in-kernel `Cell` would **duplicate state that already exists**:

- the **process tree** already groups processes (`pParent` in `process.swift`);
- the **handle table** (§2) already holds a process's authority;
- the **namespace** already lives per-process (cwd/root in `vfs.swift`, which the Cells section already says
  should be "rooted in the current process/cell context");
- **resource accounting** is already per-process (`pResPages`, `pCpuTicks`) and only needs a domain key to
  aggregate.

Reifying a `Cell` object means a second source of truth for all of that, in the *trusted* core, that must be
kept consistent with the process tree, the handle tables, and the namespace on every operation. That is more
code, more invariants, more attack surface, and more boot-critical state — the opposite of the stated
priorities. Composition keeps the kernel's job to the one thing only the kernel can do (tag and isolate),
and pushes *policy* (what a cell contains, how it is supervised, when it restarts) to a userland supervisor
that can itself be restarted and updated.

### 5.3 The trade-off, honestly

This is not free. What composition **loses** versus zones/jails:

- **No single atomic kernel "destroy the cell" / "freeze the cell" operation.** Tearing down a cell is the
  supervisor walking the job tree and killing members, then reclaiming domain-tagged resources; there is no
  one syscall that atomically guarantees nothing in the cell still runs. Zones/jails get that atomicity from
  the kernel object. swift-os must get equivalent rigor from a correct supervisor + the resource-domain tag
  (so even a missed process is at least *contained and accounted*, and reclamation is bounded by the domain).
- **Isolation strength depends on the supervisor and the handle discipline**, not on a kernel-enforced wall.
  A bug that over-grants handles at cell creation under-isolates the cell. With jails, the kernel refuses
  cross-jail access regardless of handle bugs. Mitigation: the handle table *is* the wall — if a cell never
  receives a handle to something, it cannot name it (no ambient authority to fall back on, post-C2/C3); the
  per-process `CellId` plus a namespace root gives a coarse kernel-level backstop for VFS scoping.
- **More moving parts in userland.** The supervisor becomes a trusted component. But it is a *restartable,
  updatable* trusted component outside the kernel, which is consistent with the reliability model
  (supervisors, FDIR, restart) — preferable to growing the kernel.

What composition **gains**:

- a **small trusted core** (priority #1): the kernel learns one `UInt32` tag, not a subsystem;
- **reuse**: cells fall out of primitives (handles, jobs, namespaces, domains) that drivers, the network
  service, and serving all need anyway — no cell-specific kernel machinery;
- **flexibility**: "what a cell is" can evolve in userland (nested cells, different supervision policies)
  without kernel changes;
- **alignment** with the systems that got this right at scale recently (Fuchsia, Genode) rather than the
  monolithic-kernel ancestors (zones, jails).

**Capsicum** is the cross-check that the *capability* half is sound: FreeBSD's Capsicum showed you can
retrofit capability-mode (ambient authority dropped, rights attached to fds) onto a Unix process model
incrementally and usefully — which is essentially the C1→C3 path here. **seL4** is the cross-check on the
small-trusted-core half: a tiny capability-and-IPC kernel with everything else (including isolation domains)
built above it. swift-os sits deliberately between Capsicum's pragmatism and seL4's minimalism.

### 5.4 The CellId tag is consistent with this decision

Reserving a per-process `CellId` field now (the Cells section already asks M4 to "leave room for a `CellId`
or security context") is **not** a commitment to Option A. A tag is just an accounting/rooting key; it does
not imply a kernel `Cell` object owning state. Composition *wants* that tag — it is exactly the
resource-domain key and namespace-root selector §5.1 lists. So adding `CellId` to `ProcessSecurityContext`
(or alongside it) is the right, cheap, forward-compatible step, and it does not pre-decide the fat-object
question. C6 builds the supervisor that *uses* the tag; it does not add a kernel `Cell` struct.

---

## 6. Milestone staging (the C-series arc)

**Sequential, not parallel.** Every milestone below rewrites or extends the same three hot files
(`security.swift`, `process.swift`, `vfs.swift`) and each depends on the handle table from the one before.
Attempting these in parallel would mean three branches all rewriting `vfsProcessInit` and the process-create
path at once. They must land in order, and — per [CLAUDE.md](../CLAUDE.md) — each one **builds, boots in
QEMU, meets an acceptance test, is committed, then stops for review** before the next begins.

This arc slots after the current network work (the net-* series) in the same way the N-series followed the
M-series; naming it C1–C6 (capabilities) keeps it distinct from the M and net milestones.

| # | Milestone | What lands | Acceptance (illustrative) | Risk / note |
|---|-----------|------------|---------------------------|-------------|
| **C1** | Handle table + fds-as-handles | Implemented slice: typed `HandleEntry` table, `HandleKind`, per-handle `Rights`, and attenuation. POSIX fds remain the observable namespace. | busybox/coreutils fd behavior and handle unit tests stay green. | Landed as behavior-preserving groundwork. |
| **C2** | spawn-with-handles | Implemented slice: `spawn_handles` explicit inheritance; `spawn` is stdio-only; `fork` remains the all-handles compatibility path. | A restricted spawned child cannot reach handles it was not given. | Resource limits/env-rich spawn shape remains future work. |
| **C3** | Object-scoped authority | Implemented slice: filesystem confinement plus per-handle read/write rights. The flat `caps` word remains a coarse class gate. | Confined children cannot open outside their subtree; per-handle rights checks reject overuse. | Full bitmask retirement is not done. |
| **C4a** | Minimal handle-passing IPC | Implemented slice: `endpoint_create`, `ipc_send`, `ipc_recv`, byte messages, and one moved handle per message. | Processes exchange bytes and moved handles safely. | VMOs, async rings, badges, `ipc_call`, and high-throughput data paths remain future work. |
| **C5a-C5d** | Restartable driver-service smoke + device discovery metadata | Implemented slice: `/bin/drvsvcdemo` supervises `/bin/drvinputd`, restarts it, discovers `virtio-input.0` when attached or `pseudo-input.0` as fallback, transfers the opaque grant, observes busy ownership, surfaces discovered MMIO metadata, and reclaims it. | `make c5-device-metadata-test` passes under `-smp 4` with a QEMU virtio keyboard; broad boot covers the pseudo fallback. | This is not real MMIO/IRQ/DMA/virtio-input queue handoff yet. |
| **C5 proper** | First real userland driver over IPC | Lift one non-boot-critical driver (candidate: **virtio-input**, then virtio-net) out of the kernel into a supervised userland service that receives device/IRQ/DMA + endpoint handles and serves clients over C4 IPC. | The driver runs as a process; killing and restarting it recovers service; clients reach it only via a handed endpoint handle. | First real exercise of the whole stack. |
| **C6** | Cell as userland composition | Add the per-process `CellId` tag (accounting domain + namespace root). A userland **cell supervisor** assembles a cell = job + handle set + resource domain + namespace, and launches a process inside it. **No kernel `Cell` object.** | Two cells with separate namespaces/roots and separate resource accounting; a process in one cannot name objects in the other (handles + namespace root); per-cell counters reported. | Delivers the Cells vision as composition (§5). The tag is cheap; the policy is userland. |

Dependencies are strict: C2 needs C1's handle table; C3 needs C2's
explicit-grant model to have something to scope; C4 builds endpoint/VMO handle
kinds on C1's table and transfers them with C2's move mechanism; C5 is the
first thing that needs C1-C4 at once; C6 needs C5's supervisor pattern and C4's
IPC to assemble a cell. The implemented C1-C5d slices do not remove those
dependencies for the remaining richer work.

---

## 7. Explicit non-goals (this design)

- **Not** a global/sparse capability space with guards and full derivation/revocation graphs (seL4 CSpaces).
  Flat per-process tables + explicit duplicate/close first; cascading revocation only if a milestone needs
  it.
- **Not** a fat in-kernel `Cell`/zone/jail object (§5 — the whole point).
- **Not** network isolation, OCI/Docker images, image registries, overlay layers, seccomp-style policy VMs,
  nested cells, or live migration — all already postponed by ARCHITECTURE.md and unchanged here.
- **Not** SMP-aware capability or IPC scaling. Single core is assumed throughout (and, as with the network
  stack, it *removes* most of the hard concurrency in an IPC layer).
- **Not** a rewrite of `principal`/`session`. Those stay; handles and rights sit *beside* them. A principal
  still identifies *who*; handles increasingly carry *what you may touch*. The flat `caps` word narrows to a
  coarse gate (or retires) as object handles take over object-scoped authority.
- **Not** fully implemented. C1-C5d slices exist; C5 proper, richer IPC, and
  Cells remain planned work.

---

## 8. Prior art

- **seL4** — minimal capability-and-IPC microkernel; the gold standard for "small trusted core + everything
  above it." Cross-check for §2/§5.
- **Fuchsia / Zircon** — typed kernel object handles, rights, badges, handle transfer over channels; realms
  as *composition* (jobs + handles + namespaces), not a container object. The direct model for §2 and §5.
- **Genode** — recursive component composition over capabilities, no privileged container concept; the
  far end of the composition argument.
- **Capsicum (FreeBSD)** — incremental capability mode over a Unix process: ambient authority dropped,
  rights attached to fds. The model for the C1→C3 migration path.
- **FreeBSD jails / Solaris zones** — the reified-in-kernel isolation domains we are *not* copying (§5.1),
  and the source of the honest trade-offs in §5.3.
- **Solaris doors / QNX messages / Zircon channels** — local IPC: synchronous handoff RPC, the
  send/receive/reply core, bidirectional message+handle transfer. The model for §4.
- **Arrakis / IX / mTCP / Google Snap** — userland-service data-path performance via zero-copy, batching,
  and async rings; the evidence behind the §4.3 non-negotiables (and already cited in ARCHITECTURE.md).
