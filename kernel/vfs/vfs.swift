// SPDX-License-Identifier: Apache-2.0
// vfs.swift — a small in-memory VFS: read-only base tree + writable tmpfs.
//
// The filesystem is a fixed vnode table linked as parent/child/sibling. The
// read-only base is built at init; /tmp is RAM tmpfs. File descriptors point at
// shared open-file descriptions, so dup/fork share offsets and pipe state.
//
// Implements: open, read, write, close, lseek, stat, fstat, getdents, chdir,
// getcwd, dup, dup2, pipe, eventfd, poll, unlink, rename, mkdir, rmdir.

// errno-ish returns (negative) come from the shared Errno table (kernel/errno.swift).

// Open flags (our ABI; userland lib/fs.h must match). The newlib bottom end
// (userland/lib/newlib_syscalls.c) translates newlib's BSD-style O_* values
// into these before the SYS_OPEN trap.
let oWrOnly = 1
let oRdWr = 2
let oCreat = 0x40
let oTrunc = 0x80
let oAppend = 0x100
let oCloexec = 0x200
// newlib's O_NONBLOCK is passed through fcntl(F_SETFL) directly (not via
// _open's kernel-ABI translation), so keep the newlib/POSIX-style bit here.
let oNonblock = 0x4000

// stat st_mode type bits.
private let sIFIFO: UInt32 = 0x1000
private let sIFCHR: UInt32 = 0x2000
private let sIFDIR: UInt32 = 0x4000
private let sIFREG: UInt32 = 0x8000

// dirent d_type.
private let dtDir: UInt8 = 4
private let dtReg: UInt8 = 8

// poll events (must match userland/compat/poll.h).
private let pollIn: Int16 = 0x001
private let pollOut: Int16 = 0x004
private let pollErr: Int16 = 0x008
private let pollHup: Int16 = 0x010
private let pollNval: Int16 = 0x020
private let pollfdSize = 8

// ---- vnode table ----------------------------------------------------------

private struct VNode {
    var inUse = false
    var isDir = false
    var readOnly = true
    var onDisk = false      // contents live on the virtio-blk disk (M11c)
    var namePtr: UInt = 0   // bytes of the name (not NUL-terminated)
    var nameLen = 0
    var dataPtr: UInt = 0   // file contents (in RAM: static literal or tmpfs)
    var dataLen = 0
    var dataCap = 0         // tmpfs growth capacity
    var diskImage = 0       // SWOSBASE image index for on-disk files
    var diskOffset = 0      // byte offset of contents within the disk image
    var dataFs = false      // contents persist on a writable datafs volume (D1)
    var dfsInode = -1       // datafs inode number when dataFs
    var dfsVolume = 0       // datafs volume slot when dataFs (V0: always 0 = /data)
    var special = 0         // device node: 0 none, 1 = /dev/null, 2 = /dev/zero
    var owner: UInt32 = 1   // owning principal (M13c); 1 = root/boot principal
    var mode: UInt32 = 0    // permission bits (M13c); 0 = unset → use heuristic
    var mtime: UInt64 = 0   // modification time, Unix seconds (0 = unknown)
    // I8 (signed base image): pointer to this entry's 32-byte content SHA-256
    // inside its kept signed-metadata buffer (0 for unsigned package payloads),
    // plus a once-per-boot cache so each disk file is verified on first use only.
    var hashPtr: UInt = 0
    var contentVerified = false
    var parent = -1
    var firstChild = -1
    var nextSibling = -1
}

// Keep fixed-table tmpfs churn headroom above the packed base image and early
// package payloads. Data packages such as tzdata add hundreds of read-only
// vnodes, so the bootstrap table is intentionally larger than the M7/M11 demos.
// The bundled npm tree alone is ~2060 files, so the base image now packs ~2700
// entries; size the table well above that plus runtime tmpfs headroom. At
// ~120 B/VNode this is ~0.7 MiB of the 16 MiB kernel heap.
private let maxNodes = 6144
private var nodes: UnsafeMutablePointer<VNode>! = nil
private var nodeCount = 0
private var mountedPackageStorePayloads = 0

// ---- open files, fd table, pipes -----------------------------------------

// Handle kinds live in handle.swift (HandleKind): .none/.tty/.file/.pipe/.socket,
// 1:1 with the former fdKind* constants (fdKindVNode → .file). net-b: a .socket
// description's `node` field indexes the socket table; eventfd descriptions use
// `node` for the event counter table; C5b .device descriptions index the opaque
// device grant registry below.

private let pipeReadEnd = 0
private let pipeWriteEnd = 1
private let pipeDuplexEnd = 2

private struct OpenDescription {
    var inUse = false
    var refCount = 0
    var kind: HandleKind = .none
    var node = -1
    var offset = 0
    var dirCursor = 0
    var flags = 0
    var pipe = -1
    var writePipe = -1
    var pipeEnd = pipeReadEnd
    var pty = -1
}

private struct Pipe {
    var inUse = false
    var bufPtr: UInt = 0
    var cap = 0
    var head = 0
    var tail = 0
    var readRefs = 0
    var writeRefs = 0
}

// C4a: an IPC endpoint — a channel carrying a single in-flight message that
// pairs BYTES with an optionally transferred Handle (the capability).
// Modeled on Pipe: a heap message buffer plus a one-slot handle, with
// sendRefs/recvRefs tracking open ends. See docs/CAPABILITIES.md §4.
private struct Endpoint {
    var inUse = false
    var hasMsg = false      // a message (bytes ± a handle) is pending in the slot
    var bufPtr: UInt = 0    // heap byte buffer (endpointMsgCap), like Pipe.bufPtr
    var msgLen = 0          // valid bytes in bufPtr for the pending message
    // QW4: the badge of the sender's send-capability, carried to the receiver so
    // ipc_recv_badged can tell which client a message came from. 0 = unbadged.
    // Set by ipc_send from the send HandleEntry's badge; cleared when consumed.
    var badge: UInt32 = 0
    var hasHandle = false
    var handle = HandleEntry()
    var sendRefs = 0
    var recvRefs = 0
    // QW3: owning process slot (mirrors DeviceGrant.ownerProc); -1 = unowned.
    // Both ends of a freshly created endpoint live in the creating process, so
    // the kernel can deterministically reclaim it when that process dies.
    var ownerProc = -1
    // QW1: a kernel-internal reply-port token (0 = none) carried alongside a
    // request delivered by ipc_call. ipc_reply_recv hands it to the receiving
    // server so the server can target the exact caller to reply to. Plain
    // ipc_send leaves it 0. Cleared when the message is consumed.
    var replyToken: UInt64 = 0
}
private let endpointMsgCap = 256

// QW1: a transient one-shot reply port — the synchronous-RPC counterpart to the
// Endpoint slot. ipc_call mints one, parks the caller on it, and records the
// request's token in the endpoint slot so the receiving server learns the port.
// ipc_reply_recv validates the token, deposits the reply, and wakes the exact
// parked caller. The port is named to the server only as a kernel-internal token
// (generation << 32 | index+1), never a user-forgeable fd, and is validated on
// every reply (must be inUse, generation-matched, and belong to the server's
// endpoint), so a user cannot reply to an arbitrary caller's port.
private struct ReplyPort {
    var inUse = false
    var bufPtr: UInt = 0        // 256-byte reply buffer (endpointMsgCap), allocated once & reused
    var hasReply = false        // a server has deposited its reply (bytes ± a handle)
    var replyLen = 0
    var hasHandle = false
    var handle = HandleEntry()
    var callerSlot = -1         // scheduler slot of the parked caller (wake target)
    var endpoint = -1           // owning endpoint, so the recv-end EOF path can fail pending ports
    var generation: UInt32 = 0  // nonce, bumped each alloc & persisted across free: a freed token never revalidates
}
private let maxReplyPorts = 16
private var replyPorts = [ReplyPort](repeating: ReplyPort(), count: maxReplyPorts)

private struct EventCounter {
    var inUse = false
    var counter: UInt64 = 0
    var flags = 0
}

// C5b: a tiny opaque device registry. This deliberately does not map MMIO,
// route IRQs, or allocate DMA windows yet; it only mints a unique transferable
// handle that names a future driver-owned device grant.
private struct DeviceGrant {
    var inUse = false
    var claimed = false
    var namePtr: UInt = 0
    var nameLen = 0
    var kind: UInt32 = 0
    var bus: UInt32 = 0
    var mmioBase: UInt = 0
    var mmioLen: UInt = 0
    var irq: UInt32 = 0
    var flags: UInt32 = 0
    var generation: UInt32 = 0
    var ownerProc = -1
    // LA2: kernel-only — claimable by name but omitted from the device_discover
    // ordinal enumeration. Used for the mappable alias over an already-discovered
    // virtio-mmio window so it is not surfaced as a second, distinct piece of
    // hardware (and so the C5 discovery-exhaustion contract is unchanged).
    var discoverable = true
}

private let maxFDs = 512
private let maxOpenDescriptions = 1024
private let maxPipes = 16
private let pipeCap = 1024
private var maxVFSProcesses = kInitialProcessSlots
private let maxEvents = 16

private struct VFSProcessState {
    var handlesPtr: UInt = 0
    var cwd: Int = 0
    var confine: Int = 0
}

// PT2c: the fd table is the second heavyweight per-process resource moved out
// of fixed slot storage. Each VFS group leader gets a maxFDs table on demand;
// inactive slots and thread followers pay only this small state record.
private var vfsProcessStates: UnsafeMutablePointer<VFSProcessState>! = nil
private var openDescriptions = [OpenDescription](repeating: OpenDescription(), count: maxOpenDescriptions)
private var pipes = [Pipe](repeating: Pipe(), count: maxPipes)
private var eventCounters = [EventCounter](repeating: EventCounter(), count: maxEvents)
// Raised 16 → 32 for IPC-heavy multi-service loads (PT1 follow-up). satstress
// discovers the ceiling at runtime; tests/max_endpoints_test.sh requires >16.
private let maxEndpoints = 32
private var endpoints = [Endpoint](repeating: Endpoint(), count: maxEndpoints)
// QW2: per-endpoint blocked-receiver waiter table. A receiver that finds an
// empty endpoint parks here (slot index) instead of busy-yielding through the
// run queue. Indexed as ep * maxRecvWaitersPerEndpoint + k; -1 = empty.
private let maxRecvWaitersPerEndpoint = 4
private var endpointRecvWaiters = [Int32](
    repeating: -1, count: maxEndpoints * maxRecvWaitersPerEndpoint)
private let endpointSendEnd = pipeWriteEnd  // ipc_send transfers a handle from here
private let endpointRecvEnd = pipeReadEnd   // ipc_recv receives it here
private let maxDevices = 6
private var devices = [DeviceGrant](repeating: DeviceGrant(), count: maxDevices)

// C6b: the cell allocation table — the kernel half of a Cell (docs/CAPABILITIES.md
// §5). This is NOT a fat Cell object: it only allocates/validates a CellId and, in
// later slices, will carry the namespace root (C6c) and limits (C6d). Everything a
// cell "contains" (its job tree, handle set, resources) lives in the existing
// per-process tables keyed by the CellId tag; this table just makes the tag's
// lifecycle explicit. `cells[i]` corresponds to `CellId(raw: UInt32(i + 1))`, so
// index 0 is `globalCell` (raw 1) and is always live and never handed out.
private struct CellSlot {
    var inUse = false
    var generation: UInt32 = 0   // bumped on alloc; reserved for handle-staleness checks (C6d)
    var ownerProc = -1           // the process that created the cell (for C6d reclaim)
    // C6c: the cell's VFS namespace root (a node in the global tree). 0 = unconfined
    // (the whole namespace, like globalCell). A process spawned into the cell has its
    // C3 confine root + cwd set to this node, so it resolves `/` within the subtree
    // and cannot reach anything outside it (isDescendant check). Reuses the C3
    // machinery — no separate per-cell mount table.
    var root = 0
    // C6d: optional hard resident-page ceiling (0 = unlimited). Enforced at
    // spawn-into-cell time (C6d) AND at the per-process resident-page growth sites
    // (C7a) — the cell aggregate can never exceed it.
    var pageCap = 0
    // C7b: optional hard handle ceiling (0 = unlimited). Enforced at the user-facing
    // handle constructors (allocUserFD): a member of a capped cell that mints a new
    // handle past the cell's aggregate handle count is refused with EMFILE.
    var handleCap = 0
}
private let maxCells = 8
private var cells = [CellSlot](repeating: CellSlot(), count: maxCells)
private let deviceInfoSize: UInt = 64
private let deviceInfoNameOffset = 40
private let deviceInfoNameCap = 24
private let eventFlagSemaphore = 1
private let eventAllowedFlags = eventFlagSemaphore | oNonblock | oCloexec
private let eventMaxCounter = UInt64.max - 1
private let deviceKindPseudoInput: UInt32 = 1
private let deviceKindVirtioInput: UInt32 = 2
private let deviceKindVirtioNet: UInt32 = 3   // NS1: network-serviceization grant
private let deviceBusPseudo: UInt32 = 1
private let deviceBusVirtioMmio: UInt32 = 2
private let deviceFlagNoMmioGrant: UInt32 = 1 << 0
private let deviceFlagDiscovered: UInt32 = 1 << 1
// LA2: this grant authorizes mapping the device's MMIO window (sys_device_mmap),
// so a claim yields a `.map` right. Mirrors SWIFTOS_DEVICE_FLAG_MMIO_GRANT in
// userland/lib/syscall.h. Mutually exclusive with deviceFlagNoMmioGrant.
private let deviceFlagMmioGrant: UInt32 = 1 << 2
// LA1: a tiny in-kernel name registry — the capability-microkernel NameServer
// split. A privileged publisher (capConsole) registers the RECV end of an
// endpoint under a short name; the registry pins that endpoint by holding an
// extra description ref so it survives the publisher closing its fd. A looker-up
// is granted a fresh SEND-end handle to the same endpoint — explicit grant by
// lookup, never ambient. Bounded fixed-size table (no heap growth on the hot
// path), touched only under vfsLock like the rest of the shared VFS state.
private struct NameEntry {
    var inUse = false
    var nameLen = 0
    var recvDesc = -1   // pinned recv-end OpenDescription index (holds a +1 ref)
}
private let maxServiceNames = 8
private let serviceNameCap = 16
private var serviceNames = [NameEntry](repeating: NameEntry(), count: maxServiceNames)
private var serviceNameBytes = [UInt8](repeating: 0, count: maxServiceNames * serviceNameCap)
// C3: VFSProcessState.confine is the subtree a process is confined to —
// object-scoped fs authority. 0 means unconfined (the whole namespace, the
// compatibility default). isDescendant(_, of: 0) is always true.

// rt-a: POSIX threads share ONE file-descriptor table (and cwd / confinement).
// Each VFS slot names its group leader — the slot whose lazily allocated fd
// table, cwd, and confine root the whole thread group uses. A normal process /
// fork child is its own leader; a thread (thread_create) points at its creator's
// leader so an fd opened by ANY thread (e.g. libuv's async-wake eventfd) is
// visible to all of them. Without this, per-thread fd-table COPIES diverge and a
// wakeup written by one thread never reaches the fd another polls — node -e
// deadlocked here.
// -1 = uninitialised → treated as identity (the slot is its own leader).
private var vfsGroupLeader: UnsafeMutablePointer<Int>! = nil

/// Resolve a slot to the group leader that owns its shared fd table / cwd.
private func vfsLeader(_ slot: Int) -> Int {
    guard vfsGroupLeader != nil && slot >= 0 && slot < maxVFSProcesses else { return slot }
    let l = vfsGroupLeader[slot]
    return (l >= 0 && l < maxVFSProcesses) ? l : slot
}

@inline(__always)
private func vfsProcessValid(_ slot: Int) -> Bool {
    vfsProcessStates != nil && slot >= 0 && slot < maxVFSProcesses
}

private func vfsGrowTable<T>(_ old: UnsafeMutablePointer<T>?,
                             oldCount: Int,
                             newCount: Int,
                             defaultValue: T) -> UnsafeMutablePointer<T>? {
    if newCount <= 0 { return nil }
    let bytes = MemoryLayout<T>.stride * newCount
    guard let raw = swiftos_kernel_alloc(UInt(bytes), 16) else { return nil }
    let next = raw.bindMemory(to: T.self, capacity: newCount)
    var i = 0
    if let oldTable = old {
        while i < oldCount {
            next[i] = oldTable[i]
            i += 1
        }
    }
    while i < newCount {
        next[i] = defaultValue
        i += 1
    }
    return next
}

func vfsEnsureProcessCapacity(_ requestedCapacity: Int) -> Bool {
    let daif = vfsLock()
    defer { vfsUnlock(daif) }

    if vfsProcessStates != nil && requestedCapacity <= maxVFSProcesses { return true }
    let oldCapacity = vfsProcessStates == nil ? 0 : maxVFSProcesses
    let newCapacity = requestedCapacity > maxVFSProcesses ? requestedCapacity : maxVFSProcesses
    guard let nextStates = vfsGrowTable(vfsProcessStates,
                                        oldCount: oldCapacity,
                                        newCount: newCapacity,
                                        defaultValue: VFSProcessState()),
          let nextLeaders = vfsGrowTable(vfsGroupLeader,
                                         oldCount: oldCapacity,
                                         newCount: newCapacity,
                                         defaultValue: -1) else {
        return false
    }
    vfsProcessStates = nextStates
    vfsGroupLeader = nextLeaders
    maxVFSProcesses = newCapacity
    return true
}

private func handleTable(_ proc: Int) -> UnsafeMutablePointer<HandleEntry>? {
    if !vfsProcessValid(proc) { return nil }
    let addr = vfsProcessStates[proc].handlesPtr
    if addr == 0 { return nil }
    return UnsafeMutablePointer<HandleEntry>(bitPattern: addr)
}

private func ensureHandleTable(_ proc: Int) -> UnsafeMutablePointer<HandleEntry>? {
    if let table = handleTable(proc) { return table }
    if !vfsProcessValid(proc) { return nil }
    let bytes = MemoryLayout<HandleEntry>.stride * maxFDs
    guard let raw = swiftos_kernel_alloc(UInt(bytes), 16) else { return nil }
    let table = raw.bindMemory(to: HandleEntry.self, capacity: maxFDs)
    for fd in 0..<maxFDs { table[fd] = HandleEntry() }
    vfsProcessStates[proc].handlesPtr = UInt(bitPattern: raw)
    return table
}

private func clearHandleTable(_ proc: Int) {
    guard let table = handleTable(proc) else { return }
    for fd in 0..<maxFDs { table[fd] = HandleEntry() }
}

private func releaseHandleTableEntries(_ proc: Int) {
    guard let table = handleTable(proc) else { return }
    for fd in 0..<maxFDs {
        if table[fd].inUse {
            releaseDescription(table[fd].object)
            table[fd] = HandleEntry()
        }
    }
}

private func cwdNode(_ proc: Int) -> Int {
    vfsProcessValid(proc) ? vfsProcessStates[proc].cwd : 0
}

private func setCwdNode(_ proc: Int, _ node: Int) {
    if vfsProcessValid(proc) { vfsProcessStates[proc].cwd = node }
}

private func confineNode(_ proc: Int) -> Int {
    vfsProcessValid(proc) ? vfsProcessStates[proc].confine : 0
}

private func setConfineNode(_ proc: Int, _ node: Int) {
    if vfsProcessValid(proc) { vfsProcessStates[proc].confine = node }
}

private var vfsLockWord: UInt64 = 0
private var vfsLockAcquireCount: UInt64 = 0
private var vfsLockContentionCount: UInt64 = 0

@inline(__always)
private func vfsLock() -> UInt64 {
    let daif = irq_save()
    var contended = false
    while true {
        var expected: UInt64 = 0
        let acquired = withUnsafeMutablePointer(to: &vfsLockWord) { word in
            smpAtomicCompareExchange(word, expected: &expected, desired: 1)
        }
        if acquired {
            if contended {
                withUnsafeMutablePointer(to: &vfsLockContentionCount) { count in
                    _ = smpAtomicFetchAdd(count, 1)
                }
            }
            withUnsafeMutablePointer(to: &vfsLockAcquireCount) { count in
                _ = smpAtomicFetchAdd(count, 1)
            }
            smpMemoryBarrier()
            return daif
        }
        contended = true
        smpLoadBarrier()
    }
}

@inline(__always)
private func vfsUnlock(_ daif: UInt64) {
    smpMemoryBarrier()
    withUnsafeMutablePointer(to: &vfsLockWord) { word in
        smpAtomicStore(word, 0)
    }
    irq_restore(daif)
}

@inline(__always)
private func vfsLockAtomicLoad(_ word: inout UInt64) -> UInt64 {
    withUnsafeMutablePointer(to: &word) { ptr in
        smpAtomicLoad(ptr)
    }
}

// ---- construction ---------------------------------------------------------

private func allocNode() -> Int {
    if nodeCount >= maxNodes { return -1 }
    let i = nodeCount
    nodeCount += 1
    nodes[i] = VNode()
    nodes[i].inUse = true
    return i
}

private func setName(_ node: Int, _ name: StaticString) {
    nodes[node].namePtr = UInt(bitPattern: name.utf8Start)
    nodes[node].nameLen = name.utf8CodeUnitCount
}

private func setNameCopy(_ node: Int, _ namePtr: UnsafePointer<UInt8>, _ nameLen: Int) -> Bool {
    if nameLen <= 0 { return false }
    guard let nameBuf = swiftos_kernel_alloc(UInt(nameLen), 1) else { return false }
    let nb = nameBuf.bindMemory(to: UInt8.self, capacity: nameLen)
    for i in 0..<nameLen { nb[i] = namePtr[i] }
    nodes[node].namePtr = UInt(bitPattern: nameBuf)
    nodes[node].nameLen = nameLen
    return true
}

private func linkChild(_ parent: Int, _ child: Int) {
    nodes[child].parent = parent
    nodes[child].nextSibling = nodes[parent].firstChild
    nodes[parent].firstChild = child
}

private func unlinkChild(_ parent: Int, _ child: Int) -> Bool {
    var prev = -1
    var cur = nodes[parent].firstChild
    while cur != -1 {
        if cur == child {
            if prev == -1 {
                nodes[parent].firstChild = nodes[cur].nextSibling
            } else {
                nodes[prev].nextSibling = nodes[cur].nextSibling
            }
            nodes[cur].nextSibling = -1
            return true
        }
        prev = cur
        cur = nodes[cur].nextSibling
    }
    return false
}

private func addDir(_ parent: Int, _ name: StaticString, readOnly: Bool = true) -> Int {
    let n = allocNode()
    if n < 0 { return -1 }
    setName(n, name)
    nodes[n].isDir = true
    nodes[n].readOnly = readOnly
    linkChild(parent, n)
    return n
}

// V2a: like addDir but with a dynamic (runtime-byte) name — used to name a
// volume mount point after its on-disk label.
private func addDirNamed(_ parent: Int, _ namePtr: UnsafePointer<UInt8>, _ nameLen: Int,
                         readOnly: Bool) -> Int {
    let n = allocNode()
    if n < 0 { return -1 }
    if !setNameCopy(n, namePtr, nameLen) { return -1 }
    nodes[n].isDir = true
    nodes[n].readOnly = readOnly
    linkChild(parent, n)
    return n
}

// Add a /dev special node (1 = null, 2 = zero). Reads of null give EOF, reads of
// zero give zero bytes; writes to either are discarded. Many programs (and the
// shell's job control) need /dev/null.
private func addSpecial(_ parent: Int, _ name: StaticString, _ special: Int) {
    let n = allocNode()
    if n < 0 { return }
    setName(n, name)
    nodes[n].isDir = false
    nodes[n].readOnly = false
    nodes[n].special = special
    nodes[n].mode = 0o666
    linkChild(parent, n)
}

private func addFile(_ parent: Int, _ name: StaticString, _ content: StaticString) {
    let n = allocNode()
    if n < 0 { return }
    setName(n, name)
    nodes[n].dataPtr = UInt(bitPattern: content.utf8Start)
    nodes[n].dataLen = content.utf8CodeUnitCount
    nodes[n].readOnly = true
    linkChild(parent, n)
}

// ---- disk-backed read-only base (M11c) ------------------------------------

private func le32(_ p: UnsafePointer<UInt8>, _ off: Int) -> UInt32 {
    UInt32(p[off]) | (UInt32(p[off + 1]) << 8) |
    (UInt32(p[off + 2]) << 16) | (UInt32(p[off + 3]) << 24)
}

private func le64(_ p: UnsafePointer<UInt8>, _ off: Int) -> UInt64 {
    var v: UInt64 = 0
    var i = 7
    while i >= 0 { v = (v << 8) | UInt64(p[off + i]); i -= 1 }
    return v
}

private func storeLe64(_ p: UnsafeMutablePointer<UInt8>, _ off: Int, _ v: UInt64) {
    var i = 0
    while i < 8 {
        p[off + i] = UInt8((v >> UInt64(i * 8)) & 0xFF)
        i += 1
    }
}

private func bytesEqual(_ a: UnsafePointer<UInt8>, _ aLen: Int, _ b: UnsafePointer<UInt8>, _ bLen: Int) -> Bool {
    if aLen != bLen { return false }
    var i = 0
    while i < aLen {
        if a[i] != b[i] { return false }
        i += 1
    }
    return true
}

private func addDiskDir(_ parent: Int, _ namePtr: UInt, _ nameLen: Int,
                        _ owner: UInt32, _ mode: UInt32) -> Int {
    let n = allocNode()
    if n < 0 { return -1 }
    nodes[n].namePtr = namePtr
    nodes[n].nameLen = nameLen
    nodes[n].isDir = true
    nodes[n].readOnly = true
    nodes[n].owner = owner
    nodes[n].mode = mode
    linkChild(parent, n)
    return n
}

private func addDiskFile(_ parent: Int, _ namePtr: UInt, _ nameLen: Int,
                         _ diskImage: Int, _ diskOffset: Int, _ dataLen: Int,
                         _ owner: UInt32, _ mode: UInt32, _ hashPtr: UInt) {
    let n = allocNode()
    if n < 0 { return }
    nodes[n].namePtr = namePtr
    nodes[n].nameLen = nameLen
    nodes[n].readOnly = true
    nodes[n].onDisk = true
    nodes[n].diskImage = diskImage
    nodes[n].diskOffset = diskOffset
    nodes[n].dataLen = dataLen
    nodes[n].owner = owner
    nodes[n].mode = mode
    nodes[n].hashPtr = hashPtr
    linkChild(parent, n)
}

/// Resolve the parent directory for an image path like "etc/motd": walk the
/// already-created directory nodes (entries are sorted, so parents precede
/// their children) and return the parent plus the leaf name slice. Returns -1
/// if an intermediate directory is missing.
private func resolveBuildParent(_ root: Int, _ pathPtr: UnsafePointer<UInt8>, _ pathLen: Int)
    -> (parent: Int, leafPtr: UInt, leafLen: Int) {
    var slash = -1
    var i = pathLen - 1
    while i >= 0 { if pathPtr[i] == 0x2F { slash = i; break }; i -= 1 }
    if slash < 0 {
        return (root, UInt(bitPattern: pathPtr), pathLen)
    }
    var cur = root
    var p = 0
    while p < slash {
        let start = p
        while p < slash && pathPtr[p] != 0x2F { p += 1 }
        let comp = findChild(cur, pathPtr + start, p - start)
        if comp == -1 || !nodes[comp].isDir { return (-1, 0, 0) }
        cur = comp
        while p < slash && pathPtr[p] == 0x2F { p += 1 }
    }
    let leafStart = slash + 1
    return (cur, UInt(bitPattern: pathPtr + leafStart), pathLen - leafStart)
}

private let vfsActiveBaseImage = -1

private func readPackedImageHeader(_ hdr: UnsafePointer<UInt8>)
    -> (Bool, Bool, Int, Int, UInt64, UInt64, UInt64, UInt64, Int) {
    let magic: StaticString = "SWOSBASE"
    var magicOk = true
    magic.withUTF8Buffer { m in
        for i in 0..<m.count where hdr[i] != m[i] { magicOk = false }
    }
    if !magicOk { return (false, false, 0, 0, 0, 0, 0, 0, 0) }
    let version = le32(hdr, 8)
    let signed = version == 3
    if version != 2 && version != 3 { return (false, false, 0, 0, 0, 0, 0, 0, 0) }
    let entrySize = signed ? 72 : 40
    if le32(hdr, 12) != 64 { return (false, false, 0, 0, 0, 0, 0, 0, 0) }
    if le32(hdr, 16) != UInt32(entrySize) { return (false, false, 0, 0, 0, 0, 0, 0, 0) }

    let entryCount = Int(le32(hdr, 20))
    let entriesOffset = le64(hdr, 24)
    let stringsOffset = le64(hdr, 32)
    let stringsSize = le64(hdr, 40)
    let dataOffset = le64(hdr, 48)

    if entryCount <= 0 || entryCount > maxNodes { return (false, false, 0, 0, 0, 0, 0, 0, 0) }
    if entriesOffset != 64 || stringsOffset < entriesOffset { return (false, false, 0, 0, 0, 0, 0, 0, 0) }
    let signedLen64 = stringsOffset + stringsSize
    let sigSize: UInt64 = signed ? 64 : 0
    if dataOffset != signedLen64 + sigSize { return (false, false, 0, 0, 0, 0, 0, 0, 0) }
    if signedLen64 <= 64 || signedLen64 > UInt64(1 << 20) {
        return (false, false, 0, 0, 0, 0, 0, 0, 0)
    }
    return (true, signed, entryCount, entrySize, entriesOffset, stringsOffset,
            stringsSize, dataOffset, Int(signedLen64))
}

func vfsImageReadRange(_ image: Int, _ byteOff: UInt64, _ buf: UnsafeMutableRawPointer?, _ len: UInt32) -> Int32 {
    if image == vfsActiveBaseImage {
        // OS-1: when an A/B update store is in use, the base lives in the selected
        // (coordinated) store slot — read it from the store, not the loader's RAM
        // ramdisk (which is the firmware-staged single base.img, used only when no
        // store is present). H3: otherwise serve from the RAM image the UEFI loader
        // staged (no block driver), falling back to virtio-blk on the `-kernel` path.
        if virtioBlkUsingStore() { return virtioBlkReadRange(byteOff, buf, len) }
        if ramdiskAvailable() { return ramdiskReadRange(byteOff, buf, len) }
        return virtioBlkReadRange(byteOff, buf, len)
    }
    let rawCount = virtioBlkSwosbaseImageCount()
    if image >= 0 && image < rawCount {
        return virtioBlkReadRangeFromImage(image, byteOff, buf, len)
    }
    let storeIndex = image - rawCount
    return pkgStoreReadActivePayloadRange(storeIndex, byteOff, buf, len)
}

// Fixed scratch for streaming content verification off the disk (4 KiB chunk
// per virtio read). SMP: single-CPU kernel today; serialize before S5.
private var vfsVerifyScratch = InlineArray<4096, UInt8>(repeating: 0)

private func packedImageHasPath(_ image: Int, _ target: StaticString) -> Bool {
    if !virtioBlkAvailable() && !ramdiskAvailable() { return false }

    var hdr = [UInt8](repeating: 0, count: 64)
    let hok = hdr.withUnsafeMutableBytes { raw -> Bool in
        vfsImageReadRange(image, 0, raw.baseAddress, 64) == 0
    }
    if !hok { return false }

    return hdr.withUnsafeBufferPointer { hp -> Bool in
        let h = hp.baseAddress!
        let (ok, _, entryCount, entrySize, entriesOffset, stringsOffset, stringsSize, _, _) = readPackedImageHeader(h)
        if !ok { return false }

        var found = false
        target.withUTF8Buffer { targetBuf in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: entrySize) { entry in
                withUnsafeTemporaryAllocation(of: UInt8.self, capacity: targetBuf.count) { path in
                    var k = 0
                    while k < entryCount && !found {
                        let entryOffset = entriesOffset + UInt64(k * entrySize)
                        if vfsImageReadRange(image, entryOffset, entry.baseAddress, UInt32(entrySize)) != 0 {
                            return
                        }
                        let e = entry.baseAddress!
                        let pathOff = Int(le32(e, 0))
                        let pathLen = Int(le32(e, 4))
                        if pathLen == targetBuf.count && UInt64(pathOff + pathLen) <= stringsSize {
                            let pathOffset = stringsOffset + UInt64(pathOff)
                            if vfsImageReadRange(image, pathOffset, path.baseAddress, UInt32(pathLen)) == 0 {
                                if bytesEqual(path.baseAddress!, pathLen, targetBuf.baseAddress!, targetBuf.count) {
                                    found = true
                                }
                            }
                        }
                        k += 1
                    }
                }
            }
        }
        return found
    }
}

/// Build a read-only tree from a packed SWOSBASE image. The metadata buffer
/// (header + entries + string table) is kept permanently: vnode names and signed
/// per-file hashes point straight into it.
private func buildImageFromDisk(_ image: Int, _ root: Int,
                                allowExistingDirs: Bool,
                                requireSigned: Bool) -> Bool {
    if !virtioBlkAvailable() && !ramdiskAvailable() { return false }

    var hdr = [UInt8](repeating: 0, count: 64)
    let hok = hdr.withUnsafeMutableBytes { raw -> Bool in
        vfsImageReadRange(image, 0, raw.baseAddress, 64) == 0
    }
    if !hok { return false }

    return hdr.withUnsafeBufferPointer { hp -> Bool in
        let h = hp.baseAddress!
        let (ok, signed, entryCount, entrySize, entriesOffset, stringsOffset, _, dataOffset, signedLen) =
            readPackedImageHeader(h)
        if !ok { return false }
        if requireSigned && !signed {
            uartPuts("vfs: unsigned base image refused - signed v3 required\n")
            return false
        }

        // Read the metadata range (header + entries + strings). For v3 this is
        // the signed message. For v2 package payloads it is kept so names remain
        // stable for the lifetime of the mount.
        guard let metaRaw = swiftos_kernel_alloc(UInt(signedLen), 16) else { return false }
        let meta = metaRaw.bindMemory(to: UInt8.self, capacity: signedLen)
        if vfsImageReadRange(image, 0, metaRaw, UInt32(signedLen)) != 0 { return false }

        if signed {
            var sig = [UInt8](repeating: 0, count: 64)
            let sok = sig.withUnsafeMutableBytes { raw -> Bool in
                vfsImageReadRange(image, UInt64(signedLen), raw.baseAddress, 64) == 0
            }
            if !sok { return false }
            let sigOK = sig.withUnsafeBytes { sb -> Bool in
                withUnsafeBytes(of: image_trust_root) { tr in
                    ed25519Verify(message: metaRaw, signedLen,
                                  signature: sb.baseAddress!, publicKey: tr.baseAddress!)
                }
            }
            if !sigOK {
                uartPuts("vfs: base image signature INVALID - refusing disk image\n")
                return false
            }
            klog(.info, "vfs", "base image signature verified (ed25519)")
        }

        for k in 0..<entryCount {
            let e = meta + Int(entriesOffset) + k * entrySize
            let pathOff = Int(le32(e, 0))
            let pathLen = Int(le32(e, 4))
            let kind = le32(e, 8)
            let dOff = Int(le64(e, 16))
            let dLen = Int(le64(e, 24))
            let mode = le32(e, 32)
            let owner = le32(e, 36)
            if pathLen <= 0 || Int(stringsOffset) + pathOff + pathLen > signedLen { continue }
            let pathPtr = meta + Int(stringsOffset) + pathOff
            let (parent, leafPtr, leafLen) = resolveBuildParent(root, pathPtr, pathLen)
            if parent < 0 || leafLen <= 0 { continue }
            let existing = findChild(parent, UnsafePointer<UInt8>(bitPattern: leafPtr)!, leafLen)
            if kind == 1 {
                if existing != -1 {
                    if allowExistingDirs && nodes[existing].isDir { continue }
                    return false
                }
                _ = addDiskDir(parent, leafPtr, leafLen, owner, mode)
            } else if kind == 2 {
                if existing != -1 { return false }
                let hashPtr = signed ? UInt(bitPattern: e + 40) : 0
                addDiskFile(parent, leafPtr, leafLen, image, Int(dataOffset) + dOff,
                            dLen, owner, mode, hashPtr)
            }
        }
        return true
    }
}

/// Build the read-only base tree from whichever SWOSBASE image contains the
/// boot shell. QEMU's virtio-mmio scan order is not a package contract, so the
/// VFS chooses by contents. Base images must be signed v3; package overlays may
/// still be v2 because swpkg payloads deliberately keep the v2 layout.
private func buildBaseFromDisk(_ root: Int) -> (mounted: Bool, image: Int) {
    if virtioBlkUsingStore() {
        if buildImageFromDisk(vfsActiveBaseImage, root,
                              allowExistingDirs: false,
                              requireSigned: true) {
            return (true, vfsActiveBaseImage)
        }
        return (false, -1)
    }

    let count = virtioBlkSwosbaseImageCount()
    if count <= 0 {
        if buildImageFromDisk(vfsActiveBaseImage, root,
                              allowExistingDirs: false,
                              requireSigned: true) {
            return (true, vfsActiveBaseImage)
        }
        return (false, -1)
    }
    var image = 0
    while image < count {
        if packedImageHasPath(image, "bin/busybox") || packedImageHasPath(image, "bin/console-login") {
            if buildImageFromDisk(image, root, allowExistingDirs: false, requireSigned: true) {
                return (true, image)
            }
        }
        image += 1
    }
    if count == 1 && buildImageFromDisk(0, root, allowExistingDirs: false, requireSigned: true) {
        return (true, 0)
    }
    return (false, -1)
}

// LM3b: the dedicated model disk is a separate signed SWOSBASE image carrying a
// model bundle, identified by its top-level `MODEL-DISK-ID` sentinel. It is NOT a
// package overlay (which grafts into the root), so it is mounted at its own
// /srv/models mount point instead — see mountModelDiskImage. Returns the swosbase
// image index of the model disk, or -1 if none is attached.
private func findModelDiskImage() -> Int {
    let count = virtioBlkSwosbaseImageCount()
    var image = 0
    while image < count {
        if packedImageHasPath(image, "MODEL-DISK-ID") { return image }
        image += 1
    }
    return -1
}

// LM3b: mount the model disk read-only at /srv/models. Signed-only (same image
// trust root as the base), so only an image-key-signed model disk is accepted; a
// real model that is too big for the RAM-loaded base / the ~4 MiB datafs file cap
// ships this way. No-op when no model disk is attached.
private func mountModelDiskImage(_ root: Int) {
    if virtioBlkUsingStore() { return }
    let image = findModelDiskImage()
    if image < 0 { return }
    let srv = addDir(root, "srv")
    let models = srv >= 0 ? addDir(srv, "models") : -1
    if models >= 0 && buildImageFromDisk(image, models,
                                         allowExistingDirs: false,
                                         requireSigned: true) {
        klog(.info, "vfs", "LM3b: model disk mounted read-only at /srv/models")
    } else {
        klog(.info, "vfs", "LM3b: model disk mount rejected")
    }
}

private func mountPackageImages(_ root: Int, baseImage: Int) {
    let count = virtioBlkSwosbaseImageCount()
    let modelImage = findModelDiskImage()
    if !virtioBlkUsingStore() {
        var image = 0
        while image < count {
            if image != baseImage && image != modelImage {
                if buildImageFromDisk(image, root,
                                      allowExistingDirs: true,
                                      requireSigned: false) {
                    klog(.info, "vfs", "P2: package image mounted", UInt64(image))
                } else {
                    klog(.info, "vfs", "P2: package image rejected", UInt64(image))
                }
            }
            image += 1
        }
    }
    let storeCount = pkgStoreActivePayloadCount()
    var store = 0
    while store < storeCount {
        let storeImage = count + store
        if buildImageFromDisk(storeImage, root,
                              allowExistingDirs: true,
                              requireSigned: false) {
            klog(.info, "pkg", "P3: package store payload mounted", UInt64(store))
        } else {
            klog(.info, "pkg", "P3: package store payload rejected", UInt64(store))
        }
        store += 1
    }
}

/// I8: verify a disk-backed file's content against its signed hash, once per
/// boot (cached in the vnode). Unsigned package payloads are accepted by their
/// package/store verification path and carry hashPtr == 0 here.
private func vfsVerifyNodeContent(_ node: Int) -> Bool {
    if node < 0 || nodes[node].isDir || !nodes[node].onDisk { return true }
    if nodes[node].contentVerified { return true }
    if nodes[node].hashPtr == 0 {
        nodes[node].contentVerified = true
        return true
    }
    guard let expect = UnsafePointer<UInt8>(bitPattern: nodes[node].hashPtr) else { return false }

    var stream = Sha256Stream()
    var remaining = nodes[node].dataLen
    var off = UInt64(nodes[node].diskOffset)
    var ok = true
    withUnsafeMutableBytes(of: &vfsVerifyScratch) { raw in
        let buf = raw.baseAddress!
        while remaining > 0 {
            let chunk = remaining < 4096 ? remaining : 4096
            if vfsImageReadRange(nodes[node].diskImage, off, buf, UInt32(chunk)) != 0 {
                ok = false
                return
            }
            stream.update(buf, chunk)
            remaining -= chunk
            off += UInt64(chunk)
        }
    }
    if !ok { return false }

    var digest = [UInt8](repeating: 0, count: 32)
    digest.withUnsafeMutableBytes { stream.final($0.baseAddress!) }
    var diff: UInt8 = 0
    for i in 0..<32 { diff |= digest[i] ^ expect[i] }
    if diff != 0 {
        uartPuts("vfs: content hash mismatch - rejecting file\n")
        return false
    }
    nodes[node].contentVerified = true
    return true
}

private func registerDevice(_ slot: Int, _ name: StaticString,
                            kind: UInt32, bus: UInt32,
                            mmioBase: UInt = 0, mmioLen: UInt = 0,
                            irq: UInt32 = 0, flags: UInt32,
                            discoverable: Bool = true) {
    if slot < 0 || slot >= maxDevices { return }
    devices[slot] = DeviceGrant(inUse: true, claimed: false,
                                namePtr: UInt(bitPattern: name.utf8Start),
                                nameLen: name.utf8CodeUnitCount,
                                kind: kind, bus: bus,
                                mmioBase: mmioBase, mmioLen: mmioLen,
                                irq: irq, flags: flags,
                                generation: 0, ownerProc: -1,
                                discoverable: discoverable)
}

private func resetDeviceRegistry() {
    for i in 0..<maxDevices { devices[i] = DeviceGrant() }
    let input = virtioInputDiscoverGrant()
    if input.found {
        // C5h: virtio-input.0 now carries the REAL MMIO grant (deviceFlagMmioGrant,
        // no deviceFlagNoMmioGrant). A capConsole claim of it yields a `.map` right,
        // so the supervised userland driver service (/bin/svc-input), receiving the
        // grant over IPC handle transfer, can sys_device_mmap the window Device-nGnRE
        // and read the device's identification/queue registers directly. This is the
        // metadata-only -> hardware-authority transition for the discoverable
        // virtio-input grant. The kernel's polled keyboard driver still touches the
        // same window read-only at C5h; the two mappings coexist (ownership handoff
        // is C5i). See docs/NOTES.md.
        registerDevice(0, "virtio-input.0",
                       kind: deviceKindVirtioInput,
                       bus: deviceBusVirtioMmio,
                       mmioBase: input.mmioBase,
                       mmioLen: input.mmioLen,
                       flags: deviceFlagMmioGrant | deviceFlagDiscovered)
        // C5h: an inert sibling over the SAME transport window, metadata-only
        // (deviceFlagNoMmioGrant), discoverable. It preserves the metadata-only
        // negative-path coverage that virtio-input.0 used to provide before it
        // became mappable: the legacy C5 driver demo (drvsvcdemo/drvinputd) claims
        // and transfers THIS grant to prove authority stays withheld, and the LA2
        // devicemmapprobe claims it to prove sys_device_mmap is refused with EACCES
        // on a no-MMIO grant. (Replaces the former mappable virtio-input-mmio.0
        // alias, whose mappable role virtio-input.0 now fills.)
        registerDevice(1, "virtio-input-meta.0",
                       kind: deviceKindVirtioInput,
                       bus: deviceBusVirtioMmio,
                       mmioBase: input.mmioBase,
                       mmioLen: input.mmioLen,
                       flags: deviceFlagNoMmioGrant | deviceFlagDiscovered)
    } else {
        registerDevice(0, "pseudo-input.0",
                       kind: deviceKindPseudoInput,
                       bus: deviceBusPseudo,
                       flags: deviceFlagNoMmioGrant)
    }
    // NS1: publish a mappable grant for the virtio-net transport window, the first
    // step of network serviceization. A capConsole claimer obtains a `.map` right
    // and can sys_device_mmap the window to read the device identity + config
    // (e.g. the MAC) from userland. This COEXISTS with the in-kernel net driver,
    // which keeps owning and operating the NIC (sshd/nginx/DHCP depend on it): the
    // grant only authorizes mapping, and the userland probe reads read-only
    // registers. NOT discoverable: it is claimed by name (claim-by-name needs no
    // device_discover), and keeping it out of the discovery enumeration preserves
    // the legacy C5 driver demo's "exactly the input devices are discoverable"
    // contract. Making the NIC discoverable (for a userland net service that
    // enumerates NICs) is deferred to a later NS milestone, together with
    // generalizing that demo's discovery bound. Slot 2 keeps the input slots intact.
    let net = virtioNetDiscoverGrant()
    if net.found {
        registerDevice(2, "virtio-net.0",
                       kind: deviceKindVirtioNet,
                       bus: deviceBusVirtioMmio,
                       mmioBase: net.mmioBase,
                       mmioLen: net.mmioLen,
                       flags: deviceFlagMmioGrant,
                       discoverable: false)
    }
    // NS2: when a SECOND virtio-net device is attached, publish it as a drivable
    // grant `virtio-net.1`. The in-kernel net driver always binds the first NIC
    // (ordinal 0), so the userland net driver can fully reset + own the second one
    // (TX/RX from EL0) without disturbing the primary kernel NIC. Absent on the
    // single-NIC production profile, so no userland program touches the live NIC.
    let net2 = virtioNetDiscoverGrant(ordinal: 1)
    if net2.found {
        registerDevice(3, "virtio-net.1",
                       kind: deviceKindVirtioNet,
                       bus: deviceBusVirtioMmio,
                       mmioBase: net2.mmioBase,
                       mmioLen: net2.mmioLen,
                       flags: deviceFlagMmioGrant,
                       discoverable: false)
    }
}

// C5i: does a discovered virtio-input device carry the mappable MMIO grant, i.e.
// is it owned by the userland driver service rather than the in-kernel polled
// driver? Queried once after vfsInit() so the kernel can skip virtioKbdInit() and
// the per-tick poll. True only when a real virtio-input window exists AND it was
// registered mappable (the C5h registry policy). Read under vfsLock like the rest.
func vfsVirtioInputUserlandOwned() -> Bool {
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    for dev in 0..<maxDevices where devices[dev].inUse {
        if devices[dev].kind == deviceKindVirtioInput &&
           (devices[dev].flags & deviceFlagMmioGrant) != 0 &&
           (devices[dev].flags & deviceFlagNoMmioGrant) == 0 {
            return true
        }
    }
    return false
}

func vfsInit() {
    withUnsafeMutablePointer(to: &vfsLockWord) { word in
        smpAtomicStore(word, 0)
    }
    withUnsafeMutablePointer(to: &vfsLockAcquireCount) { count in
        smpAtomicStore(count, 0)
    }
    withUnsafeMutablePointer(to: &vfsLockContentionCount) { count in
        smpAtomicStore(count, 0)
    }

    guard let raw = swiftos_kernel_alloc(UInt(MemoryLayout<VNode>.stride * maxNodes), 16) else {
        uartPuts("panic: vfs node table allocation failed\n")
        while true {}
    }
    nodes = raw.bindMemory(to: VNode.self, capacity: maxNodes)
    nodeCount = 0
    mountedPackageStorePayloads = 0

    let root = allocNode()
    setName(root, "/")
    nodes[root].isDir = true
    nodes[root].parent = root

    // M11c: serve the read-only base from the packed disk image when one is
    // attached; otherwise fall back to the compiled-in literals (the -kernel
    // test paths and UEFI GPT boot, where the disk is not a SWOSBASE image).
    //
    // U1a: if an A/B update-store disk is attached, updateStoreInit picks the
    // active slot and points base reads at it; if that slot's image fails its
    // Ed25519/SHA-256 verification, roll back to the known-good fallback slot
    // and mount that instead (the verified-fallback half of A/B).
    updateStoreInit()
    updateStorePayloadProbe() // U1f: report an attached A/B update payload disk
    var baseMount = buildBaseFromDisk(root)
    var usedFallback = false
    if !baseMount.mounted && virtioBlkUseFallbackBase() {
        uartPuts("update-store: active slot failed verification - rolling back to fallback slot\n")
        baseMount = buildBaseFromDisk(root)
        usedFallback = baseMount.mounted
    }
    if baseMount.mounted {
        klog(.info, "vfs", "M11c: read-only base mounted from disk")
        if virtioBlkUsingStore() {
            if usedFallback { uartPuts("update-store: mounted fallback slot\n") }
            else { uartPuts("update-store: mounted active slot\n") }
        }
        mountPackageImages(root, baseImage: baseMount.image)
        mountModelDiskImage(root)   // LM3b: model bundle disk at /srv/models
    } else {
        let bin = addDir(root, "bin")
        addFile(bin, "ps", "")
        let etc = addDir(root, "etc")
        addFile(etc, "motd", "Welcome to swift-os.\n")
        addFile(etc, "hostname", "swiftos\n")
        addFile(root, "readme.txt", "swift-os read-only base fs\n")
        addFile(root, "hello.txt", "M5 file: hello from VFS read()\n")
    }
    _ = addDir(root, "tmp", readOnly: false)
    let dev = addDir(root, "dev", readOnly: true)
    if dev >= 0 {
        addSpecial(dev, "null", 1)
        addSpecial(dev, "zero", 2)
        addSpecial(dev, "urandom", 3)
        addSpecial(dev, "random", 3)
    }

    // Stamp the base/literal tree (and /tmp) with the boot time, so ls -l shows
    // a real date for read-only files instead of the 1970 epoch. tmpfs nodes
    // created later get their own creation time in createTmpNode.
    let bootTime = rtcNow()
    for i in 0..<nodeCount { nodes[i].mtime = bootTime }

    // D1: mount the persistent /data tier after stamping, so datafs nodes keep
    // their own on-disk mtimes rather than the boot time.
    vfsMountDataFs(root)

    if !vfsEnsureProcessCapacity(processSlotCapacityForSubsystems()) {
        uartPuts("panic: vfs process-state allocation failed\n")
        while true {}
    }
    for p in 0..<maxVFSProcesses {
        setCwdNode(p, root)
        setConfineNode(p, 0)
        clearHandleTable(p)
        vfsGroupLeader[p] = -1
    }
    for i in 0..<maxOpenDescriptions { openDescriptions[i] = OpenDescription() }
    for i in 0..<maxPipes { pipes[i] = Pipe() }
    for i in 0..<maxEvents { eventCounters[i] = EventCounter() }
    for i in 0..<maxEndpoints { resetEndpointSlotForReuse(i) }
    resetDeviceRegistry()
    resetCellRegistry()
}

// C6b: seed the cell table. cells[0] is globalCell (raw 1) — always live and never
// handed out by cell_create; all M0-era and unconfined processes carry this tag.
private func resetCellRegistry() {
    for i in 0..<maxCells { cells[i] = CellSlot() }
    cells[0].inUse = true
    cells[0].generation = 1
}

func vfsMountActivePackageStore() -> Int {
    if nodes == nil { return Errno.invalid.code }
    let rawCount = virtioBlkSwosbaseImageCount()
    let storeCount = pkgStoreActivePayloadCount()
    if storeCount < mountedPackageStorePayloads { return Errno.invalid.code }
    var store = mountedPackageStorePayloads
    while store < storeCount {
        let storeImage = rawCount + store
        if buildImageFromDisk(storeImage, 0,
                              allowExistingDirs: true,
                              requireSigned: false) {
            klog(.info, "pkg", "P3b: package store payload live-mounted", UInt64(store))
            mountedPackageStorePayloads += 1
        } else {
            klog(.info, "pkg", "P3b: package store payload live-mount rejected", UInt64(store))
            return Errno.exists.code
        }
        store += 1
    }
    return 0
}

private func readHandleSpec(_ base: UnsafePointer<UInt8>, _ index: Int) -> HandleSpec {
    let raw = UnsafeRawPointer(base)
    let off = index * handleSpecSize
    return HandleSpec(sourceFD: raw.load(fromByteOffset: off, as: Int32.self),
                      targetFD: raw.load(fromByteOffset: off + 4, as: Int32.self),
                      rightsMask: raw.load(fromByteOffset: off + 8, as: UInt32.self),
                      flags: raw.load(fromByteOffset: off + 12, as: UInt32.self))
}

func vfsValidateHandleInheritance(parent: Int, inherit: HandleInheritance,
                                  specsVA: UInt = 0, specCount: UInt = 0) -> Int {
    if inherit != .explicit { return 0 }
    if !vfsProcessValid(parent) { return Errno.invalid.code }
    if specCount > UInt(maxFDs) { return Errno.invalid.code }
    if specCount == 0 { return 0 }
    guard let specs = userReadableBuffer(specsVA, specCount * UInt(handleSpecSize)) else {
        return Errno.invalid.code
    }

    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    let parentProc = vfsLeader(parent)
    var targetMask: UInt64 = 0
    for i in 0..<Int(specCount) {
        let spec = readHandleSpec(specs, i)
        let src = Int(spec.sourceFD)
        let dst = Int(spec.targetFD)
        if src < 0 || src >= maxFDs || dst < 0 || dst >= maxFDs { return Errno.badFD.code }
        let entry = fdEntry(parentProc, src)
        if !entry.inUse { return Errno.badFD.code }
        if !hasRights(entry.rights, .transfer) { return Errno.access.code }
        if (spec.flags & ~handleSpecFlagCloexec) != 0 { return Errno.invalid.code }
        let bit = UInt64(1) << UInt64(dst)
        if (targetMask & bit) != 0 { return Errno.invalid.code }
        targetMask |= bit
    }
    return 0
}

private func seedExplicitHandles(slot: Int, parent: Int, specsVA: UInt, specCount: UInt) {
    if specCount == 0 { return }
    guard let specs = userReadableBuffer(specsVA, specCount * UInt(handleSpecSize)) else { return }
    let parentProc = vfsLeader(parent)
    for i in 0..<Int(specCount) {
        let spec = readHandleSpec(specs, i)
        let src = Int(spec.sourceFD)
        let dst = Int(spec.targetFD)
        let parentEntry = fdEntry(parentProc, src)
        var childEntry = parentEntry
        childEntry.rights = attenuate(parentEntry.rights, to: Rights(rawValue: spec.rightsMask))
        childEntry.cloexec = (spec.flags & handleSpecFlagCloexec) != 0
        setFDEntry(slot, dst, childEntry)
        retainDescription(childEntry.object)
    }
}

@discardableResult
func vfsProcessInit(slot: Int, parent: Int, inherit: HandleInheritance = .all,
                    specsVA: UInt = 0, specCount: UInt = 0) -> Bool {
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    if !vfsProcessValid(slot) { return false }
    // A process (init / fork child / spawned image) owns its own fd table: it is
    // its own group leader. fork/spawn still COPY the parent's table below — that
    // is correct POSIX (a forked child gets a private copy). Only threads share,
    // via vfsThreadAttach (which bypasses this function).
    vfsGroupLeader[slot] = slot
    guard let table = ensureHandleTable(slot) else { return false }
    for fd in 0..<maxFDs { table[fd] = HandleEntry() }

    if vfsProcessValid(parent) {
        let parentProc = vfsLeader(parent)
        // cwd is always inherited; the handle set depends on the mode. `.all` is
        // the fork/thread case, `.stdioOnly` is legacy spawn compatibility, and
        // `.explicit` starts empty and installs only named handle specs (C2).
        setCwdNode(slot, cwdNode(parentProc))
        setConfineNode(slot, confineNode(parentProc)) // a confined parent's child stays confined
        for fd in 0..<maxFDs {
            let e = handleInheritanceCopiesFD(inherit, fd: fd)
                ? fdEntry(parentProc, fd)
                : HandleEntry()
            table[fd] = e
            if e.inUse { retainDescription(e.object) }
        }
        if inherit == .explicit {
            seedExplicitHandles(slot: slot, parent: parent, specsVA: specsVA, specCount: specCount)
        }
        return true
    }

    setCwdNode(slot, 0)
    setConfineNode(slot, 0)
    if installTTY(slot: slot, fd: 0, readable: true, writable: true) < 0 ||
       installTTY(slot: slot, fd: 1, readable: true, writable: true) < 0 ||
       installTTY(slot: slot, fd: 2, readable: true, writable: true) < 0 {
        releaseHandleTableEntries(slot)
        return false
    }
    return true
}

/// rt-a: attach a new thread to its creator's VFS group so they share ONE fd
/// table, cwd, and confinement. Unlike vfsProcessInit it does NOT copy or retain
/// the leader's handles — the thread holds no fds of its own; every fd/cwd
/// access routes through vfsLeader() to the leader's table. Any old private table
/// for this slot is cleared so a reused slot carries no stale entries.
func vfsThreadAttach(slot: Int, leader: Int) {
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    if !vfsProcessValid(slot) { return }
    let root = vfsProcessValid(leader) ? vfsLeader(leader) : slot
    vfsGroupLeader[slot] = root
    clearHandleTable(slot)
    setCwdNode(slot, 0)
    setConfineNode(slot, 0)
}

func vfsProcessCloseAll(slot: Int) {
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    if !vfsProcessValid(slot) { return }
    // A thread (non-leader) owns no fds — they belong to the shared leader table.
    // Tearing them down here would close fds out from under live sibling threads,
    // so a thread exit only detaches from the group; the leader's exit closes the
    // shared table.
    if vfsGroupLeader[slot] != slot && vfsGroupLeader[slot] >= 0 {
        vfsGroupLeader[slot] = slot
        setCwdNode(slot, 0)
        setConfineNode(slot, 0)
        return
    }
    releaseHandleTableEntries(slot)
    // QW3: owner-based reclaim of any endpoint still tagged to this slot. The FD
    // loop above already reclaimed endpoints reachable via this slot's FDs; this
    // is the deterministic, owner-tagged backstop.
    releaseEndpointsOwnedBy(slot)
    setCwdNode(slot, 0)
    setConfineNode(slot, 0)
    vfsGroupLeader[slot] = slot // reset for slot reuse
}

/// Close the slot's close-on-exec descriptors. Called from execve: POSIX closes
/// FD_CLOEXEC fds across exec, so the shell's relocated/redirect-saved fds (ash
/// duplicates them above 10 with F_DUPFD_CLOEXEC) do not leak into the new image.
func vfsCloseCloexec(slot: Int) {
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    if !vfsProcessValid(slot) { return }
    let proc = vfsLeader(slot)
    guard let table = handleTable(proc) else { return }
    for fd in 0..<maxFDs {
        if table[fd].inUse && table[fd].cloexec {
            releaseDescription(table[fd].object)
            table[fd] = HandleEntry()
        }
    }
}

// ---- name / path helpers --------------------------------------------------

private func currentVFSProcess() -> Int {
    let slot = processCurrentSlot()
    // Resolve to the thread-group leader so all threads share one fd table.
    return (slot >= 0 && slot < maxVFSProcesses) ? vfsLeader(slot) : 0
}

private func cwdNodeForCurrentProcess() -> Int {
    cwdNode(currentVFSProcess())
}

private func confineRootForCurrentProcess() -> Int {
    let slot = processCurrentSlot()
    // Confinement is a group property — resolve to the leader (threads share it).
    return vfsProcessValid(slot) ? confineNode(vfsLeader(slot)) : 0
}

private func fdEntry(_ proc: Int, _ fd: Int) -> HandleEntry {
    guard fd >= 0 && fd < maxFDs, let table = handleTable(proc) else { return HandleEntry() }
    return table[fd]
}

private func setFDEntry(_ proc: Int, _ fd: Int, _ value: HandleEntry) {
    guard fd >= 0 && fd < maxFDs, let table = ensureHandleTable(proc) else { return }
    table[fd] = value
}

private func setFDEntryCloexec(_ proc: Int, _ fd: Int, _ value: Bool) {
    guard fd >= 0 && fd < maxFDs, let table = handleTable(proc) else { return }
    table[fd].cloexec = value
}

private func setFDEntryBadge(_ proc: Int, _ fd: Int, _ badge: UInt32) {
    guard fd >= 0 && fd < maxFDs, let table = handleTable(proc) else { return }
    table[fd].badge = badge
}

private func fdEntryHasRights(_ proc: Int, _ fd: Int, _ required: Rights) -> Bool {
    validFD(proc, fd) && hasRights(fdEntry(proc, fd).rights, required)
}

/// C6a: count the in-use handles a process slot holds. Used by the per-cell
/// resource-accounting aggregate (processCellStat) to charge a process's handle
/// count to its CellId domain. Bounded by maxFDs; safe for any slot index.
func vfsHandleCount(slot: Int) -> Int {
    if !vfsProcessValid(slot) || vfsLeader(slot) != slot { return 0 }
    guard let table = handleTable(slot) else { return 0 }
    var n = 0
    for fd in 0..<maxFDs where table[fd].inUse { n += 1 }
    return n
}

private func nameEquals(_ node: Int, _ ptr: UnsafePointer<UInt8>, _ len: Int) -> Bool {
    if nodes[node].nameLen != len { return false }
    let np = UnsafePointer<UInt8>(bitPattern: nodes[node].namePtr)!
    for i in 0..<len { if np[i] != ptr[i] { return false } }
    return true
}

private func findChild(_ dir: Int, _ ptr: UnsafePointer<UInt8>, _ len: Int) -> Int {
    if len == 1 && ptr[0] == 0x2E { return dir }
    if len == 2 && ptr[0] == 0x2E && ptr[1] == 0x2E { return nodes[dir].parent }
    var c = nodes[dir].firstChild
    while c != -1 {
        if nameEquals(c, ptr, len) { return c }
        c = nodes[c].nextSibling
    }
    return -1
}

private func resolve(_ path: UnsafePointer<UInt8>) -> Int {
    var i = 0
    var cur = path[0] == 0x2F ? 0 : cwdNodeForCurrentProcess()
    while path[i] == 0x2F { i += 1 }
    while path[i] != 0 {
        let start = i
        while path[i] != 0 && path[i] != 0x2F { i += 1 }
        let len = i - start
        if len > 0 {
            if !nodes[cur].isDir { return -1 }
            let child = findChild(cur, path + start, len)
            if child == -1 { return -1 }
            cur = child
        }
        while path[i] == 0x2F { i += 1 }
    }
    return cur
}

private func resolveParent(_ path: UnsafePointer<UInt8>,
                           _ leafStart: inout Int, _ leafLen: inout Int) -> Int {
    var i = 0
    var cur = path[0] == 0x2F ? 0 : cwdNodeForCurrentProcess()
    while path[i] == 0x2F { i += 1 }
    var lastStart = i
    var lastLen = 0
    while path[i] != 0 {
        let start = i
        while path[i] != 0 && path[i] != 0x2F { i += 1 }
        let len = i - start
        var j = i
        while path[j] == 0x2F { j += 1 }
        let more = path[j] != 0
        if len > 0 {
            if more {
                let child = findChild(cur, path + start, len)
                if child == -1 || !nodes[child].isDir { return -1 }
                cur = child
            } else {
                lastStart = start
                lastLen = len
            }
        }
        i = j
    }
    leafStart = lastStart
    leafLen = lastLen
    return lastLen > 0 ? cur : -1
}

private func isDescendant(_ node: Int, of ancestor: Int) -> Bool {
    var n = node
    while n != 0 {
        if n == ancestor { return true }
        n = nodes[n].parent
    }
    return ancestor == 0
}

private func confinedAllows(_ node: Int) -> Bool {
    isDescendant(node, of: confineRootForCurrentProcess())
}

// ---- fd/open-description helpers -----------------------------------------

private func allocFDInProcess(_ proc: Int, from start: Int = 3) -> Int {
    if start < 0 || start >= maxFDs { return -1 }
    if !vfsProcessValid(proc) || handleTable(proc) == nil { return -1 }
    for i in start..<maxFDs where !fdEntry(proc, i).inUse { return i }
    return -1
}

// C7b: would allocating `n` more handles for `proc` exceed its cell's handle cap?
// Returns true (refuse) only for a member of an explicitly capped cell that is at the
// ceiling; globalCell + uncapped cells short-circuit on one integer compare (zero
// cost — no scan). The aggregate is a bounded scan (processCellHandleCount), like the
// C7a page-cap guard. Caller holds vfsLock (reads cells[] without re-locking).
private func cellHandleCapWouldExceed(_ proc: Int, adding n: Int) -> Bool {
    let cellRaw = processCellRawForSlot(proc)
    if cellRaw == globalCell.raw { return false }   // common case: no scan
    let idx = Int(cellRaw) - 1
    guard idx >= 1 && idx < maxCells && cells[idx].inUse else { return false }
    let cap = cells[idx].handleCap
    if cap <= 0 { return false }                     // uncapped cell — unaffected
    return processCellHandleCount(cellRaw) + n > cap
}

// C7b: allocate an fd for a USER-facing handle constructor (open/dup/pipe/socket/
// endpoint/…), enforcing the cell handle cap. Returns a non-negative fd, or a
// negative errno: EMFILE if the proc's cell handle cap is reached, ENOSPC if the fd
// table is full. The delegation paths — the explicit spawn-grant handle install and
// IPC handle transfer — deliberately keep calling allocFDInProcess directly and are
// NOT capped: those are authority handed IN by a supervisor/peer, not the member
// growing its own table. Caller holds vfsLock.
private func allocUserFD(_ proc: Int, from start: Int = 3) -> Int {
    if cellHandleCapWouldExceed(proc, adding: 1) { return Errno.manyFiles.code }
    let fd = allocFDInProcess(proc, from: start)
    return fd < 0 ? Errno.noSpace.code : fd
}

private func allocDescription() -> Int {
    for i in 0..<maxOpenDescriptions where !openDescriptions[i].inUse {
        openDescriptions[i] = OpenDescription()
        openDescriptions[i].inUse = true
        openDescriptions[i].refCount = 1
        return i
    }
    return -1
}

private func retainDescription(_ d: Int) {
    if d >= 0 && d < maxOpenDescriptions && openDescriptions[d].inUse {
        openDescriptions[d].refCount += 1
    }
}

private func releaseDescription(_ d: Int) {
    if d < 0 || d >= maxOpenDescriptions || !openDescriptions[d].inUse { return }
    openDescriptions[d].refCount -= 1
    if openDescriptions[d].refCount > 0 { return }

    let desc = openDescriptions[d]
    if desc.kind == .socket { socketClose(desc.node) }
    if desc.kind == .pipe {
        if desc.pipeEnd == pipeDuplexEnd {
            releasePipeRef(desc.pipe, read: true)
            releasePipeRef(desc.writePipe, read: false)
        } else {
            releasePipeRef(desc.pipe, read: desc.pipeEnd == pipeReadEnd)
        }
    }
    if desc.kind == .endpoint && desc.node >= 0 && desc.node < maxEndpoints && endpoints[desc.node].inUse {
        let ep = desc.node
        if desc.pipeEnd == endpointSendEnd {
            if endpoints[ep].sendRefs > 0 { endpoints[ep].sendRefs -= 1 }
            // QW2: wake any parked receivers when the last sender closes so
            // they return Errno.pipe.code instead of sleeping forever (EOF wake).
            if endpoints[ep].sendRefs == 0 { ipcWakeWaiters(ep) }
        } else {
            if endpoints[ep].recvRefs > 0 { endpoints[ep].recvRefs -= 1 }
            // QW1: when the last receiver closes, no server can reply, so wake
            // any callers parked in ipc_call on a reply port for this endpoint;
            // they re-check recvRefs and return Errno.pipe.code (mirrors the QW2 EOF wake).
            if endpoints[ep].recvRefs == 0 { replyPortsWakeForEndpointEOF(ep) }
        }
        if endpoints[ep].sendRefs == 0 && endpoints[ep].recvRefs == 0 {
            // Balance an in-flight handle that was never received before teardown.
            if endpoints[ep].hasHandle && endpoints[ep].handle.inUse {
                releaseDescription(endpoints[ep].handle.object)
            }
            // Keep the heap-backed message buffer attached to this slot for reuse:
            // the kernel heap is a bump allocator, so dropping bufPtr would leak
            // endpointMsgCap bytes on every create/close cycle.
            resetEndpointSlotForReuse(ep)
        }
    }
    if desc.kind == .event && desc.node >= 0 && desc.node < maxEvents {
        eventCounters[desc.node] = EventCounter()
    }
    if desc.kind == .device {
        releaseDeviceGrant(desc.node)
    }
    // C6b: closing the last cell control handle does NOT free the CellId — a cell
    // outlives its handle and is reclaimed only by explicit teardown (C6d), so a
    // supervisor crash leaves the domain contained + accounted, not silently
    // dissolved. The slot stays cells[node].inUse until cell_destroy. (No-op here.)
    if desc.kind == .ptyMaster { ptyReleaseEnd(desc.pty, master: true) }
    if desc.kind == .ptySlave { ptyReleaseEnd(desc.pty, master: false) }
    openDescriptions[d] = OpenDescription()
}

private func borrowDescriptionForFD(_ proc: Int, _ fd: Int,
                                    required: Rights = Rights())
    -> (err: Int, entry: HandleEntry, descIndex: Int, desc: OpenDescription) {
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    guard fd >= 0 && fd < maxFDs && fdEntry(proc, fd).inUse else {
        return (Errno.badFD.code, HandleEntry(), -1, OpenDescription())
    }
    let entry = fdEntry(proc, fd)
    guard hasRights(entry.rights, required) else {
        return (Errno.access.code, HandleEntry(), -1, OpenDescription())
    }
    let d = entry.object
    guard d >= 0 && d < maxOpenDescriptions && openDescriptions[d].inUse else {
        return (Errno.badFD.code, HandleEntry(), -1, OpenDescription())
    }
    openDescriptions[d].refCount += 1
    return (0, entry, d, openDescriptions[d])
}

private func releaseBorrowedDescription(_ d: Int) {
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    releaseDescription(d)
}

private func borrowSocketForFD(_ proc: Int, _ fd: Int,
                               required: Rights = Rights())
    -> (err: Int, socket: Int, descIndex: Int, flags: Int) {
    let b = borrowDescriptionForFD(proc, fd, required: required)
    if b.err != 0 { return (b.err, -1, -1, 0) }
    guard b.entry.kind == .socket else {
        releaseBorrowedDescription(b.descIndex)
        return (Errno.badFD.code, -1, -1, 0)
    }
    return (0, b.desc.node, b.descIndex, b.desc.flags)
}

private func validFD(_ proc: Int, _ fd: Int) -> Bool {
    fd >= 0 && fd < maxFDs && fdEntry(proc, fd).inUse
}

private func installTTY(slot: Int, fd: Int, readable: Bool, writable: Bool) -> Int {
    let d = allocDescription()
    if d < 0 { return d }
    openDescriptions[d].kind = .tty
    installDescription(slot, fd, d, rights: posixRights(read: readable, write: writable))
    return fd
}

private func installDescription(_ proc: Int, _ fd: Int, _ desc: Int, rights: Rights) {
    let kind = (desc >= 0 && desc < maxOpenDescriptions && openDescriptions[desc].inUse)
        ? openDescriptions[desc].kind
        : HandleKind.none
    setFDEntry(proc, fd, HandleEntry(inUse: true, kind: kind, object: desc, rights: rights))
}

private func posixRights(read: Bool, write: Bool) -> Rights {
    var r = rights(read: read, write: write)
    r.insert(.duplicate)
    r.insert(.transfer)
    r.insert(.getattr)
    r.insert(.setattr)
    return r
}

private func endpointRights(read: Bool, write: Bool) -> Rights {
    var r = rights(read: read, write: write)
    r.insert(.transfer)
    return r
}

// LA2: rights for a freshly claimed device grant. A device with a real MMIO
// window that is not explicitly inert (deviceFlagNoMmioGrant clear, mmioLen != 0)
// is mappable, so its grant carries `.map` (deviceMmioGrantRights). Every other
// device stays metadata-only (inspect + transfer), exactly as before LA2 — so
// the C5f metadata-only contract still holds for virtio-input.0 and pseudo-input.
private func deviceRights(_ dev: Int) -> Rights {
    if devices[dev].mmioLen != 0 && (devices[dev].flags & deviceFlagNoMmioGrant) == 0 {
        return deviceMmioGrantRights()
    }
    return deviceMetadataGrantRights()
}

private func discardUninstalledDescription(_ d: Int) {
    if d >= 0 && d < maxOpenDescriptions {
        openDescriptions[d] = OpenDescription()
    }
}

private func resetEndpointSlotForReuse(_ ep: Int) {
    let bufPtr = endpoints[ep].bufPtr
    endpoints[ep] = Endpoint()
    endpoints[ep].bufPtr = bufPtr
    // QW2: clear all waiter slots so a reused endpoint cannot spuriously wake
    // processes that parked on the old incarnation.
    ipcClearEndpointWaiters(ep)
}

// ---- QW2: endpoint waiter helpers (all callers must hold vfsLock) ----------

// Record process slot as a receiver waiter for ep. Returns true on success,
// false if the per-endpoint waiter array is full (caller falls back to yield).
private func ipcRecordWaiter(_ ep: Int, _ slot: Int32) -> Bool {
    let base = ep * maxRecvWaitersPerEndpoint
    for k in 0..<maxRecvWaitersPerEndpoint {
        if endpointRecvWaiters[base + k] == -1 {
            endpointRecvWaiters[base + k] = slot
            return true
        }
    }
    return false
}

// Clear the record for a specific process slot from ep's waiter list.
private func ipcClearWaiterSlot(_ ep: Int, _ slot: Int32) {
    let base = ep * maxRecvWaitersPerEndpoint
    for k in 0..<maxRecvWaitersPerEndpoint {
        if endpointRecvWaiters[base + k] == slot {
            endpointRecvWaiters[base + k] = -1
        }
    }
}

// Clear all waiter slots for ep (slot reuse / endpoint teardown).
private func ipcClearEndpointWaiters(_ ep: Int) {
    let base = ep * maxRecvWaitersPerEndpoint
    for k in 0..<maxRecvWaitersPerEndpoint {
        endpointRecvWaiters[base + k] = -1
    }
}

// Wake all recorded receiver waiters for ep and clear their slots. Called
// under vfsLock by both ipc_send (message available) and the EOF close path
// (last sender closed). Woken processes re-check hasMsg/sendRefs under lock;
// spurious wakes are safe because the recv loop always re-validates.
private func ipcWakeWaiters(_ ep: Int) {
    let base = ep * maxRecvWaitersPerEndpoint
    for k in 0..<maxRecvWaitersPerEndpoint {
        let slot = endpointRecvWaiters[base + k]
        if slot >= 0 {
            endpointRecvWaiters[base + k] = -1
            processWakeFromFutex(Int(slot))
        }
    }
}

/// Drop any endpoint waiter records for an exiting process slot, mirroring
/// futexForgetSlot. Called from process teardown alongside futexForgetSlot.
func ipcForgetSlot(_ slot: Int) {
    let daif = vfsLock()
    for ep in 0..<maxEndpoints {
        ipcClearWaiterSlot(ep, Int32(slot))
    }
    vfsUnlock(daif)
}

// ---- QW1: reply-port helpers (all callers must hold vfsLock) ---------------

// The token is opaque to userland: (generation << 32) | (index + 1). The +1
// keeps 0 reserved as the "no reply" sentinel, and the generation makes a freed
// port's token fail revalidation after the slot is reused.
private func replyPortToken(_ pr: Int) -> UInt64 {
    (UInt64(replyPorts[pr].generation) << 32) | UInt64(pr + 1)
}

// Decode a token to its reply-port index, or -1 if it is the sentinel, out of
// range, names a free port, or fails the generation check (stale/forged).
private func decodeReplyPort(_ token: UInt64) -> Int {
    if token == 0 { return -1 }
    let idx = Int(token & 0xFFFF_FFFF) - 1
    if idx < 0 || idx >= maxReplyPorts || !replyPorts[idx].inUse { return -1 }
    if replyPorts[idx].generation != UInt32(truncatingIfNeeded: token >> 32) { return -1 }
    return idx
}

// Mint a reply port for `ep`, owned by caller scheduler slot `callerSlot`. The
// 256-byte buffer is allocated lazily once and kept attached to the slot across
// free (mirrors allocEndpoint), so the hot path never calls swiftos_kernel_alloc.
private func allocReplyPort(endpoint ep: Int, callerSlot: Int) -> Int {
    for i in 0..<maxReplyPorts where !replyPorts[i].inUse {
        var bufPtr = replyPorts[i].bufPtr
        if bufPtr == 0 {
            guard let buf = swiftos_kernel_alloc(UInt(endpointMsgCap), 16) else { return -1 }
            bufPtr = UInt(bitPattern: buf)
        }
        let gen = replyPorts[i].generation &+ 1
        replyPorts[i] = ReplyPort()
        replyPorts[i].inUse = true
        replyPorts[i].bufPtr = bufPtr
        replyPorts[i].generation = gen
        replyPorts[i].endpoint = ep
        replyPorts[i].callerSlot = callerSlot
        return i
    }
    return -1
}

// Release a reply port. Keeps the buffer and generation for reuse (bumped on the
// next alloc). `releaseHandle` MUST be true when the port still holds a moved
// handle that no one has collected (caller died after a server reply) so the
// underlying description ref is balanced; it is false on the normal collect path
// where ipc_call already installed the handle into a fresh fd before freeing.
private func freeReplyPort(_ pr: Int, releaseHandle: Bool = false) {
    if pr < 0 || pr >= maxReplyPorts { return }
    if releaseHandle && replyPorts[pr].hasHandle && replyPorts[pr].handle.inUse {
        releaseDescription(replyPorts[pr].handle.object)
    }
    let bufPtr = replyPorts[pr].bufPtr
    let gen = replyPorts[pr].generation
    replyPorts[pr] = ReplyPort()
    replyPorts[pr].bufPtr = bufPtr
    replyPorts[pr].generation = gen
}

// Wake every caller parked on a reply port for `ep` after the last receiver
// closes (recvRefs == 0): no server can ever reply, so the woken caller re-checks
// recvRefs under lock and returns Errno.pipe.code, then frees its own port. We only wake
// here (never free) to keep reply-port ownership with the caller.
private func replyPortsWakeForEndpointEOF(_ ep: Int) {
    for i in 0..<maxReplyPorts where replyPorts[i].inUse && replyPorts[i].endpoint == ep {
        let slot = replyPorts[i].callerSlot
        if slot >= 0 { processWakeFromFutex(slot) }
    }
}

// Reclaim any reply port owned by an exiting caller slot, mirroring
// ipcForgetSlot. A server reply that lands after this finds a stale token and is
// rejected (Errno.invalid.code) — never a dangling callerSlot. Releases an uncollected
// reply handle so its description ref is balanced.
func replyPortForgetSlot(_ slot: Int) {
    let daif = vfsLock()
    for i in 0..<maxReplyPorts where replyPorts[i].inUse && replyPorts[i].callerSlot == slot {
        freeReplyPort(i, releaseHandle: true)
    }
    vfsUnlock(daif)
}

private func discardEndpoint(_ ep: Int) {
    if ep >= 0 && ep < maxEndpoints {
        resetEndpointSlotForReuse(ep)
    }
}

/// QW3: belt-and-suspenders owner-based endpoint reclaim for a dying process.
/// The FD-close loop in vfsProcessCloseAll already releases endpoints whose ends
/// were all FDs of this slot; this sweep additionally tears down any endpoint
/// still tagged as owned by the slot, using the exact primitives the FD path
/// uses. The caller MUST already hold vfsLock (matches vfsProcessCloseAll). It is
/// idempotent: endpoints reclaimed by the FD loop are no longer inUse, so they
/// are skipped here.
private func releaseEndpointsOwnedBy(_ slot: Int) {
    for i in 0..<maxEndpoints where endpoints[i].inUse && endpoints[i].ownerProc == slot {
        // Balance an in-flight handle that was never received before teardown,
        // exactly as releaseDescription's endpoint branch does.
        if endpoints[i].hasHandle && endpoints[i].handle.inUse {
            releaseDescription(endpoints[i].handle.object)
        }
        // Keep the bump-allocated bufPtr attached to the slot for reuse; reset
        // clears ownerProc back to -1 along with the rest of the slot state.
        resetEndpointSlotForReuse(i)
    }
}

/// Kernel-internal observability: count endpoint slots currently in use. Used by
/// the QW3 orphan-reap self-test to assert endpoint slot reuse stays stable
/// across orphan churn (no ABI / syscall surface).
func vfsEndpointInUseCount() -> Int {
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    var n = 0
    for i in 0..<maxEndpoints where endpoints[i].inUse { n += 1 }
    return n
}

private func rollbackEndpointCreate(proc: Int, sfd: Int, rfd: Int,
                                    endpoint ep: Int, sendDesc sd: Int, recvDesc rd: Int) {
    if sfd >= 0 && sfd < maxFDs { setFDEntry(proc, sfd, HandleEntry()) }
    if rfd >= 0 && rfd < maxFDs { setFDEntry(proc, rfd, HandleEntry()) }
    discardUninstalledDescription(sd)
    discardUninstalledDescription(rd)
    discardEndpoint(ep)
}

private func releaseDeviceGrant(_ dev: Int) {
    if dev < 0 || dev >= maxDevices || !devices[dev].inUse { return }
    devices[dev].claimed = false
    devices[dev].ownerProc = -1
}

// C6b: rights a cell control handle carries. `.write` is the authority to mutate
// the cell — add a member via cell_spawn today, tear it down in C6d. `.duplicate`/
// `.transfer` let a supervisor hand the control handle to a sub-supervisor. There
// is no `.read` byte stream (a cell is not readable); cell_stat is keyed on the
// CellId and gated separately by capProcessInspect.
private func cellControlRights() -> Rights { [.write, .duplicate, .transfer] }

// C6b/C6c/C6d: SYS_cell_create — allocate a fresh CellId and return a `.cell`
// control handle fd for it. capConsole-gated: creating an isolation/accounting
// domain is a privileged supervisor operation (the same gate as device_claim /
// tty_inject). `rootVA` (C6c) names the cell's VFS namespace root: NULL or "/"
// leaves the cell unconfined (like globalCell); any other path is resolved (against
// the caller's own namespace) to a directory the cell's processes are confined to.
// `pageCap` (C6d/C7a) is an optional hard resident-page ceiling (0 = unlimited);
// `handleCap` (C7b) is an optional hard handle ceiling (0 = unlimited). Writes the new
// CellId raw to *outIdVA (4 bytes) when non-NULL so the caller can query the domain via
// cell_stat. The cell persists until explicit teardown (cell_destroy, C6d); closing the
// control handle does NOT free it.
func vfsCellCreate(root rootVA: UInt, pageCap: UInt, handleCap: UInt, outId outVA: UInt) -> Int {
    if (processCurrentCaps() & capConsole) == 0 { return Errno.access.code }
    let out: UnsafeMutablePointer<UInt8>?
    if outVA == 0 {
        out = nil
    } else {
        guard let buf = userWritableBuffer(outVA, 4) else { return Errno.invalid.code }
        out = buf
    }
    // A NULL or "/" path means unconfined (root node 0); any other path is resolved
    // to a directory node under the lock (resolve() expects vfsLock held, as in
    // vfsConfine), and is validated before we allocate the cell.
    let wantRoot = rootVA != 0
    var rootPath: UnsafePointer<UInt8>? = nil
    if wantRoot {
        guard let p = userCString(rootVA) else { return Errno.invalid.code }
        rootPath = p
    }

    let proc = currentVFSProcess()
    let daif = vfsLock()
    defer { vfsUnlock(daif) }

    var rootNode = 0
    if let rp = rootPath, !(rp[0] == 0x2F && rp[1] == 0) { // not just "/"
        let node = resolve(rp)
        if node == -1 { return Errno.noEntry.code }      // ENOENT
        if !nodes[node].isDir { return Errno.notDir.code } // ENOTDIR
        rootNode = node
    }

    var slot = -1
    for i in 1..<maxCells where !cells[i].inUse { slot = i; break }
    if slot < 0 { return Errno.noSpace.code } // ENOSPC: cell table full

    let fd = allocFDInProcess(proc, from: 3)
    if fd < 0 { return Errno.noSpace.code }
    let d = allocDescription()
    if d < 0 { return Errno.noSpace.code }

    cells[slot].inUse = true
    cells[slot].generation &+= 1
    cells[slot].ownerProc = proc
    cells[slot].root = rootNode
    cells[slot].pageCap = pageCap > UInt(Int.max) ? Int.max : Int(pageCap)
    cells[slot].handleCap = handleCap > UInt(Int.max) ? Int.max : Int(handleCap)
    openDescriptions[d].kind = .cell
    openDescriptions[d].node = slot
    // C6d: stamp the cell generation into the description so a handle that outlives a
    // cell_destroy + slot reuse resolves stale (never to the new tenant of the slot).
    openDescriptions[d].offset = Int(cells[slot].generation)
    installDescription(proc, fd, d, rights: cellControlRights())
    if let outBuf = out {
        UnsafeMutableRawPointer(outBuf).storeBytes(of: UInt32(slot + 1), toByteOffset: 0, as: UInt32.self)
    }
    return fd
}

// C6c: apply a cell's namespace root to a freshly spawned member. Called from the
// spawn-into-cell path after the child inherits the parent's VFS state; if the cell
// is confined (root != 0) it overrides the child's C3 confine root + cwd so the
// child resolves `/` within the subtree and cannot escape it. An unconfined cell
// (root 0) leaves the inherited (unconfined) namespace untouched.
func vfsApplyCellNamespace(slot childSlot: Int, cellRaw: UInt32) {
    let idx = Int(cellRaw) - 1
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    guard idx >= 1 && idx < maxCells && cells[idx].inUse else { return }
    guard childSlot >= 0 && childSlot < maxVFSProcesses else { return }
    let root = cells[idx].root
    if root != 0 {
        let childProc = vfsLeader(childSlot)
        setConfineNode(childProc, root)
        setCwdNode(childProc, root)
    }
}

// C6b/C6d: resolve a fd the caller claims is a cell control handle into the CellId
// raw it names, enforcing authority-by-handle for cell_spawn / cell_pids /
// cell_destroy. Returns the raw (>= 2, since globalCell is never created) on success,
// or a negative errno: EBADF if the fd is not a live `.cell` handle, EACCES if it
// lacks the `.write` (mutate) right, EINVAL if the cell slot is freed or the handle
// is stale (its stamped generation no longer matches — the slot was reused by a
// later cell_create). The caller must hold the handle — a process that was never
// given it cannot name the cell.
private func cellRawForControlHandleLocked(_ proc: Int, _ fd: Int) -> Int {
    guard fd >= 0 && fd < maxFDs && fdEntry(proc, fd).inUse else { return Errno.badFD.code }
    let entry = fdEntry(proc, fd)
    guard entry.kind == .cell else { return Errno.badFD.code }
    if !hasRights(entry.rights, .write) { return Errno.access.code }
    let d = entry.object
    guard d >= 0 && d < maxOpenDescriptions && openDescriptions[d].inUse
          && openDescriptions[d].kind == .cell else { return Errno.invalid.code }
    let slot = openDescriptions[d].node
    guard slot >= 1 && slot < maxCells && cells[slot].inUse else { return Errno.invalid.code }
    guard openDescriptions[d].offset == Int(cells[slot].generation) else { return Errno.invalid.code }
    return slot + 1 // CellId raw
}

func vfsCellResolveControl(fd: Int) -> Int {
    let proc = currentVFSProcess()
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    return cellRawForControlHandleLocked(proc, fd)
}

// C6d: the hard resident-page cap of a cell (0 = unlimited / unknown cell). Used by
// the spawn-into-cell path to refuse a new member past the ceiling.
func vfsCellPageCap(cellRaw: UInt32) -> Int {
    let idx = Int(cellRaw) - 1
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    guard idx >= 1 && idx < maxCells && cells[idx].inUse else { return 0 }
    return cells[idx].pageCap
}

// C6d: free a cell's CellId, the final step of teardown. The caller (cell_destroy)
// must have already confirmed via the control handle that it owns the cell AND that
// the cell has no live member processes. Bumps the generation so the now-dangling
// control handle(s) resolve stale, then clears the slot for reuse. Returns 0, or a
// negative errno if `fd` is not a valid control handle for a live cell.
func vfsCellFree(fd: Int) -> Int {
    let proc = currentVFSProcess()
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    let raw = cellRawForControlHandleLocked(proc, fd)
    if raw < 0 { return raw }
    let slot = raw - 1
    // Advance the generation PAST this handle's stamp before clearing the slot, so
    // the now-dangling handle (and any dup) resolves stale even after the slot is
    // re-allocated. Generation is monotonic across free/reuse — never reset.
    let nextGen = cells[slot].generation &+ 1
    cells[slot] = CellSlot()           // inUse = false, root/cap cleared
    cells[slot].generation = nextGen
    return 0
}

private func deviceNameMatches(_ dev: Int, _ name: UnsafePointer<UInt8>) -> Bool {
    if dev < 0 || dev >= maxDevices || !devices[dev].inUse { return false }
    let len = devices[dev].nameLen
    guard let expected = UnsafePointer<UInt8>(bitPattern: devices[dev].namePtr) else { return false }
    var i = 0
    while i < len {
        if name[i] != expected[i] { return false }
        i += 1
    }
    return name[len] == 0
}

private func findDeviceByName(_ name: UnsafePointer<UInt8>) -> Int {
    for i in 0..<maxDevices where deviceNameMatches(i, name) { return i }
    return -1
}

private func writeDeviceInfoLocked(_ dev: Int, _ out: UnsafeMutablePointer<UInt8>) {
    for i in 0..<Int(deviceInfoSize) { out[i] = 0 }
    let raw = UnsafeMutableRawPointer(out)
    raw.storeBytes(of: devices[dev].kind, toByteOffset: 0, as: UInt32.self)
    raw.storeBytes(of: devices[dev].bus, toByteOffset: 4, as: UInt32.self)
    raw.storeBytes(of: UInt64(devices[dev].mmioBase), toByteOffset: 8, as: UInt64.self)
    raw.storeBytes(of: UInt64(devices[dev].mmioLen), toByteOffset: 16, as: UInt64.self)
    raw.storeBytes(of: devices[dev].irq, toByteOffset: 24, as: UInt32.self)
    raw.storeBytes(of: devices[dev].flags, toByteOffset: 28, as: UInt32.self)
    raw.storeBytes(of: devices[dev].generation, toByteOffset: 32, as: UInt32.self)
    raw.storeBytes(of: devices[dev].claimed ? UInt32(1) : UInt32(0),
                   toByteOffset: 36, as: UInt32.self)
    if let name = UnsafePointer<UInt8>(bitPattern: devices[dev].namePtr) {
        var n = devices[dev].nameLen
        if n >= deviceInfoNameCap { n = deviceInfoNameCap - 1 }
        for i in 0..<n { out[deviceInfoNameOffset + i] = name[i] }
        out[deviceInfoNameOffset + n] = 0
    }
}

// ---- kernel-internal handle API (C1) --------------------------------------
//
// The handle-generic operations from docs/CAPABILITIES.md §2. These are not yet
// wired to syscalls (the POSIX dup/dup2/fcntl/close paths above still do that);
// later milestones (C2+) call these to manipulate handles directly, with
// per-handle rights and attenuation.

/// The rights the holder has on the handle at `(proc, fd)`, or empty if invalid.
func handleRights(_ proc: Int, _ fd: Int) -> Rights {
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    return validFD(proc, fd) ? fdEntry(proc, fd).rights : Rights()
}

/// Duplicate a handle into the lowest free slot, sharing the same underlying
/// description/offset, with rights attenuated to (at most) `mask`. The new
/// handle can never hold more authority than the source. Returns the new fd or
/// a negative error.
func handleDuplicate(_ proc: Int, _ fd: Int, mask: Rights) -> Int {
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    guard validFD(proc, fd) else { return Errno.badFD.code }
    guard fdEntryHasRights(proc, fd, .duplicate) else { return Errno.access.code }
    let newfd = allocUserFD(proc, from: 0)   // C7b: cell handle cap (EMFILE)
    if newfd < 0 { return newfd }
    let d = fdEntry(proc, fd).object
    retainDescription(d)
    installDescription(proc, newfd, d, rights: attenuate(fdEntry(proc, fd).rights, to: mask))
    return newfd
}

/// Close the handle at `(proc, fd)`, dropping its reference to the underlying
/// object. vfsClose is the current-process view of this.
func handleClose(_ proc: Int, _ fd: Int) -> Int {
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    guard fd >= 0 && fd < maxFDs && fdEntry(proc, fd).inUse else { return Errno.badFD.code }
    releaseDescription(fdEntry(proc, fd).object)
    setFDEntry(proc, fd, HandleEntry())
    return 0
}

// ---- tmpfs node helpers ---------------------------------------------------

private func createTmpNode(_ parent: Int, _ namePtr: UnsafePointer<UInt8>, _ nameLen: Int,
                           isDir: Bool) -> Int {
    if nodeCount >= maxNodes || nameLen <= 0 { return -1 }
    let n = allocNode()
    if n < 0 { return -1 }
    if !setNameCopy(n, namePtr, nameLen) { return -1 }
    nodes[n].isDir = isDir
    nodes[n].readOnly = false
    // M13c: a tmpfs node is owned by the principal that created it, so `ls -l`
    // reflects who wrote the file (the live login context, not always root).
    nodes[n].owner = processCurrentPrincipal()
    nodes[n].mode = isDir ? 0o755 : 0o644
    nodes[n].mtime = rtcNow()
    if !isDir {
        let cap = 4096
        guard let dataBuf = swiftos_kernel_alloc(UInt(cap), 16) else { return -1 }
        nodes[n].dataPtr = UInt(bitPattern: dataBuf)
        nodes[n].dataLen = 0
        nodes[n].dataCap = cap
    }
    linkChild(parent, n)
    return n
}

private func ensureTmpFileCapacity(_ node: Int, _ needed: Int) -> Bool {
    if needed <= nodes[node].dataCap { return true }
    var cap = nodes[node].dataCap
    if cap < 4096 { cap = 4096 }
    while cap < needed {
        let next = cap * 2
        if next <= cap { return false }
        cap = next
    }
    guard let dataBuf = swiftos_kernel_alloc(UInt(cap), 16) else { return false }
    let dst = dataBuf.bindMemory(to: UInt8.self, capacity: cap)
    if nodes[node].dataLen > 0 {
        let src = UnsafePointer<UInt8>(bitPattern: nodes[node].dataPtr)!
        var i = 0
        while i < nodes[node].dataLen {
            dst[i] = src[i]
            i += 1
        }
    }
    nodes[node].dataPtr = UInt(bitPattern: dataBuf)
    nodes[node].dataCap = cap
    return true
}

// ---- datafs (/data) integration (D1) --------------------------------------

// Create a persistent /data node (file or dir) under a datafs-backed parent,
// allocating both the on-disk inode and its mirror VNode.
private func createDataFsNode(_ parent: Int, _ namePtr: UnsafePointer<UInt8>, _ nameLen: Int,
                              isDir: Bool) -> Int {
    if nodeCount >= maxNodes || nameLen <= 0 { return -1 }
    let vol = nodes[parent].dfsVolume
    let mode: UInt32 = isDir ? 0o755 : 0o644
    let ino = datafsCreate(vol, nodes[parent].dfsInode, namePtr, nameLen, isDir: isDir, mode: mode)
    if ino < 0 { return -1 }
    let n = allocNode()
    if n < 0 { _ = datafsRemove(vol, ino); return -1 }
    if !setNameCopy(n, namePtr, nameLen) { _ = datafsRemove(vol, ino); return -1 }
    nodes[n].isDir = isDir
    nodes[n].readOnly = false
    nodes[n].dataFs = true
    nodes[n].dfsInode = ino
    nodes[n].dfsVolume = vol
    nodes[n].owner = processCurrentPrincipal()
    nodes[n].mode = mode
    nodes[n].mtime = rtcNow()
    nodes[n].dataLen = 0
    linkChild(parent, n)
    return n
}

// Build mirror VNodes for every datafs inode whose parent is `parentInode`,
// recursing into directories. Called once per directory at mount.
private func datafsMirror(_ vol: Int, _ parentVNode: Int, _ parentInode: Int) {
    var nameBuf = [UInt8](repeating: 0, count: 128)
    let count = datafsInodeCount()
    var ino = 0
    while ino < count {
        if ino != datafsRootInode() && datafsInodeUsed(vol, ino) && datafsInodeParent(vol, ino) == parentInode {
            let isDir = datafsInodeIsDir(vol, ino)
            let n = allocNode()
            if n >= 0 {
                let nl = nameBuf.withUnsafeMutableBufferPointer {
                    datafsInodeNameCopy(vol, ino, $0.baseAddress!, $0.count)
                }
                _ = nameBuf.withUnsafeBufferPointer { setNameCopy(n, $0.baseAddress!, nl) }
                nodes[n].isDir = isDir
                nodes[n].readOnly = false
                nodes[n].dataFs = true
                nodes[n].dfsInode = ino
                nodes[n].dfsVolume = vol
                nodes[n].dataLen = datafsInodeSize(vol, ino)
                nodes[n].mode = datafsInodeMode(vol, ino)
                nodes[n].mtime = datafsInodeMtime(vol, ino)
                linkChild(parentVNode, n)
                if isDir { datafsMirror(vol, n, ino) }
            }
        }
        ino += 1
    }
}

// D1: format-if-needed, mount the data disk's datafs, and mirror its tree under
// /data. Called from vfsInit after the base + /tmp are set up.
private let manifestCap = 1024
private var vfsManifestBuf: UInt = 0   // heap buffer for the /data mount manifest

private func vfsMountDataFs(_ root: Int) {
    if !virtioBlkDataAvailable() { return }
    let n = virtioBlkDataVolumeCount()

    // Choose the root /data disk by IDENTITY, not scan order, so /data is
    // deterministic when extra disks / Hetzner Volumes attach in any order.
    //   V2c: if the kernel cmdline pins a root UUID, match the disk carrying it;
    //        on first boot (no match), format the first blank UNLABELED disk as the
    //        root, stamping the pinned UUID.
    //   V2a: otherwise the root is the first UNLABELED datafs disk.
    var rootOrd = -1
    var i = 0
    if datafsRootUuidSet {
        i = 0
        while i < n {
            let u = datafsPeekUuid(virtioBlkDataDeviceIndexAt(i))
            if u.formatted && u.lo == datafsRootUuidLo && u.hi == datafsRootUuidHi { rootOrd = i; break }
            i += 1
        }
        if rootOrd < 0 {
            i = 0
            while i < n {
                let dev = virtioBlkDataDeviceIndexAt(i)
                if !datafsPeekUuid(dev).formatted {   // blank disk -> candidate root
                    var lbl = [UInt8](repeating: 0, count: 32)
                    let ll = lbl.withUnsafeMutableBufferPointer { datafsPeekLabel(dev, $0.baseAddress!, $0.count) }
                    if ll == 0 { rootOrd = i; break }
                }
                i += 1
            }
        }
    }
    if rootOrd < 0 {
        i = 0
        while i < n {
            var lbl = [UInt8](repeating: 0, count: 32)
            let ll = lbl.withUnsafeMutableBufferPointer {
                datafsPeekLabel(virtioBlkDataDeviceIndexAt(i), $0.baseAddress!, $0.count)
            }
            if ll == 0 { rootOrd = i; break }
            i += 1
        }
    }
    if rootOrd < 0 { rootOrd = 0 }

    let rootDev = virtioBlkDataDeviceIndexAt(rootOrd)
    let rootOK = datafsRootUuidSet
        ? datafsMount(0, rootDev, pinnedLo: datafsRootUuidLo, pinnedHi: datafsRootUuidHi, usePinned: true)
        : datafsMount(0, rootDev)
    if !rootOK { uartPuts("D1: datafs mount failed\n"); return }
    uartPuts("V2c root: uuid=")
    uartPutUInt(datafsVolumeUuidLo(0))
    uartPuts(":")
    uartPutUInt(datafsVolumeUuidHi(0))
    uartPuts("\n")
    let data = addDir(root, "data", readOnly: false)
    if data < 0 { return }
    nodes[data].dataFs = true
    nodes[data].dfsInode = datafsRootInode()
    nodes[data].dfsVolume = 0
    nodes[data].mode = 0o755
    datafsMirror(0, data, datafsRootInode())
    uartPuts("D1 OK: datafs mounted at /data\n")

    if n <= 1 { return }

    // V2b: the mount table lives on the just-mounted /data volume. When present it
    // is authoritative — each labeled disk mounts at the mountpoint the manifest
    // assigns to its label, and a disk whose label is not listed is left
    // unmounted. With no manifest, fall back to the V2a default (auto-mount every
    // labeled disk at /mnt/<label>, unlabeled extras at /mnt/data<slot>).
    let mlen = readMountManifest()
    if mlen > 0 { uartPuts("V2 OK: mount manifest applied\n") }

    let mnt = addDir(root, "mnt", readOnly: false)
    if mnt < 0 { return }
    nodes[mnt].mode = 0o755

    var slot = 1
    i = 0
    while i < n {
        if i == rootOrd { i += 1; continue }
        let dev = virtioBlkDataDeviceIndexAt(i)
        var lbl = [UInt8](repeating: 0, count: 32)
        let ll = lbl.withUnsafeMutableBufferPointer { datafsPeekLabel(dev, $0.baseAddress!, $0.count) }
        var nameBuf = [UInt8](repeating: 0, count: 32)
        var nameLen = 0
        var skip = false
        if mlen > 0 {
            if ll == 0 {
                skip = true                       // unlabeled disk in manifest mode → not mounted
            } else {
                nameLen = lbl.withUnsafeBufferPointer { lp in
                    nameBuf.withUnsafeMutableBufferPointer { nb in
                        manifestMountpoint(vfsManifestBuf, mlen, lp.baseAddress!, ll, nb.baseAddress!, nb.count)
                    }
                }
                if nameLen == 0 { skip = true }   // label not listed in the manifest
                else if nameLen < 0 { uartPuts("V2: manifest mountpoint refused (not /mnt/<name>)\n"); skip = true }
            }
        } else if ll > 0 {
            nameLen = ll
            var k = 0; while k < ll { nameBuf[k] = lbl[k]; k += 1 }
        } else {
            let fb: StaticString = slot == 1 ? "data1" : (slot == 2 ? "data2" : "data3")
            fb.withUTF8Buffer { b in nameLen = b.count; var k = 0; while k < b.count { nameBuf[k] = b[k]; k += 1 } }
        }
        if !skip {
            let mounted = nameBuf.withUnsafeBufferPointer { mountVolumeAt(mnt, slot, dev, $0.baseAddress!, nameLen) }
            if mounted { slot += 1 }
        }
        i += 1
    }
}

// V2b: read the mount manifest (/data/.system/mounts) — a datafs file on the
// just-mounted /data volume — into the shared buffer. Returns its length (0 if
// absent/empty).
private func readMountManifest() -> Int {
    if vfsManifestBuf == 0 {
        guard let p = swiftos_kernel_alloc(UInt(manifestCap), 1) else { return 0 }
        vfsManifestBuf = UInt(bitPattern: p)
    }
    let path: StaticString = "/data/.system/mounts"
    var name = [UInt8](repeating: 0, count: path.utf8CodeUnitCount + 1)
    path.withUTF8Buffer { b in for i in 0..<b.count { name[i] = b[i] } }
    return name.withUnsafeBufferPointer { bp -> Int in
        let node = resolve(bp.baseAddress!)
        if node < 0 || nodes[node].isDir || !nodes[node].dataFs { return 0 }
        var len = nodes[node].dataLen
        if len <= 0 { return 0 }
        if len > manifestCap { len = manifestCap }
        let got = datafsRead(nodes[node].dfsVolume, nodes[node].dfsInode, 0,
                             UnsafeMutableRawPointer(bitPattern: vfsManifestBuf)!, len)
        return got > 0 ? got : 0
    }
}

// V2b: validate that [start, start+len) is exactly "/mnt/<name>" with a single,
// path-safe name component (guardrail: data-driven mounts only land under /mnt,
// never over /bin, /etc, ...). On success copy <name> to out, return its length;
// otherwise return -1 (refused).
private func validateMountpoint(_ p: UnsafePointer<UInt8>, _ start: Int, _ len: Int,
                                _ out: UnsafeMutablePointer<UInt8>, _ outMax: Int) -> Int {
    let prefix: StaticString = "/mnt/"
    var ok = true
    var pl = 0
    prefix.withUTF8Buffer { b in
        pl = b.count
        if len <= b.count { ok = false; return }
        var k = 0
        while k < b.count { if p[start + k] != b[k] { ok = false; return }; k += 1 }
    }
    if !ok { return -1 }
    let nameStart = start + pl
    let nameLen = len - pl
    if nameLen <= 0 || nameLen > outMax { return -1 }
    var k = 0
    while k < nameLen {
        let c = p[nameStart + k]
        if c == UInt8(ascii: "/") || c < 0x21 || c > 0x7e { return -1 } // single, path-safe component
        out[k] = c
        k += 1
    }
    return nameLen
}

// V2b: look up `label` in the manifest text. Each non-comment line is
// `<label> <mountpoint>`. Returns the /mnt/<name> component length (copied into
// out), 0 if the label is absent, or -1 if listed but the mountpoint is refused.
private func manifestMountpoint(_ buf: UInt, _ mlen: Int,
                                _ label: UnsafePointer<UInt8>, _ labelLen: Int,
                                _ out: UnsafeMutablePointer<UInt8>, _ outMax: Int) -> Int {
    guard let p = UnsafePointer<UInt8>(bitPattern: buf) else { return 0 }
    var i = 0
    while i < mlen {
        while i < mlen && (p[i] == 0x20 || p[i] == 0x09) { i += 1 }   // leading blanks
        let lineStart = i
        var e = i
        while e < mlen && p[e] != 0x0a { e += 1 }                     // to end-of-line
        if lineStart < e && p[lineStart] != UInt8(ascii: "#") {
            var t = lineStart
            while t < e && p[t] != 0x20 && p[t] != 0x09 { t += 1 }    // token0 = label
            if t - lineStart == labelLen {
                var same = true
                var k = 0
                while k < labelLen { if p[lineStart + k] != label[k] { same = false; break }; k += 1 }
                if same {
                    while t < e && (p[t] == 0x20 || p[t] == 0x09) { t += 1 }
                    let mpStart = t
                    while t < e && p[t] != 0x20 && p[t] != 0x09 && p[t] != 0x0d { t += 1 }
                    return validateMountpoint(p, mpStart, t - mpStart, out, outMax)
                }
            }
        }
        i = (e < mlen) ? e + 1 : e
    }
    return 0
}

// V1/V2a/V2b: mount data volume `vol` on `dev`, graft it under `parent` at the
// given (dynamic) name, and mirror its tree. Empty-dir guardrail: never hide an
// existing non-empty directory of that name. Returns true iff the volume mounted.
//   V3: `formatBlank` threads FORMAT_IF_BLANK to datafsMount (stamp+format a
//   genuinely blank disk); `readOnly` marks the mount point read-only.
private func mountVolumeAt(_ parent: Int, _ vol: Int, _ dev: Int,
                           _ namePtr: UnsafePointer<UInt8>, _ nameLen: Int,
                           formatBlank: Bool = false, readOnly: Bool = false) -> Bool {
    if dev < 0 || nameLen <= 0 { return false }
    let existing = findChild(parent, namePtr, nameLen)
    if existing != -1 && nodes[existing].firstChild != -1 {
        uartPuts("V2: mountpoint not empty, skipped\n"); return false
    }
    if !datafsMount(vol, dev, formatBlank: formatBlank) { uartPuts("V1: extra datafs mount failed\n"); return false }
    let mp = existing != -1 ? existing : addDirNamed(parent, namePtr, nameLen, readOnly: readOnly)
    if mp < 0 { return false }
    nodes[mp].readOnly = readOnly
    nodes[mp].dataFs = true
    nodes[mp].dfsInode = datafsRootInode()
    nodes[mp].dfsVolume = vol
    nodes[mp].mode = 0o755
    datafsMirror(vol, mp, datafsRootInode())
    // Report the volume's stable identity (UUID halves + label length).
    uartPuts("V2 vol: uuid=")
    uartPutUInt(datafsVolumeUuidLo(vol))
    uartPuts(":")
    uartPutUInt(datafsVolumeUuidHi(vol))
    uartPuts(" labellen=")
    uartPutUInt(UInt64(datafsVolumeLabelLen(vol)))
    uartPuts("\n")
    uartPuts("V1 OK: datafs volume mounted under /mnt\n")
    return true
}

// ---- V3: runtime, capability-gated mount()/unmount() ----------------------
//
// The mount "table" is the implicit graft itself: a mountpoint VNode carries
// dataFs + dfsInode(root) + dfsVolume(slot). A runtime unmount recovers
// (mountpoint vnode, slot) by resolving the path and the invariant that a mount
// root is the unique datafs node whose PARENT is not datafs. Both syscalls are
// capConsole-gated (held by init / the cell supervisor), like device_claim.

// SYS_mount(selector, mountpoint, flags) flag bits — must match the userland
// SWIFTOS_MOUNT_* in userland/lib/syscall.h.
private let mountFlagRO: UInt = 1 << 0           // mount read-only (default: read-write)
private let mountFlagPersist: UInt = 1 << 1      // write the entry through to the manifest (V3b)
private let mountFlagFormatIfBlank: UInt = 1 << 2 // format a genuinely blank disk (no magic, sector 0 all zero)

// Length of a NUL-terminated user string already validated by userCString,
// scanned up to `max` bytes.
private func cstrLen(_ p: UnsafePointer<UInt8>, _ max: Int) -> Int {
    var n = 0
    while n < max && p[n] != 0 { n += 1 }
    return n
}

// Parse 16 hex chars at p[start..<start+16] into a UInt64; sets ok=false on any
// non-hex byte. Mirrors the cmdline UUID parse (V2c): first 16 hex = uuidHi, next
// 16 = uuidLo.
private func parseHex16(_ p: UnsafePointer<UInt8>, _ start: Int, _ ok: inout Bool) -> UInt64 {
    var v: UInt64 = 0
    var i = 0
    while i < 16 {
        let c = p[start + i]
        var d: UInt64 = 0
        if c >= 0x30 && c <= 0x39 { d = UInt64(c - 0x30) }
        else if c >= 0x61 && c <= 0x66 { d = UInt64(c - 0x61 + 10) }
        else if c >= 0x41 && c <= 0x46 { d = UInt64(c - 0x41 + 10) }
        else { ok = false; return 0 }
        v = (v << 4) | d
        i += 1
    }
    return v
}

// Resolve a mount selector to an enumerated, currently-UNMOUNTED SWDATAFS device
// index, or -1 if no such disk matches. A 32-hex-char selector matches by volume
// UUID; anything else matches by volume label. Caller holds vfsLock.
private func findUnmountedDataDevice(_ sel: UnsafePointer<UInt8>, _ selLen: Int) -> Int {
    if selLen <= 0 { return -1 }
    var byUuid = false
    var uHi: UInt64 = 0
    var uLo: UInt64 = 0
    if selLen == 32 {
        var ok = true
        uHi = parseHex16(sel, 0, &ok)
        uLo = parseHex16(sel, 16, &ok)
        byUuid = ok
    }
    let n = virtioBlkDataVolumeCount()
    var i = 0
    while i < n {
        let dev = virtioBlkDataDeviceIndexAt(i)
        if datafsDeviceMountedSlot(dev) >= 0 { i += 1; continue }  // already mounted
        if byUuid {
            let u = datafsPeekUuid(dev)
            if u.formatted && u.lo == uLo && u.hi == uHi { return dev }
        } else {
            var lbl = [UInt8](repeating: 0, count: 32)
            let ll = lbl.withUnsafeMutableBufferPointer { datafsPeekLabel(dev, $0.baseAddress!, $0.count) }
            if ll == selLen {
                var same = true
                var k = 0
                while k < ll { if lbl[k] != sel[k] { same = false; break }; k += 1 }
                if same { return dev }
            }
        }
        i += 1
    }
    return -1
}

// The /mnt mount-root directory, created on demand (it is created at boot only
// when extra volumes exist). Caller holds vfsLock.
private func ensureMntDir() -> Int {
    let path: StaticString = "/mnt"
    var name = [UInt8](repeating: 0, count: path.utf8CodeUnitCount + 1)
    path.withUTF8Buffer { b in for i in 0..<b.count { name[i] = b[i] } }
    let existing = name.withUnsafeBufferPointer { resolve($0.baseAddress!) }
    if existing > 0 { return existing }
    let mnt = addDir(0, "mnt", readOnly: false)   // node 0 = "/"
    if mnt >= 0 { nodes[mnt].mode = 0o755 }
    return mnt
}

// True iff anything keeps the subtree rooted at `root` busy: an open description
// pinning a vnode inside it, or a process whose cwd is inside it. This is the
// per-mount refcount computed on demand (the same shape as cell_destroy's
// live-member check), so it can never drift out of sync. Caller holds vfsLock.
private func mountSubtreeBusy(_ root: Int) -> Bool {
    for d in 0..<maxOpenDescriptions where openDescriptions[d].inUse {
        if openDescriptions[d].kind == .file {        // .file descriptions index a vnode
            let nd = openDescriptions[d].node
            if nd > 0 && nd < nodeCount && isDescendant(nd, of: root) { return true }
        }
    }
    for p in 0..<maxVFSProcesses {
        let c = cwdNode(p)
        if c > 0 && c < nodeCount && isDescendant(c, of: root) { return true }
    }
    return false
}

// SYS_mount: mount an already-enumerated, unmounted SWDATAFS volume named by
// `selector` (32-hex UUID, else label) at `mountpoint` (must be /mnt/<name>).
func vfsMount(selector selVA: UInt, mountpoint mpVA: UInt, flags: UInt) -> Int {
    if (processCurrentCaps() & capConsole) == 0 { return Errno.access.code }
    guard let sel = userCString(selVA, maxLen: 64) else { return Errno.invalid.code }
    guard let mpPath = userCString(mpVA, maxLen: 64) else { return Errno.invalid.code }

    // Guardrail: the mountpoint must be exactly /mnt/<name> (single, path-safe
    // component) — never over /bin, /etc, ... — and extract the name.
    var nameBuf = [UInt8](repeating: 0, count: 32)
    let mpLen = cstrLen(mpPath, 64)
    let nameLen = nameBuf.withUnsafeMutableBufferPointer {
        validateMountpoint(mpPath, 0, mpLen, $0.baseAddress!, $0.count)
    }
    if nameLen < 0 { return Errno.access.code }

    let readOnly = (flags & mountFlagRO) != 0
    let formatBlank = (flags & mountFlagFormatIfBlank) != 0
    let selLen = cstrLen(sel, 64)

    let daif = vfsLock()
    defer { vfsUnlock(daif) }

    let dev = findUnmountedDataDevice(sel, selLen)
    if dev < 0 { return Errno.noEntry.code }       // no matching unmounted disk

    let slot = datafsFindFreeVolume()
    if slot < 0 { return Errno.noSpace.code }       // all datafs slots in use

    let mnt = ensureMntDir()
    if mnt < 0 { return Errno.noSpace.code }

    let ok = nameBuf.withUnsafeBufferPointer {
        mountVolumeAt(mnt, slot, dev, $0.baseAddress!, nameLen,
                      formatBlank: formatBlank, readOnly: readOnly)
    }
    if !ok { return Errno.invalid.code }            // busy/non-empty mountpoint or datafs refused
    uartPuts("V3 OK: runtime mount\n")

    // V3b: PERSIST writes the entry through to /data/.system/mounts so the mount
    // re-applies on reboot. The manifest is label-keyed, so persistence needs a
    // labeled volume; an unlabeled volume stays a live-only mount.
    if (flags & mountFlagPersist) != 0 {
        var lbl = [UInt8](repeating: 0, count: 32)
        let ll = lbl.withUnsafeMutableBufferPointer { datafsVolumeLabelCopy(slot, $0.baseAddress!, $0.count) }
        if ll <= 0 {
            uartPuts("V3: persist skipped (volume is unlabeled)\n")
        } else {
            let persisted = lbl.withUnsafeBufferPointer { lp in
                nameBuf.withUnsafeBufferPointer { np in
                    persistMountEntry(lp.baseAddress!, ll, np.baseAddress!, nameLen)
                }
            }
            uartPuts(persisted ? "V3 OK: mount persisted to manifest\n"
                               : "V3: persist write-through failed\n")
        }
    }
    return 0
}

// SYS_unmount: tear down a runtime graft and release its datafs slot. Refuses a
// busy mountpoint (EBUSY) and never unmounts the root /data volume (slot 0).
func vfsUnmount(mountpoint mpVA: UInt) -> Int {
    if (processCurrentCaps() & capConsole) == 0 { return Errno.access.code }
    guard let mpPath = userCString(mpVA, maxLen: 64) else { return Errno.invalid.code }

    // Confine to /mnt/<name>, mirroring the mount guardrail.
    var nameBuf = [UInt8](repeating: 0, count: 32)
    let mpLen = cstrLen(mpPath, 64)
    let nameLen = nameBuf.withUnsafeMutableBufferPointer {
        validateMountpoint(mpPath, 0, mpLen, $0.baseAddress!, $0.count)
    }
    if nameLen < 0 { return Errno.access.code }

    let daif = vfsLock()
    defer { vfsUnlock(daif) }

    let node = resolve(mpPath)
    if node <= 0 { return Errno.noEntry.code }
    // Must be a datafs mount ROOT: the unique datafs node whose parent is not
    // datafs (a plain dir like /mnt). This refuses unmounting a datafs subdir.
    if !nodes[node].dataFs { return Errno.invalid.code }
    let parent = nodes[node].parent
    if parent < 0 || nodes[parent].dataFs { return Errno.invalid.code }
    let slot = nodes[node].dfsVolume
    if slot == 0 { return Errno.access.code }       // never unmount the root /data

    if mountSubtreeBusy(node) { return Errno.busy.code }

    // Detach the whole mountpoint subtree from /mnt (the name disappears; the
    // orphaned mirrored vnodes are reclaimed lazily, like every removed vnode),
    // then release the datafs slot so the disk can be remounted.
    _ = unlinkChild(parent, node)
    _ = datafsUnmount(slot)
    uartPuts("V3 OK: runtime unmount\n")
    return 0
}

// V3b: write the `<label> /mnt/<name>` entry through to the root volume's mount
// manifest (/data/.system/mounts), so the runtime mount re-applies at the next
// boot via the V2b authoritative-manifest path. The manifest is label-keyed: any
// existing line for the same label is replaced (re-persisting a label to a new
// mountpoint updates it). Caller holds vfsLock and has verified the volume is
// labeled. Returns true on success. Reuses the same VFS+datafs operations as a
// userland write, so the on-disk inode and the in-memory mirror stay consistent.
private func persistMountEntry(_ label: UnsafePointer<UInt8>, _ labelLen: Int,
                               _ name: UnsafePointer<UInt8>, _ nameLen: Int) -> Bool {
    // Resolve /data (root datafs volume 0).
    let dataPath: StaticString = "/data"
    var dp = [UInt8](repeating: 0, count: dataPath.utf8CodeUnitCount + 1)
    dataPath.withUTF8Buffer { b in for i in 0..<b.count { dp[i] = b[i] } }
    let dataNode = dp.withUnsafeBufferPointer { resolve($0.baseAddress!) }
    if dataNode <= 0 || !nodes[dataNode].dataFs { return false }

    // Find or create /data/.system (a datafs directory).
    let sysName: StaticString = ".system"
    var sn = [UInt8](repeating: 0, count: sysName.utf8CodeUnitCount)
    sysName.withUTF8Buffer { b in for i in 0..<b.count { sn[i] = b[i] } }
    var systemNode = sn.withUnsafeBufferPointer { findChild(dataNode, $0.baseAddress!, $0.count) }
    if systemNode < 0 {
        systemNode = sn.withUnsafeBufferPointer { createDataFsNode(dataNode, $0.baseAddress!, $0.count, isDir: true) }
    }
    if systemNode < 0 || !nodes[systemNode].isDir { return false }

    // Find or create /data/.system/mounts (a datafs file).
    let mName: StaticString = "mounts"
    var mn = [UInt8](repeating: 0, count: mName.utf8CodeUnitCount)
    mName.withUTF8Buffer { b in for i in 0..<b.count { mn[i] = b[i] } }
    var mountsNode = mn.withUnsafeBufferPointer { findChild(systemNode, $0.baseAddress!, $0.count) }
    if mountsNode < 0 {
        mountsNode = mn.withUnsafeBufferPointer { createDataFsNode(systemNode, $0.baseAddress!, $0.count, isDir: false) }
    }
    if mountsNode < 0 || nodes[mountsNode].isDir { return false }

    let vol = nodes[mountsNode].dfsVolume
    let ino = nodes[mountsNode].dfsInode

    return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: manifestCap) { src in
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: manifestCap) { dst in
            // Read the current manifest content.
            var srcLen = nodes[mountsNode].dataLen
            if srcLen > manifestCap { srcLen = manifestCap }
            if srcLen > 0 {
                let got = datafsRead(vol, ino, 0, UnsafeMutableRawPointer(src.baseAddress!), srcLen)
                srcLen = got > 0 ? got : 0
            }
            // Copy existing lines verbatim, dropping any whose first token is this
            // label (so a re-persist replaces the stale mountpoint).
            var outLen = 0
            var i = 0
            while i < srcLen {
                let lineStart = i
                while i < srcLen && src[i] != 0x0a { i += 1 }
                let lineEnd = i                       // points at '\n' or end
                let copyEnd = (lineEnd < srcLen) ? lineEnd + 1 : lineEnd   // include the '\n'
                i = copyEnd
                var t = lineStart                     // first whitespace-delimited token
                while t < lineEnd && src[t] != 0x20 && src[t] != 0x09 { t += 1 }
                let tokLen = t - lineStart
                var sameLabel = (tokLen == labelLen)
                if sameLabel {
                    var k = 0
                    while k < labelLen { if src[lineStart + k] != label[k] { sameLabel = false; break }; k += 1 }
                }
                if sameLabel { continue }             // drop the stale entry
                let lineLen = copyEnd - lineStart
                if outLen + lineLen > manifestCap { return false }
                var k = 0
                while k < lineLen { dst[outLen + k] = src[lineStart + k]; k += 1 }
                outLen += lineLen
            }
            // Ensure a newline separates the prior content from the new line.
            if outLen > 0 && dst[outLen - 1] != 0x0a {
                if outLen + 1 > manifestCap { return false }
                dst[outLen] = 0x0a; outLen += 1
            }
            // Append "<label> /mnt/<name>\n".
            let mid: StaticString = " /mnt/"
            var need = labelLen + nameLen + 1
            mid.withUTF8Buffer { need += $0.count }
            if outLen + need > manifestCap { return false }
            var k = 0
            while k < labelLen { dst[outLen] = label[k]; outLen += 1; k += 1 }
            mid.withUTF8Buffer { b in var j = 0; while j < b.count { dst[outLen] = b[j]; outLen += 1; j += 1 } }
            k = 0
            while k < nameLen { dst[outLen] = name[k]; outLen += 1; k += 1 }
            dst[outLen] = 0x0a; outLen += 1
            // Rewrite the file (truncate to 0 + write), update the mirror length,
            // and flush so the entry survives the reboot.
            if !datafsTruncate(vol, ino, 0) { return false }
            let wrote = datafsWrite(vol, ino, 0, UnsafeRawPointer(dst.baseAddress!), outLen)
            if wrote != outLen { return false }
            nodes[mountsNode].dataLen = outLen
            _ = datafsFlush(vol)
            return true
        }
    }
}

private func pipeCount(_ p: Int) -> Int {
    (pipes[p].tail - pipes[p].head + pipes[p].cap) % pipes[p].cap
}

private func pipeSpace(_ p: Int) -> Int {
    pipes[p].cap - pipeCount(p) - 1
}

private func pipePush(_ p: Int, _ byte: UInt8) {
    let b = UnsafeMutablePointer<UInt8>(bitPattern: pipes[p].bufPtr)!
    b[pipes[p].tail] = byte
    pipes[p].tail = (pipes[p].tail + 1) % pipes[p].cap
}

private func pipePop(_ p: Int) -> UInt8 {
    let b = UnsafeMutablePointer<UInt8>(bitPattern: pipes[p].bufPtr)!
    let byte = b[pipes[p].head]
    pipes[p].head = (pipes[p].head + 1) % pipes[p].cap
    return byte
}

private func releasePipeRef(_ p: Int, read: Bool) {
    if p < 0 || p >= maxPipes || !pipes[p].inUse { return }
    if read {
        if pipes[p].readRefs > 0 { pipes[p].readRefs -= 1 }
    } else {
        if pipes[p].writeRefs > 0 { pipes[p].writeRefs -= 1 }
    }
    if pipes[p].readRefs == 0 && pipes[p].writeRefs == 0 {
        pipes[p] = Pipe()
    }
}

private func allocPipe() -> Int {
    for i in 0..<maxPipes where !pipes[i].inUse {
        guard let buf = swiftos_kernel_alloc(UInt(pipeCap), 16) else { return -1 }
        pipes[i] = Pipe(inUse: true, bufPtr: UInt(bitPattern: buf), cap: pipeCap,
                        head: 0, tail: 0, readRefs: 1, writeRefs: 1)
        return i
    }
    return -1
}

private func vfsS4bAccountingSelfTestLocked() -> Bool {
    if nodes == nil || nodeCount <= 0 || !nodes[0].inUse || !nodes[0].isDir {
        return false
    }

    return withUnsafeTemporaryAllocation(of: Int.self, capacity: maxOpenDescriptions) { descRefs in
        withUnsafeTemporaryAllocation(of: Int.self, capacity: maxPipes) { pipeReadRefs in
            withUnsafeTemporaryAllocation(of: Int.self, capacity: maxPipes) { pipeWriteRefs in
                withUnsafeTemporaryAllocation(of: Int.self, capacity: maxEndpoints) { endpointSendRefs in
                    withUnsafeTemporaryAllocation(of: Int.self, capacity: maxEndpoints) { endpointRecvRefs in
                        for i in 0..<maxOpenDescriptions { descRefs[i] = 0 }
                        for i in 0..<maxPipes {
                            pipeReadRefs[i] = 0
                            pipeWriteRefs[i] = 0
                        }
                        for i in 0..<maxEndpoints {
                            endpointSendRefs[i] = 0
                            endpointRecvRefs[i] = 0
                        }

                        for p in 0..<maxVFSProcesses {
                            guard let table = handleTable(p) else { continue }
                            for fd in 0..<maxFDs {
                                let entry = table[fd]
                                if entry.inUse {
                                    let d = entry.object
                                    if d < 0 || d >= maxOpenDescriptions { return false }
                                    if !openDescriptions[d].inUse { return false }
                                    if entry.kind != openDescriptions[d].kind { return false }
                                    descRefs[d] += 1
                                }
                            }
                        }

                        for ep in 0..<maxEndpoints where endpoints[ep].inUse {
                            if endpoints[ep].bufPtr == 0 { return false }
                            if endpoints[ep].msgLen < 0 || endpoints[ep].msgLen > endpointMsgCap { return false }
                            if endpoints[ep].hasHandle {
                                let entry = endpoints[ep].handle
                                if !entry.inUse { return false }
                                let d = entry.object
                                if d < 0 || d >= maxOpenDescriptions { return false }
                                if !openDescriptions[d].inUse { return false }
                                descRefs[d] += 1
                            }
                        }

                        // QW1: a reply port holding a moved (replied) handle owns
                        // a description ref exactly like an endpoint's in-flight
                        // handle — count it so the refcount audit stays balanced.
                        for pr in 0..<maxReplyPorts where replyPorts[pr].inUse {
                            if replyPorts[pr].bufPtr == 0 { return false }
                            if replyPorts[pr].replyLen < 0 || replyPorts[pr].replyLen > endpointMsgCap { return false }
                            if replyPorts[pr].hasHandle {
                                let entry = replyPorts[pr].handle
                                if !entry.inUse { return false }
                                let d = entry.object
                                if d < 0 || d >= maxOpenDescriptions { return false }
                                if !openDescriptions[d].inUse { return false }
                                descRefs[d] += 1
                            }
                        }

                        // LA1: the name registry pins each published endpoint's
                        // recv description with a held ref (so it outlives the
                        // publisher's fd). That ref is real — account for it here
                        // or the refCount audit below would see an "extra" ref.
                        for s in 0..<maxServiceNames where serviceNames[s].inUse {
                            let d = serviceNames[s].recvDesc
                            if d < 0 || d >= maxOpenDescriptions { return false }
                            if !openDescriptions[d].inUse { return false }
                            descRefs[d] += 1
                        }

                        for d in 0..<maxOpenDescriptions {
                            let desc = openDescriptions[d]
                            if desc.inUse {
                                if desc.refCount != descRefs[d] { return false }
                                if desc.refCount <= 0 { return false }
                                if desc.kind == .pipe {
                                    let p = desc.pipe
                                    if p < 0 || p >= maxPipes || !pipes[p].inUse { return false }
                                    if desc.pipeEnd == pipeDuplexEnd {
                                        pipeReadRefs[p] += 1
                                        let wp = desc.writePipe
                                        if wp < 0 || wp >= maxPipes || !pipes[wp].inUse { return false }
                                        pipeWriteRefs[wp] += 1
                                    } else if desc.pipeEnd == pipeReadEnd {
                                        pipeReadRefs[p] += 1
                                    } else {
                                        pipeWriteRefs[p] += 1
                                    }
                                } else if desc.kind == .endpoint {
                                    let ep = desc.node
                                    if ep < 0 || ep >= maxEndpoints || !endpoints[ep].inUse { return false }
                                    if desc.pipeEnd == endpointSendEnd {
                                        endpointSendRefs[ep] += 1
                                    } else {
                                        endpointRecvRefs[ep] += 1
                                    }
                                } else if desc.kind == .file {
                                    if desc.node < 0 || desc.node >= nodeCount || !nodes[desc.node].inUse {
                                        return false
                                    }
                                } else if desc.kind == .device {
                                    let dev = desc.node
                                    if dev < 0 || dev >= maxDevices || !devices[dev].inUse ||
                                        !devices[dev].claimed {
                                        return false
                                    }
                                } else if desc.kind == .event {
                                    let ev = desc.node
                                    if ev < 0 || ev >= maxEvents || !eventCounters[ev].inUse {
                                        return false
                                    }
                                }
                            } else if desc.refCount != 0 {
                                return false
                            }
                        }

                        for p in 0..<maxPipes {
                            if pipes[p].inUse {
                                if pipes[p].bufPtr == 0 || pipes[p].cap != pipeCap { return false }
                                if pipes[p].readRefs != pipeReadRefs[p] { return false }
                                if pipes[p].writeRefs != pipeWriteRefs[p] { return false }
                                if pipes[p].readRefs + pipes[p].writeRefs <= 0 { return false }
                            } else if pipeReadRefs[p] != 0 || pipeWriteRefs[p] != 0 {
                                return false
                            }
                        }

                        for ep in 0..<maxEndpoints {
                            if endpoints[ep].inUse {
                                if endpoints[ep].sendRefs != endpointSendRefs[ep] { return false }
                                if endpoints[ep].recvRefs != endpointRecvRefs[ep] { return false }
                                if endpoints[ep].sendRefs + endpoints[ep].recvRefs <= 0 { return false }
                            } else if endpointSendRefs[ep] != 0 || endpointRecvRefs[ep] != 0 {
                                return false
                            }
                        }
                        return true
                    }
                }
            }
        }
    }
}

func vfsS4bLockAcquireCount() -> UInt64 {
    vfsLockAtomicLoad(&vfsLockAcquireCount)
}

func vfsS4bLockContentionCount() -> UInt64 {
    vfsLockAtomicLoad(&vfsLockContentionCount)
}

func vfsS4bReadinessSelfTest() -> Bool {
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    return vfsS4bAccountingSelfTestLocked()
}

func vfsS4bLockBoundaryHeldSelfTest() -> Bool {
    if vfsLockAtomicLoad(&vfsLockWord) != 0 || vfsS4bLockAcquireCount() == 0 {
        return false
    }
    return vfsS4bReadinessSelfTest()
}

// ---- syscalls -------------------------------------------------------------

func vfsDeviceClaim(name nameVA: UInt, info infoVA: UInt) -> Int {
    if (processCurrentCaps() & capConsole) == 0 { return Errno.access.code }
    guard let name = userCString(nameVA, maxLen: deviceInfoNameCap) else { return Errno.invalid.code }
    let out: UnsafeMutablePointer<UInt8>?
    if infoVA == 0 {
        out = nil
    } else {
        guard let buf = userWritableBuffer(infoVA, deviceInfoSize) else { return Errno.invalid.code }
        out = buf
    }

    let proc = currentVFSProcess()
    let daif = vfsLock()
    defer { vfsUnlock(daif) }

    let dev = findDeviceByName(name)
    if dev < 0 { return Errno.noEntry.code }
    if devices[dev].claimed { return Errno.busy.code }

    let fd = allocFDInProcess(proc, from: 3)
    if fd < 0 { return Errno.noSpace.code }
    let d = allocDescription()
    if d < 0 { return Errno.noSpace.code }

    devices[dev].claimed = true
    devices[dev].ownerProc = proc
    devices[dev].generation &+= 1
    openDescriptions[d].kind = .device
    openDescriptions[d].node = dev
    installDescription(proc, fd, d, rights: deviceRights(dev))
    if let outBuf = out { writeDeviceInfoLocked(dev, outBuf) }
    return fd
}

func vfsDeviceDiscover(index: Int, info infoVA: UInt) -> Int {
    if (processCurrentCaps() & capConsole) == 0 { return Errno.access.code }
    if index < 0 { return Errno.invalid.code }
    guard let out = userWritableBuffer(infoVA, deviceInfoSize) else { return Errno.invalid.code }

    let daif = vfsLock()
    defer { vfsUnlock(daif) }

    var ordinal = 0
    for dev in 0..<maxDevices where devices[dev].inUse && devices[dev].discoverable {
        if ordinal == index {
            writeDeviceInfoLocked(dev, out)
            return 0
        }
        ordinal += 1
    }
    return Errno.noEntry.code
}

func vfsDeviceInfo(fd: Int, info infoVA: UInt) -> Int {
    guard let out = userWritableBuffer(infoVA, deviceInfoSize) else { return Errno.invalid.code }
    let proc = currentVFSProcess()
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    guard validFD(proc, fd) else { return Errno.badFD.code }
    let entry = fdEntry(proc, fd)
    guard entry.kind == .device else { return Errno.badFD.code }
    guard hasRights(entry.rights, .getattr) else { return Errno.access.code }
    let d = entry.object
    guard d >= 0 && d < maxOpenDescriptions && openDescriptions[d].inUse else { return Errno.badFD.code }
    let desc = openDescriptions[d]
    guard desc.kind == .device else { return Errno.badFD.code }
    let dev = desc.node
    guard dev >= 0 && dev < maxDevices && devices[dev].inUse else { return Errno.invalid.code }
    writeDeviceInfoLocked(dev, out)
    return 0
}

// LA2: resolve `fd` to its device grant's MMIO window for sys_device_mmap. The
// handle must be a `.device` carrying `.map` (else EACCES), and the named device
// must be mappable (deviceFlagNoMmioGrant clear, mmioLen != 0). Reads mmioBase/
// mmioLen under vfsLock, like every other registry access. On success returns
// (0, base, len); on failure a negative errno in `err` and zeros.
func vfsDeviceMmioWindow(fd: Int) -> (err: Int, base: UInt, len: UInt) {
    let proc = currentVFSProcess()
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    guard validFD(proc, fd) else { return (Errno.badFD.code, 0, 0) }
    let entry = fdEntry(proc, fd)
    guard entry.kind == .device else { return (Errno.badFD.code, 0, 0) }
    guard hasRights(entry.rights, .map) else { return (Errno.access.code, 0, 0) }
    let d = entry.object
    guard d >= 0 && d < maxOpenDescriptions && openDescriptions[d].inUse else { return (Errno.badFD.code, 0, 0) }
    let desc = openDescriptions[d]
    guard desc.kind == .device else { return (Errno.badFD.code, 0, 0) }
    let dev = desc.node
    guard dev >= 0 && dev < maxDevices && devices[dev].inUse else { return (Errno.invalid.code, 0, 0) }
    // Defense in depth: a `.map` grant should only exist on a mappable device,
    // but re-check the device's own flags before handing out hardware authority.
    if (devices[dev].flags & deviceFlagNoMmioGrant) != 0 { return (Errno.access.code, 0, 0) }
    if devices[dev].mmioLen == 0 { return (Errno.access.code, 0, 0) }
    return (0, devices[dev].mmioBase, devices[dev].mmioLen)
}

func vfsOpen(path pathVA: UInt, flags: UInt) -> Int {
    guard let path = userCString(pathVA) else { return Errno.invalid.code }

    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    var node = resolve(path)
    let f = Int(bitPattern: flags)

    // M13: capability enforcement. Reading the filesystem needs capFsRead;
    // writing/creating (only the tmpfs is writable) needs capTmpWrite.
    let caps = processCurrentCaps()
    let wantWrite = (f & oWrOnly) != 0 || (f & oRdWr) != 0 ||
                    (f & oCreat) != 0 || (f & oTrunc) != 0
    let wantRead = (f & oWrOnly) == 0 // O_RDONLY or O_RDWR
    if wantRead && (caps & capFsRead) == 0 { return Errno.access.code }
    if wantWrite && (caps & capTmpWrite) == 0 { return Errno.access.code }

    // C3: object-scoped confinement. A confined process (confine root != 0) may only
    // reach paths inside its subtree; isDescendant(_, of: 0) is always true, so this is
    // a no-op for the unconfined default. See docs/CAPABILITIES.md §6 (C3).
    let confineRoot = confineRootForCurrentProcess()
    if node != -1 && !isDescendant(node, of: confineRoot) { return Errno.access.code }

    if node == -1 {
        if (f & oCreat) != 0 {
            var ls = 0, ll = 0
            let parent = resolveParent(path, &ls, &ll)
            if parent == -1 { return Errno.noEntry.code }
            if !isDescendant(parent, of: confineRoot) { return Errno.access.code } // C3 confinement
            if nodes[parent].readOnly { return Errno.readOnly.code }
            if findChild(parent, path + ls, ll) != -1 { return Errno.exists.code }
            node = nodes[parent].dataFs
                ? createDataFsNode(parent, path + ls, ll, isDir: false)
                : createTmpNode(parent, path + ls, ll, isDir: false)
            if node == -1 {
                // Debug-gated (default min level is INFO): names a failed /data
                // create without flooding healthy boots. detail = negative errno.
                if nodes[parent].dataFs {
                    klog(.debug, "datafs", "open creat failed", UInt64(bitPattern: Int64(Errno.noSpace.code)))
                }
                return Errno.noSpace.code
            }
        } else {
            return Errno.noEntry.code
        }
    }

    // I8: a disk-backed file must match its signed content hash before the
    // first descriptor is handed out (verified once per boot, then cached).
    if !nodes[node].isDir && nodes[node].onDisk && !vfsVerifyNodeContent(node) {
        return Errno.access.code
    }

    // O_TRUNC on a writable tmpfs file resets it to empty (shell `>` redirects).
    // Base/disk files are read-only, so truncation never applies to them.
    if (f & oTrunc) != 0 && !nodes[node].isDir && !nodes[node].readOnly {
        if nodes[node].dataFs { _ = datafsTruncate(nodes[node].dfsVolume, nodes[node].dfsInode, 0) }
        nodes[node].dataLen = 0
    }

    let proc = currentVFSProcess()
    let fd = allocUserFD(proc)            // C7b: enforce the cell handle cap (EMFILE)
    if fd < 0 { return fd }
    let d = allocDescription()
    if d == -1 { return Errno.noSpace.code }

    openDescriptions[d].kind = .file
    openDescriptions[d].node = node
    // O_APPEND starts the offset at end-of-file (shell `>>` redirects).
    openDescriptions[d].offset = (f & oAppend) != 0 ? nodes[node].dataLen : 0
    openDescriptions[d].dirCursor = 0
    openDescriptions[d].flags = f
    // Rights are per-handle (C1): derive read/write from the open mode and add
    // the POSIX fd meta-rights that keep dup/fork/fstat/IPC-transfer compatible.
    let r = posixRights(read: (f & oWrOnly) == 0 || (f & oRdWr) != 0,
                        write: (f & oWrOnly) != 0 || (f & oRdWr) != 0)
    installDescription(proc, fd, d, rights: r)
    if (f & oCloexec) != 0 { setFDEntryCloexec(proc, fd, true) }
    return fd
}

func vfsRead(fd: Int, buffer: UInt, count: UInt) -> Int {
    if count == 0 { return 0 }
    let proc = currentVFSProcess()
    let borrowed = borrowDescriptionForFD(proc, fd)
    if borrowed.err != 0 { return borrowed.err }
    let entry = borrowed.entry
    let d = borrowed.descIndex
    let file = borrowed.desc
    defer { releaseBorrowedDescription(d) }
    guard entry.rights.contains(.read) else { return Errno.badFD.code }

    if entry.kind == .tty {
        return ttyRead(buffer: buffer, count: count)
    }
    guard let dst = userWritableBuffer(buffer, count) else { return Errno.invalid.code }

    if entry.kind == .socket {
        if socketIsTCP(file.node) {
            if (file.flags & oNonblock) != 0 {
                netPump()
                if !socketPollReadable(file.node) { return Errno.again.code }
            }
            return tcpRecv(file.node, dst: UnsafeMutableRawPointer(dst), cap: Int(count),
                           timeoutMs: socketRecvTimeoutMs)
        }
        return Errno.invalid.code   // UDP: use recvfrom
    }

    if entry.kind == .pipe {
        let p = file.pipe
        var copied = 0
        enable_irq()
        while copied == 0 {
            let daif = vfsLock()
            if p < 0 || p >= maxPipes || !pipes[p].inUse {
                vfsUnlock(daif)
                return Errno.invalid.code
            }
            while copied < Int(count) && pipeCount(p) > 0 {
                dst[copied] = pipePop(p)
                copied += 1
            }
            let done = copied > 0 || pipes[p].writeRefs == 0
            if !done && (file.flags & oNonblock) != 0 {
                vfsUnlock(daif)
                return Errno.again.code
            }
            vfsUnlock(daif)
            if done { break }
            processYieldForIO()
        }
        return copied
    }

    if entry.kind == .ptyMaster {
        let p = file.pty
        var copied = 0
        enable_irq()
        while copied == 0 {
            let daif = vfsLock()
            if !ptyValid(p) { vfsUnlock(daif); return Errno.invalid.code }
            while copied < Int(count) && ptyOutCount(p) > 0 { dst[copied] = ptyOutPop(p); copied += 1 }
            let done = copied > 0 || ptySlaveRefs(p) == 0
            if !done && (file.flags & oNonblock) != 0 { vfsUnlock(daif); return Errno.again.code }
            // A pending signal (e.g. SIGINT raised on this PTY) interrupts the
            // blocking read so syscall return can deliver it.
            if !done && signalPendingForCurrent() { vfsUnlock(daif); return Errno.intr.code }
            vfsUnlock(daif)
            if done { break }
            processYieldForIO()
        }
        return copied
    }

    if entry.kind == .ptySlave {
        let p = file.pty
        var copied = 0
        enable_irq()
        while copied == 0 {
            let daif = vfsLock()
            if !ptyValid(p) { vfsUnlock(daif); return Errno.invalid.code }
            let canonical = (ptySlaveLflag(p) & ttyICANON) != 0
            while copied < Int(count) && ptyCookedCount(p) > 0 {
                let byte = ptyCookedPop(p)
                dst[copied] = byte
                copied += 1
                if canonical && byte == 0x0A { break } // one line per read
            }
            let done = copied > 0 || ptyMasterRefs(p) == 0
            if !done && (file.flags & oNonblock) != 0 { vfsUnlock(daif); return Errno.again.code }
            if !done && signalPendingForCurrent() { vfsUnlock(daif); return Errno.intr.code }
            vfsUnlock(daif)
            if done { break }
            processYieldForIO()
        }
        return copied
    }

    if entry.kind == .event {
        if count < 8 { return Errno.invalid.code }
        let ev = file.node
        enable_irq()
        while true {
            let daif = vfsLock()
            if ev < 0 || ev >= maxEvents || !eventCounters[ev].inUse {
                vfsUnlock(daif)
                return Errno.invalid.code
            }
            if eventCounters[ev].counter > 0 {
                let value: UInt64
                if (eventCounters[ev].flags & eventFlagSemaphore) != 0 {
                    value = 1
                    eventCounters[ev].counter -= 1
                } else {
                    value = eventCounters[ev].counter
                    eventCounters[ev].counter = 0
                }
                storeLe64(dst, 0, value)
                vfsUnlock(daif)
                return 8
            }
            if (file.flags & oNonblock) != 0 {
                vfsUnlock(daif)
                return Errno.again.code
            }
            vfsUnlock(daif)
            processYieldForIO()
        }
    }

    guard entry.kind == .file else { return Errno.badFD.code }
    let daif = vfsLock()
    var result = 0
    var diskImage = -1
    var diskOffset = 0
    var diskWant = 0
    var current = openDescriptions[d]
    let node = current.node
    if node < 0 || node >= nodeCount || !nodes[node].inUse {
        result = Errno.invalid.code
    } else if nodes[node].isDir {
        result = Errno.isDir.code
    } else if nodes[node].special != 0 {
        if nodes[node].special == 2 { // /dev/zero: count zero bytes
            var z = 0
            while z < Int(count) { dst[z] = 0; z += 1 }
            result = Int(count)
        } else if nodes[node].special == 3 { // /dev/urandom, /dev/random
            let got = virtioRngRead(dst, Int(count))
            result = got > 0 ? got : 0
        } // /dev/null: result stays 0 (EOF)
    } else if nodes[node].dataFs {
        // Persistent /data file: read from the data disk by inode. Done under the
        // VFS lock (synchronous polled block I/O on the single EL0 CPU).
        let avail = nodes[node].dataLen - current.offset
        if avail > 0 {
            let want = min(Int(count), avail)
            let got = datafsRead(nodes[node].dfsVolume, nodes[node].dfsInode, current.offset,
                                 UnsafeMutableRawPointer(dst), want)
            if got > 0 {
                current.offset += got
                openDescriptions[d] = current
                result = got
            } else if got < 0 {
                result = Errno.invalid.code
            }
        }
    } else if nodes[node].onDisk {
        // Reserve the shared offset under the VFS lock, then do the block-device
        // read without holding the VFS lock.
        let avail = nodes[node].dataLen - current.offset
        if avail > 0 {
            let want = min(Int(count), avail)
            diskImage = nodes[node].diskImage
            diskOffset = nodes[node].diskOffset + current.offset
            diskWant = want
            current.offset += want
            openDescriptions[d] = current
            result = want
        }
    } else {
        let src = UnsafePointer<UInt8>(bitPattern: nodes[node].dataPtr)!
        var copied = 0
        while copied < Int(count) && current.offset < nodes[node].dataLen {
            dst[copied] = src[current.offset]
            copied += 1
            current.offset += 1
        }
        openDescriptions[d] = current
        result = copied
    }
    vfsUnlock(daif)
    if diskWant > 0 {
        let off = UInt64(diskOffset)
        let rc = vfsImageReadRange(diskImage, off, UnsafeMutableRawPointer(dst), UInt32(diskWant))
        if rc != 0 { return Errno.invalid.code }
    }
    return result
}

func vfsKernelFileSize(fd: Int) -> Int {
    let proc = currentVFSProcess()
    guard validFD(proc, fd) else { return Errno.badFD.code }
    let entry = fdEntry(proc, fd)
    guard entry.kind == .file, entry.rights.contains(.read) else { return Errno.badFD.code }
    let node = openDescriptions[entry.object].node
    if node < 0 || nodes[node].isDir { return Errno.invalid.code }
    return nodes[node].dataLen
}

func vfsKernelReadFile(fd: Int, offset: Int, buffer: UnsafeMutableRawPointer?, count: Int) -> Int {
    if count == 0 { return 0 }
    if offset < 0 || count < 0 { return Errno.invalid.code }
    let proc = currentVFSProcess()
    guard validFD(proc, fd) else { return Errno.badFD.code }
    let entry = fdEntry(proc, fd)
    guard entry.kind == .file, entry.rights.contains(.read) else { return Errno.badFD.code }
    let node = openDescriptions[entry.object].node
    if node < 0 || nodes[node].isDir { return Errno.invalid.code }
    if offset >= nodes[node].dataLen { return 0 }
    guard let dst = buffer else { return Errno.invalid.code }
    let want = min(count, nodes[node].dataLen - offset)
    if nodes[node].onDisk {
        let off = UInt64(nodes[node].diskOffset + offset)
        let rc = vfsImageReadRange(nodes[node].diskImage, off, dst, UInt32(want))
        return rc == 0 ? want : Errno.invalid.code
    }
    let src = UnsafePointer<UInt8>(bitPattern: nodes[node].dataPtr)!
    let out = dst.bindMemory(to: UInt8.self, capacity: want)
    var i = 0
    while i < want {
        out[i] = src[offset + i]
        i += 1
    }
    return want
}

// W3: recv(fd, buf, len) with MSG_PEEK on a TCP socket — return buffered bytes
// without consuming them. nginx's `listen ssl` peeks the first byte to detect
// TLS. Only TCP-socket peek is supported; callers route here only for MSG_PEEK.
func vfsRecvPeek(fd: Int, buffer: UInt, count: UInt) -> Int {
    if count == 0 { return 0 }
    let proc = currentVFSProcess()
    let borrowed = borrowDescriptionForFD(proc, fd)
    if borrowed.err != 0 { return borrowed.err }
    let entry = borrowed.entry
    let d = borrowed.descIndex
    let file = borrowed.desc
    defer { releaseBorrowedDescription(d) }
    guard entry.rights.contains(.read) else { return Errno.badFD.code }
    guard entry.kind == .socket, socketIsTCP(file.node) else { return Errno.invalid.code }
    guard let dst = userWritableBuffer(buffer, count) else { return Errno.invalid.code }
    if (file.flags & oNonblock) != 0 {
        netPump()
        if !socketPollReadable(file.node) { return Errno.again.code }
    }
    return tcpRecv(file.node, dst: UnsafeMutableRawPointer(dst), cap: Int(count),
                   timeoutMs: socketRecvTimeoutMs, peek: true)
}

func vfsWrite(fd: Int, buffer: UInt, count: UInt) -> Int {
    if count == 0 { return 0 }
    let proc = currentVFSProcess()
    let borrowed = borrowDescriptionForFD(proc, fd)
    if borrowed.err != 0 { return borrowed.err }
    let entry = borrowed.entry
    let d = borrowed.descIndex
    let file = borrowed.desc
    defer { releaseBorrowedDescription(d) }
    guard entry.rights.contains(.write) else { return Errno.badFD.code }
    guard let src = userReadableBuffer(buffer, count) else { return Errno.invalid.code }

    if entry.kind == .tty {
        var w = 0
        while w < Int(count) { uartPutc(src[w]); w += 1 }
        return Int(count)
    }

    if entry.kind == .socket {
        if socketIsTCP(file.node) {
            var written = 0
            enable_irq()
            while written < Int(count) {
                netPump()
                let n = tcpSend(file.node, src: UnsafeRawPointer(src + written),
                                len: Int(count) - written)
                if n > 0 {
                    written += n
                    continue
                }
                if n < 0 { return written > 0 ? written : n }
                if !socketWriteOpen(file.node) { return written > 0 ? written : Errno.pipe.code }
                if (file.flags & oNonblock) != 0 { return written > 0 ? written : Errno.again.code }
                wfi()
            }
            return written
        }
        return Errno.invalid.code   // UDP: use sendto
    }

    if entry.kind == .pipe {
        let p = file.pipeEnd == pipeDuplexEnd ? file.writePipe : file.pipe
        var written = 0
        enable_irq()
        while written < Int(count) {
            let daif = vfsLock()
            if p < 0 || p >= maxPipes || !pipes[p].inUse {
                vfsUnlock(daif)
                return Errno.invalid.code
            }
            if pipes[p].readRefs == 0 {
                vfsUnlock(daif)
                return written > 0 ? written : Errno.pipe.code
            }
            while written < Int(count) && pipeSpace(p) > 0 {
                pipePush(p, src[written])
                written += 1
            }
            let done = written >= Int(count)
            if !done && (file.flags & oNonblock) != 0 {
                vfsUnlock(daif)
                return written > 0 ? written : Errno.again.code
            }
            vfsUnlock(daif)
            if done { break }
            if written < Int(count) { processYieldForIO() }
        }
        return written
    }

    if entry.kind == .ptyMaster {
        // Keystrokes from the terminal server: feed through the line discipline.
        // Non-blocking by design (a full cooked buffer drops input, as on a real
        // tty under flow control).
        let p = file.pty
        let daif = vfsLock()
        if !ptyValid(p) { vfsUnlock(daif); return Errno.invalid.code }
        var w = 0
        while w < Int(count) { ptyInput(p, src[w]); w += 1 }
        vfsUnlock(daif)
        return Int(count)
    }

    if entry.kind == .ptySlave {
        // Program output: copy to the master-readable ring with ONLCR (LF->CRLF).
        let p = file.pty
        var written = 0
        enable_irq()
        while written < Int(count) {
            let daif = vfsLock()
            if !ptyValid(p) { vfsUnlock(daif); return Errno.invalid.code }
            if ptyMasterRefs(p) == 0 { vfsUnlock(daif); return written > 0 ? written : Errno.pipe.code }
            while written < Int(count) {
                let byte = src[written]
                if byte == 0x0A {
                    if ptyOutSpace(p) < 2 { break }
                    ptyOutPush(p, 0x0D); ptyOutPush(p, 0x0A)
                } else {
                    if ptyOutSpace(p) < 1 { break }
                    ptyOutPush(p, byte)
                }
                written += 1
            }
            let done = written >= Int(count)
            if !done && (file.flags & oNonblock) != 0 { vfsUnlock(daif); return written > 0 ? written : Errno.again.code }
            vfsUnlock(daif)
            if done { break }
            if written < Int(count) { processYieldForIO() }
        }
        return written
    }

    if entry.kind == .event {
        if count < 8 { return Errno.invalid.code }
        let value = le64(src, 0)
        if value == UInt64.max { return Errno.invalid.code }
        let ev = file.node
        enable_irq()
        while true {
            let daif = vfsLock()
            if ev < 0 || ev >= maxEvents || !eventCounters[ev].inUse {
                vfsUnlock(daif)
                return Errno.invalid.code
            }
            if value <= eventMaxCounter - eventCounters[ev].counter {
                eventCounters[ev].counter += value
                vfsUnlock(daif)
                return 8
            }
            if (file.flags & oNonblock) != 0 {
                vfsUnlock(daif)
                return Errno.again.code
            }
            vfsUnlock(daif)
            processYieldForIO()
        }
    }

    guard entry.kind == .file else { return Errno.badFD.code }
    let daif = vfsLock()
    var result = 0
    var current = openDescriptions[d]
    let node = current.node
    if node < 0 || node >= nodeCount || !nodes[node].inUse {
        result = Errno.invalid.code
    } else if nodes[node].isDir {
        result = Errno.isDir.code
    } else if nodes[node].special != 0 {
        result = Int(count)   // /dev/null and /dev/zero: discard writes
    } else if nodes[node].dataFs {
        // Persistent /data file: write through to the data disk by inode.
        let w = datafsWrite(nodes[node].dfsVolume, nodes[node].dfsInode, current.offset,
                            UnsafeRawPointer(src), Int(count))
        if w > 0 {
            current.offset += w
            nodes[node].dataLen = datafsInodeSize(nodes[node].dfsVolume, nodes[node].dfsInode)
            nodes[node].mtime = rtcNow()
            openDescriptions[d] = current
            result = w
        } else {
            result = w == 0 ? 0 : Errno.noSpace.code
            // Debug-gated: a healthy D3 boot never logs here (the D3 readonly
            // failure was SQLITE_READONLY_DBMOVED from garbage st_ino, not a
            // datafs write errno).
            if result < 0 {
                klog(.debug, "datafs", "write failed", UInt64(bitPattern: Int64(result)))
            }
        }
    } else if nodes[node].readOnly {
        result = Errno.readOnly.code
    } else if !ensureTmpFileCapacity(node, current.offset + Int(count)) {
        result = Errno.noSpace.code
    } else {
        let dst = UnsafeMutablePointer<UInt8>(bitPattern: nodes[node].dataPtr)!
        var w = 0
        while w < Int(count) && current.offset < nodes[node].dataCap {
            dst[current.offset] = src[w]
            current.offset += 1
            if current.offset > nodes[node].dataLen { nodes[node].dataLen = current.offset }
            w += 1
        }
        if w > 0 { nodes[node].mtime = rtcNow() }
        openDescriptions[d] = current
        result = w
    }
    vfsUnlock(daif)
    return result
}

/// ftruncate(fd, length): resize a writable tmpfs file. Used by busybox vi,
/// which writes the buffer with O_CREAT (no O_TRUNC) and then ftruncate()s to
/// the exact length — so without this an overwrite that shrinks a file would
/// leave a stale tail. Growth zero-fills up to the node's capacity.
func vfsFtruncate(fd: Int, length: Int) -> Int {
    if length < 0 { return Errno.invalid.code }
    let proc = currentVFSProcess()
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    guard validFD(proc, fd) else { return Errno.badFD.code }
    let entry = fdEntry(proc, fd)
    let d = entry.object
    let file = openDescriptions[d]
    guard entry.rights.contains(.write) else { return Errno.badFD.code }
    guard entry.kind == .file else { return Errno.invalid.code }
    let node = file.node
    if nodes[node].isDir { return Errno.isDir.code }
    if nodes[node].dataFs {
        if !datafsTruncate(nodes[node].dfsVolume, nodes[node].dfsInode, length) {
            klog(.debug, "datafs", "ftruncate failed", UInt64(bitPattern: Int64(Errno.noSpace.code)))
            return Errno.noSpace.code
        }
        nodes[node].dataLen = length
        nodes[node].mtime = rtcNow()
        return 0
    }
    if nodes[node].readOnly { return Errno.readOnly.code }
    if length > nodes[node].dataCap { return Errno.noSpace.code }
    if length > nodes[node].dataLen {
        let base = UnsafeMutablePointer<UInt8>(bitPattern: nodes[node].dataPtr)!
        var i = nodes[node].dataLen
        while i < length { base[i] = 0; i += 1 }
    }
    nodes[node].dataLen = length
    nodes[node].mtime = rtcNow()
    return 0
}

// D2: fsync(fd)/fdatasync(fd). Flush the fd's filesystem to stable media. For a
// /data (datafs) file this issues the data-disk cache flush; for tmpfs/base or
// non-file fds there is nothing durable to flush, so it succeeds as a no-op.
func vfsFsync(fd: Int) -> Int {
    let proc = currentVFSProcess()
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    guard validFD(proc, fd) else { return Errno.badFD.code }
    let entry = fdEntry(proc, fd)
    guard entry.kind == .file else { return 0 }
    let node = openDescriptions[entry.object].node
    if node >= 0 && node < nodeCount && nodes[node].dataFs {
        let fr = datafsFlush(nodes[node].dfsVolume)
        if fr != 0 {
            klog(.debug, "datafs", "fsync failed", UInt64(bitPattern: Int64(Errno.invalid.code)))
            return Errno.invalid.code
        }
        return 0
    }
    return 0
}

// D2: sync(). Flush every writable filesystem to stable media. Only datafs
// volumes are durable, so this flushes each mounted one (when present).
func vfsSyncAll() -> Int {
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    datafsSyncAll()
    return 0
}

func vfsClose(fd: Int) -> Int {
    return handleClose(currentVFSProcess(), fd)
}

func vfsDup(fd: Int) -> Int {
    let proc = currentVFSProcess()
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    guard validFD(proc, fd) else { return Errno.badFD.code }
    guard fdEntryHasRights(proc, fd, .duplicate) else { return Errno.access.code }
    let newfd = allocUserFD(proc, from: 0)   // C7b: cell handle cap (EMFILE)
    if newfd < 0 { return newfd }
    let d = fdEntry(proc, fd).object
    retainDescription(d)
    // The dup carries the source handle's rights (today: identical access via
    // the shared description).
    installDescription(proc, newfd, d, rights: fdEntry(proc, fd).rights)
    return newfd
}

func vfsDup2(oldfd: Int, newfd: Int) -> Int {
    let proc = currentVFSProcess()
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    guard validFD(proc, oldfd) else { return Errno.badFD.code }
    if newfd < 0 || newfd >= maxFDs { return Errno.badFD.code }
    if oldfd == newfd { return newfd }
    guard fdEntryHasRights(proc, oldfd, .duplicate) else { return Errno.access.code }
    // C7b: dup2 to a FRESH newfd grows the handle table; refuse past the cell cap
    // (EMFILE). Reusing an in-use newfd is net-zero growth, so it is never capped.
    if !fdEntry(proc, newfd).inUse && cellHandleCapWouldExceed(proc, adding: 1) {
        return Errno.manyFiles.code
    }
    if fdEntry(proc, newfd).inUse {
        releaseDescription(fdEntry(proc, newfd).object)
        setFDEntry(proc, newfd, HandleEntry())
    }
    let d = fdEntry(proc, oldfd).object
    retainDescription(d)
    installDescription(proc, newfd, d, rights: fdEntry(proc, oldfd).rights)
    return newfd
}

// fcntl(fd, cmd, arg). Command numbers match newlib's <fcntl.h>. The busybox
// shell needs F_DUPFD_CLOEXEC to save/restore descriptors around every redirect
// (ash duplicates the fd above 10, then restores with dup2 + close). An unknown
// command MUST return a negative error: ash treats a non-negative result as the
// duplicated fd, so returning 0 for an unhandled command makes it close fd 0
// (stdin) on restore — that is exactly what broke the shell after a redirect.
private let fDupFD = 0
private let fGetFD = 1
private let fSetFD = 2
private let fGetFL = 3
private let fSetFL = 4
private let fDupFDCloexec = 14
private let fGetLk = 7     // F_GETLK  (newlib value)
private let fSetLk = 8     // F_SETLK
private let fSetLkw = 9    // F_SETLKW
private let fdCloexecFlag = 1
private let mutableStatusFlags = oNonblock

func vfsFcntl(fd: Int, cmd: Int, arg: Int) -> Int {
    let proc = currentVFSProcess()
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    guard validFD(proc, fd) else { return Errno.badFD.code }
    switch cmd {
    case fDupFD, fDupFDCloexec:
        guard fdEntryHasRights(proc, fd, .duplicate) else { return Errno.access.code }
        // Duplicate to the lowest free descriptor >= arg (shares the open
        // description, like dup). F_DUPFD_CLOEXEC additionally marks the new fd
        // close-on-exec.
        let start = arg < 0 ? 0 : arg
        let newfd = allocUserFD(proc, from: start)   // C7b: cell handle cap (EMFILE)
        if newfd < 0 { return newfd }
        let d = fdEntry(proc, fd).object
        retainDescription(d)
        installDescription(proc, newfd, d, rights: fdEntry(proc, fd).rights)
        if cmd == fDupFDCloexec { setFDEntryCloexec(proc, newfd, true) }
        return newfd
    case fGetFD:
        guard fdEntryHasRights(proc, fd, .getattr) else { return Errno.access.code }
        return fdEntry(proc, fd).cloexec ? fdCloexecFlag : 0
    case fSetFD:
        guard fdEntryHasRights(proc, fd, .setattr) else { return Errno.access.code }
        setFDEntryCloexec(proc, fd, (arg & fdCloexecFlag) != 0)
        return 0
    case fGetFL:
        guard fdEntryHasRights(proc, fd, .getattr) else { return Errno.access.code }
        return openDescriptions[fdEntry(proc, fd).object].flags
    case fSetFL:
        guard fdEntryHasRights(proc, fd, .setattr) else { return Errno.access.code }
        let d = fdEntry(proc, fd).object
        openDescriptions[d].flags = (openDescriptions[d].flags & ~mutableStatusFlags)
            | (arg & mutableStatusFlags)
        return 0
    case fGetLk, fSetLk, fSetLkw:
        // POSIX advisory record locks. With no concurrent openers of a /data file
        // (single process, SQLITE_THREADSAFE=0) advisory locking is a no-op
        // success — SQLite's unix VFS only needs F_SETLK to succeed to proceed.
        guard fdEntryHasRights(proc, fd, .getattr) else { return Errno.access.code }
        return 0
    default:
        return Errno.invalid.code
    }
}

func vfsPipe(fdsVA: UInt) -> Int {
    guard let out = userWritableBuffer(fdsVA, 8) else { return Errno.invalid.code }
    let proc = currentVFSProcess()
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    let rfd = allocUserFD(proc, from: 0)   // C7b: cell handle cap (EMFILE)
    if rfd < 0 { return rfd }
    setFDEntry(proc, rfd, HandleEntry(inUse: true, object: -1)) // reserve (counts toward the cap)
    let wfd = allocUserFD(proc, from: 0)
    setFDEntry(proc, rfd, HandleEntry())
    if wfd < 0 { return wfd }

    let p = allocPipe()
    if p == -1 { return Errno.noMem.code }
    let rd = allocDescription()
    let wr = allocDescription()
    if rd == -1 || wr == -1 { return Errno.noSpace.code }

    openDescriptions[rd].kind = .pipe
    openDescriptions[rd].pipe = p
    openDescriptions[rd].pipeEnd = pipeReadEnd

    openDescriptions[wr].kind = .pipe
    openDescriptions[wr].pipe = p
    openDescriptions[wr].pipeEnd = pipeWriteEnd

    // The read end may only be read from; the write end only written to, with
    // ordinary POSIX fd meta-rights for compatibility.
    installDescription(proc, rfd, rd, rights: posixRights(read: true, write: false))
    installDescription(proc, wfd, wr, rights: posixRights(read: false, write: true))
    let raw = UnsafeMutableRawPointer(out)
    raw.storeBytes(of: Int32(rfd), toByteOffset: 0, as: Int32.self)
    raw.storeBytes(of: Int32(wfd), toByteOffset: 4, as: Int32.self)
    return 0
}

// HC34: allocate a pseudo-terminal pair, returning the master fd in *masterVA
// and the slave fd in *slaveVA. The slave is the controlling-tty end (line
// discipline, S_IFCHR); the master is the terminal-server end.
func vfsOpenpty(masterVA: UInt, slaveVA: UInt) -> Int {
    guard let mOut = userWritableBuffer(masterVA, 4),
          let sOut = userWritableBuffer(slaveVA, 4) else { return Errno.invalid.code }
    let proc = currentVFSProcess()
    let daif = vfsLock()
    defer { vfsUnlock(daif) }

    let mfd = allocUserFD(proc, from: 0)   // C7b: cell handle cap (EMFILE)
    if mfd < 0 { return mfd }
    setFDEntry(proc, mfd, HandleEntry(inUse: true, object: -1)) // reserve (counts toward the cap)
    let sfd = allocUserFD(proc, from: 0)
    if sfd < 0 { setFDEntry(proc, mfd, HandleEntry()); return sfd }
    setFDEntry(proc, sfd, HandleEntry(inUse: true, object: -1))

    func unwind(_ code: Int) -> Int {
        setFDEntry(proc, mfd, HandleEntry())
        setFDEntry(proc, sfd, HandleEntry())
        return code
    }

    let p = ptyAlloc()
    if p == -1 { return unwind(Errno.noMem.code) }
    let md = allocDescription()
    let sd = allocDescription()
    if md == -1 || sd == -1 {
        discardUninstalledDescription(md)
        discardUninstalledDescription(sd)
        ptyReleaseEnd(p, master: true)
        ptyReleaseEnd(p, master: false)
        return unwind(Errno.noSpace.code)
    }

    openDescriptions[md].kind = .ptyMaster
    openDescriptions[md].pty = p
    openDescriptions[sd].kind = .ptySlave
    openDescriptions[sd].pty = p
    installDescription(proc, mfd, md, rights: posixRights(read: true, write: true))
    installDescription(proc, sfd, sd, rights: posixRights(read: true, write: true))

    UnsafeMutableRawPointer(mOut).storeBytes(of: Int32(mfd), toByteOffset: 0, as: Int32.self)
    UnsafeMutableRawPointer(sOut).storeBytes(of: Int32(sfd), toByteOffset: 0, as: Int32.self)
    return 0
}

// HC36: set the foreground process for a PTY (the target of tty-generated
// signals such as Ctrl-C/SIGINT). `fd` may be either end of the pair; `pid`
// names the foreground process (0 clears it). TIOCSPGRP-shaped but pid-scoped,
// as we do not yet model process groups.
func vfsPtySetForeground(fd: Int, pid: Int) -> Int {
    let proc = currentVFSProcess()
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    guard validFD(proc, fd) else { return Errno.badFD.code }
    let entry = fdEntry(proc, fd)
    guard entry.kind == .ptyMaster || entry.kind == .ptySlave else { return Errno.invalid.code }
    let p = openDescriptions[entry.object].pty
    guard ptyValid(p) else { return Errno.invalid.code }
    ptySetForeground(p, pid)
    return 0
}

// tcgetattr/tcsetattr must act on the terminal behind `fd`, not a single global.
// A pty end carries its own line-discipline flags (ptys[p].lflag); any other fd
// (the real console, or a non-tty) falls back to the console tty flags, which
// preserves prior behaviour for the console fds. Without per-fd routing, a
// program on a pty (e.g. mc over sshd) that switches to raw mode flipped the
// CONSOLE instead of its own pty slave, leaving the pty stuck in canonical mode.
func vfsTtyGetLflagForFD(_ fd: Int) -> UInt32 {
    let proc = currentVFSProcess()
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    guard validFD(proc, fd) else { return ttyGetLflag() }
    let entry = fdEntry(proc, fd)
    if entry.kind == .ptyMaster || entry.kind == .ptySlave {
        let p = openDescriptions[entry.object].pty
        if ptyValid(p) { return ptySlaveLflag(p) }
    }
    return ttyGetLflag()
}

func vfsTtySetLflagForFD(_ fd: Int, _ lflag: UInt32) {
    let proc = currentVFSProcess()
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    guard validFD(proc, fd) else { ttySetLflag(lflag); return }
    let entry = fdEntry(proc, fd)
    if entry.kind == .ptyMaster || entry.kind == .ptySlave {
        let p = openDescriptions[entry.object].pty
        if ptyValid(p) { ptySetLflag(p, lflag); return }
    }
    ttySetLflag(lflag)
}

private let socketpairFlagNonblock = 1
private let socketpairFlagCloexec = 2

func vfsSocketpair(fdsVA: UInt, flags: Int) -> Int {
    guard let out = userWritableBuffer(fdsVA, 8) else { return Errno.invalid.code }
    if (flags & ~(socketpairFlagNonblock | socketpairFlagCloexec)) != 0 {
        return Errno.invalid.code
    }

    let proc = currentVFSProcess()
    var fd0 = -1
    var fd1 = -1
    var p01 = -1
    var p10 = -1
    var d0 = -1
    var d1 = -1

    func fail(_ code: Int) -> Int {
        if d0 >= 0 && d0 < maxOpenDescriptions { openDescriptions[d0] = OpenDescription() }
        if d1 >= 0 && d1 < maxOpenDescriptions { openDescriptions[d1] = OpenDescription() }
        if p01 >= 0 && p01 < maxPipes { pipes[p01] = Pipe() }
        if p10 >= 0 && p10 < maxPipes { pipes[p10] = Pipe() }
        if fd0 >= 0 { setFDEntry(proc, fd0, HandleEntry()) }
        if fd1 >= 0 { setFDEntry(proc, fd1, HandleEntry()) }
        return code
    }

    let daif = vfsLock()
    defer { vfsUnlock(daif) }

    fd0 = allocUserFD(proc, from: 0)   // C7b: cell handle cap (EMFILE)
    if fd0 < 0 { return fd0 }
    setFDEntry(proc, fd0, HandleEntry(inUse: true, object: -1))
    fd1 = allocUserFD(proc, from: 0)
    if fd1 < 0 { return fail(fd1) }
    setFDEntry(proc, fd1, HandleEntry(inUse: true, object: -1))

    p01 = allocPipe()
    if p01 == -1 { return fail(Errno.noMem.code) }
    p10 = allocPipe()
    if p10 == -1 { return fail(Errno.noMem.code) }
    d0 = allocDescription()
    if d0 == -1 { return fail(Errno.noSpace.code) }
    d1 = allocDescription()
    if d1 == -1 { return fail(Errno.noSpace.code) }

    let statusFlags = (flags & socketpairFlagNonblock) != 0 ? oNonblock : 0
    openDescriptions[d0].kind = .pipe
    openDescriptions[d0].pipe = p10
    openDescriptions[d0].writePipe = p01
    openDescriptions[d0].pipeEnd = pipeDuplexEnd
    openDescriptions[d0].flags = statusFlags

    openDescriptions[d1].kind = .pipe
    openDescriptions[d1].pipe = p01
    openDescriptions[d1].writePipe = p10
    openDescriptions[d1].pipeEnd = pipeDuplexEnd
    openDescriptions[d1].flags = statusFlags

    installDescription(proc, fd0, d0, rights: posixRights(read: true, write: true))
    installDescription(proc, fd1, d1, rights: posixRights(read: true, write: true))
    if (flags & socketpairFlagCloexec) != 0 {
        setFDEntryCloexec(proc, fd0, true)
        setFDEntryCloexec(proc, fd1, true)
    }

    let raw = UnsafeMutableRawPointer(out)
    raw.storeBytes(of: Int32(fd0), toByteOffset: 0, as: Int32.self)
    raw.storeBytes(of: Int32(fd1), toByteOffset: 4, as: Int32.self)
    return 0
}

private func allocEventCounter(initval: UInt64, flags: Int) -> Int {
    for i in 0..<maxEvents where !eventCounters[i].inUse {
        eventCounters[i] = EventCounter(inUse: true, counter: initval, flags: flags)
        return i
    }
    return -1
}

func vfsEventfd(initval: UInt, flags: UInt) -> Int {
    let f = Int(bitPattern: flags)
    if (f & ~eventAllowedFlags) != 0 { return Errno.invalid.code }
    let proc = currentVFSProcess()
    let daif = vfsLock()
    defer { vfsUnlock(daif) }

    let fd = allocFDInProcess(proc, from: 3)
    if fd == -1 { return Errno.noSpace.code }
    let ev = allocEventCounter(initval: UInt64(initval), flags: f & eventFlagSemaphore)
    if ev == -1 { return Errno.noSpace.code }
    let d = allocDescription()
    if d == -1 {
        eventCounters[ev] = EventCounter()
        return Errno.noSpace.code
    }

    openDescriptions[d].kind = .event
    openDescriptions[d].node = ev
    openDescriptions[d].flags = f & oNonblock
    installDescription(proc, fd, d, rights: posixRights(read: true, write: true))
    if (f & oCloexec) != 0 { setFDEntryCloexec(proc, fd, true) }
    return fd
}

// ---- C4a: handle-passing IPC endpoints ------------------------------------
//
// A minimal capability-passing primitive (docs/CAPABILITIES.md §4): endpoint_create
// returns a (send, recv) fd pair; ipc_send copies BYTES and MOVES an optional
// handle into the channel; ipc_recv blocks until a message arrives, copies the bytes
// out and installs any transferred handle as a new fd in the receiver. This is the
// keystone for restartable services and cells (request/reply rides the bytes); a
// bidirectional channel, VMOs and async rings are later sub-milestones. Like a pipe,
// each endpoint owns a heap message buffer (off the bump heap — see allocPipe).

private func allocEndpoint() -> Int {
    for i in 0..<maxEndpoints where !endpoints[i].inUse {
        var bufPtr = endpoints[i].bufPtr
        if bufPtr == 0 {
            guard let buf = swiftos_kernel_alloc(UInt(endpointMsgCap), 16) else { return -1 }
            bufPtr = UInt(bitPattern: buf)
        }
        endpoints[i] = Endpoint(inUse: true, hasMsg: false, bufPtr: bufPtr,
                                msgLen: 0, hasHandle: false, handle: HandleEntry(),
                                sendRefs: 1, recvRefs: 1, ownerProc: -1)
        return i
    }
    return -1
}

/// endpoint_create(int ends[2]) -> 0; ends[0] = send end, ends[1] = recv end.
// ---- LA1 name registry helpers (all callers hold vfsLock) ----------------

private func cstrLenU8(_ s: UnsafePointer<UInt8>, max: Int) -> Int {
    var i = 0
    while i < max && s[i] != 0 { i += 1 }
    return i
}

private func serviceNameMatches(_ slot: Int, _ name: UnsafePointer<UInt8>, _ len: Int) -> Bool {
    if !serviceNames[slot].inUse || serviceNames[slot].nameLen != len { return false }
    let base = slot * serviceNameCap
    for i in 0..<len where serviceNameBytes[base + i] != name[i] { return false }
    return true
}

private func findServiceNameSlot(_ name: UnsafePointer<UInt8>, _ len: Int) -> Int {
    for i in 0..<maxServiceNames where serviceNameMatches(i, name, len) { return i }
    return -1
}

private func allocServiceNameSlot() -> Int {
    for i in 0..<maxServiceNames where !serviceNames[i].inUse { return i }
    return -1
}

/// name_register(name, endpoint_fd) -> 0 (LA1). Publish the RECV end of an
/// endpoint under a short name so a child can resolve the service without a
/// hard-coded path. Privileged (capConsole), like device_claim — only init / the
/// supervisor may publish. The registry pins the endpoint with an extra
/// description ref so it outlives the publisher's fd; re-registering the same name
/// updates the entry and releases the previous pin. SMP-safe under vfsLock.
func vfsNameRegister(nameVA: UInt, fd: Int) -> Int {
    if (processCurrentCaps() & capConsole) == 0 { return Errno.access.code }
    guard let name = userCString(nameVA, maxLen: serviceNameCap) else { return Errno.invalid.code }
    let proc = currentVFSProcess()
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    let nlen = cstrLenU8(name, max: serviceNameCap)
    if nlen == 0 { return Errno.invalid.code }
    guard validFD(proc, fd) else { return Errno.badFD.code }
    let entry = fdEntry(proc, fd)
    guard entry.kind == .endpoint else { return Errno.invalid.code }
    let d = entry.object
    guard d >= 0 && d < maxOpenDescriptions && openDescriptions[d].inUse else { return Errno.badFD.code }
    let desc = openDescriptions[d]
    guard desc.kind == .endpoint, desc.pipeEnd == endpointRecvEnd else { return Errno.invalid.code }

    var slot = findServiceNameSlot(name, nlen)
    if slot >= 0 {
        // Re-registering an existing name. If it already names this exact
        // description there is nothing to do; otherwise drop the old pin first.
        if serviceNames[slot].recvDesc == d { return 0 }
        releaseDescription(serviceNames[slot].recvDesc)
    } else {
        slot = allocServiceNameSlot()
        if slot < 0 { return Errno.noSpace.code }
    }
    retainDescription(d) // pin: the endpoint survives the publisher closing its fd
    // Transfer ownership to the registry: clear ownerProc so the QW3 owner-death
    // backstop (releaseEndpointsOwnedBy) does not tear the endpoint down when the
    // publisher exits — the registry pin alone now governs its lifetime, until the
    // name is overwritten/released. (A published service endpoint is owned by the
    // kernel name registry, not the publishing process.)
    endpoints[desc.node].ownerProc = -1
    serviceNames[slot].inUse = true
    serviceNames[slot].nameLen = nlen
    serviceNames[slot].recvDesc = d
    let base = slot * serviceNameCap
    for i in 0..<nlen { serviceNameBytes[base + i] = name[i] }
    return 0
}

/// name_lookup(name) -> fd (LA1). Resolve a registered service name and install a
/// FRESH SEND-end handle to its endpoint into the caller's fd table, returning the
/// new fd (Errno.noEntry if unknown). This is the explicit grant-by-lookup path:
/// the caller receives only a send capability (write+transfer), never the recv
/// authority. Ungated — a published name is meant to be reachable and a send cap
/// only lets the holder send. SMP-safe under vfsLock.
func vfsNameLookup(nameVA: UInt) -> Int {
    guard let name = userCString(nameVA, maxLen: serviceNameCap) else { return Errno.invalid.code }
    let proc = currentVFSProcess()
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    let nlen = cstrLenU8(name, max: serviceNameCap)
    if nlen == 0 { return Errno.invalid.code }
    let slot = findServiceNameSlot(name, nlen)
    if slot < 0 { return Errno.noEntry.code }
    let rd = serviceNames[slot].recvDesc
    guard rd >= 0 && rd < maxOpenDescriptions && openDescriptions[rd].inUse else { return Errno.noEntry.code }
    let ep = openDescriptions[rd].node
    guard ep >= 0 && ep < maxEndpoints && endpoints[ep].inUse else { return Errno.noEntry.code }

    let fd = allocFDInProcess(proc, from: 0)
    if fd < 0 { return Errno.noSpace.code }
    let sd = allocDescription()
    if sd < 0 { return Errno.noSpace.code }
    openDescriptions[sd].kind = .endpoint
    openDescriptions[sd].node = ep
    openDescriptions[sd].pipeEnd = endpointSendEnd
    endpoints[ep].sendRefs += 1 // mint a new send end (balanced when this fd closes)
    installDescription(proc, fd, sd, rights: endpointRights(read: false, write: true))
    return fd
}

func vfsEndpointCreate(endsVA: UInt) -> Int {
    guard let out = userWritableBuffer(endsVA, 8) else { return Errno.invalid.code }
    let proc = currentVFSProcess()
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    let sfd = allocUserFD(proc, from: 0)   // C7b: cell handle cap (EMFILE)
    if sfd < 0 { return sfd }
    setFDEntry(proc, sfd, HandleEntry(inUse: true, object: -1)) // reserve (counts toward the cap)
    let rfd = allocUserFD(proc, from: 0)
    if rfd < 0 {
        rollbackEndpointCreate(proc: proc, sfd: sfd, rfd: -1,
                               endpoint: -1, sendDesc: -1, recvDesc: -1)
        return rfd
    }
    setFDEntry(proc, rfd, HandleEntry(inUse: true, object: -1)) // reserve

    let ep = allocEndpoint()
    if ep == -1 {
        rollbackEndpointCreate(proc: proc, sfd: sfd, rfd: rfd,
                               endpoint: -1, sendDesc: -1, recvDesc: -1)
        return Errno.noMem.code
    }
    // QW3: stamp the creating process as the owner so reclamation-on-death can
    // find and tear down this endpoint deterministically.
    endpoints[ep].ownerProc = proc
    let sd = allocDescription()
    if sd == -1 {
        rollbackEndpointCreate(proc: proc, sfd: sfd, rfd: rfd,
                               endpoint: ep, sendDesc: -1, recvDesc: -1)
        return Errno.noSpace.code
    }
    let rd = allocDescription()
    if rd == -1 {
        rollbackEndpointCreate(proc: proc, sfd: sfd, rfd: rfd,
                               endpoint: ep, sendDesc: sd, recvDesc: -1)
        return Errno.noSpace.code
    }

    openDescriptions[sd].kind = .endpoint
    openDescriptions[sd].node = ep
    openDescriptions[sd].pipeEnd = endpointSendEnd
    openDescriptions[rd].kind = .endpoint
    openDescriptions[rd].node = ep
    openDescriptions[rd].pipeEnd = endpointRecvEnd

    installDescription(proc, sfd, sd, rights: endpointRights(read: false, write: true))
    installDescription(proc, rfd, rd, rights: endpointRights(read: true, write: false))
    let raw = UnsafeMutableRawPointer(out)
    raw.storeBytes(of: Int32(sfd), toByteOffset: 0, as: Int32.self)
    raw.storeBytes(of: Int32(rfd), toByteOffset: 4, as: Int32.self)
    return 0
}

// The user-side msg structs (fixed little-endian offsets, like sendto's udp_msg —
// the 3-arg syscall ABI carries only (fd, &msg)):
//   SEND  off 0: buf (u64 user VA)  off 8: len (u64)  off 16: handle_fd (i32, <0 = none)
//   RECV  off 0: buf (u64 user VA)  off 8: cap (u64)  off 16: out_handle_fd (u64 user VA → int)
//         off 24: out_badge (u64 user VA → u32; 0 = don't report) — QW4
// QW4 grew the recv struct 24→32. The kernel always reads 32 bytes; the ipc_recv
// wrapper passes a zero out_badge VA, so old callers are byte-for-byte compatible.
private let ipcSendMsgSize: UInt = 24  // buf(8) + len(8) + handle_fd(4) + requested_rights(4)
private let ipcRecvMsgSize: UInt = 32  // buf(8) + cap(8) + out_handle_fd(8) + out_badge(8)

private func handleNamesEndpoint(_ entry: HandleEntry, endpoint ep: Int) -> Bool {
    if entry.kind != .endpoint { return false }
    let d = entry.object
    if d < 0 || d >= maxOpenDescriptions || !openDescriptions[d].inUse { return false }
    return openDescriptions[d].node == ep
}

/// ipc_badge(fd, badge) -> 0: stamp a server-chosen client tag onto a send-end
/// endpoint handle (QW4). The badge rides with the send-capability — through a
/// handle transfer or a direct ipc_send — and ipc_recv_badged reports it to the
/// receiver, so one endpoint shared among many clients can tell them apart with
/// no side-channel identity lookup (docs/CAPABILITIES.md §4.2). 0 clears the
/// badge. A non-endpoint fd, or the recv end, is rejected.
func vfsIpcBadge(fd: Int, badge: UInt32) -> Int {
    let proc = currentVFSProcess()
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    guard validFD(proc, fd) else { return Errno.badFD.code }
    let entry = fdEntry(proc, fd)
    guard entry.kind == .endpoint else { return Errno.invalid.code }
    let desc = openDescriptions[entry.object]
    guard desc.kind == .endpoint, desc.pipeEnd == endpointSendEnd else { return Errno.invalid.code }
    setFDEntryBadge(proc, fd, badge)
    return 0
}

/// ipc_send(fd, &msg): copy up to endpointMsgCap message BYTES into the endpoint and,
/// if msg.handle_fd >= 0, MOVE that handle to the peer. The handle's source fd is
/// cleared WITHOUT releasing the underlying object — ownership (and its refcount)
/// transfers with the handle. Errno.again.code if a message is already in flight (single-slot
/// channel). A message may carry bytes with no handle, so the slot is gated on hasMsg.
func vfsIpcSend(fd: Int, msgVA: UInt) -> Int {
    let proc = currentVFSProcess()
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    guard validFD(proc, fd) else { return Errno.badFD.code }
    let sender = fdEntry(proc, fd)
    guard sender.rights.contains(.write) else { return Errno.badFD.code }
    guard sender.rights.contains(.transfer) else { return Errno.access.code }
    let desc = openDescriptions[sender.object]
    guard desc.kind == .endpoint, desc.pipeEnd == endpointSendEnd else { return Errno.invalid.code }
    let ep = desc.node
    guard ep >= 0 && ep < maxEndpoints && endpoints[ep].inUse else { return Errno.invalid.code }
    if endpoints[ep].recvRefs == 0 { return Errno.pipe.code }
    if endpoints[ep].hasMsg { return Errno.again.code }

    guard let m = userReadableBuffer(msgVA, ipcSendMsgSize) else { return Errno.invalid.code }
    let buf = UInt(le64(m, 0))
    let len = Int(le64(m, 8))
    let handleFd = Int(Int32(bitPattern: le32(m, 16)))
    // QW5: rights the sender is willing to grant. The handle that crosses gets
    // held ∩ requested — monotonic attenuation, never widening. The all-ones
    // sentinel inherits every held right (the pre-QW5 behavior).
    let requested = Rights(rawValue: le32(m, 20))
    if len < 0 { return Errno.invalid.code }

    // The handle (if any) must be a distinct, valid fd before we commit the message.
    if handleFd >= 0 {
        guard validFD(proc, handleFd), handleFd != fd else { return Errno.badFD.code }
        let moved = fdEntry(proc, handleFd)
        guard moved.rights.contains(.transfer) else { return Errno.access.code }
        guard !handleNamesEndpoint(moved, endpoint: ep) else { return Errno.invalid.code }
    }

    let n = min(len, endpointMsgCap)
    if n > 0 {
        guard let src = userReadableBuffer(buf, UInt(n)) else { return Errno.invalid.code }
        let dst = UnsafeMutablePointer<UInt8>(bitPattern: endpoints[ep].bufPtr)!
        for i in 0..<n { dst[i] = src[i] }
    }
    endpoints[ep].msgLen = n
    // QW4: the badge rides from the sender's send-capability to the receiver.
    endpoints[ep].badge = sender.badge

    if handleFd >= 0 {
        // QW5: install a FRESH, attenuated copy of the source entry. The .transfer
        // precondition above guarantees the source could move at all; the
        // intersection only narrows what crosses and can never conjure a right
        // (e.g. .transfer or .write) the sender did not already hold.
        // QW5: the field could later be packed as (rights<<32)|handle_fd for a
        // single-register fast path; the msg struct carries both today.
        var moved = fdEntry(proc, handleFd)             // copy the entry...
        moved.rights = attenuate(moved.rights, to: requested) // ...narrow to held ∩ requested
        endpoints[ep].handle = moved
        endpoints[ep].hasHandle = true
        setFDEntry(proc, handleFd, HandleEntry())       // ...then clear the source (move, no release)
    }
    endpoints[ep].hasMsg = true
    // QW2: wake any receiver parked on this endpoint. Wake happens under the
    // same vfsLock the receiver held when it recorded its waiter slot, closing
    // the lost-wakeup window on SMP. The woken receiver re-checks hasMsg under
    // lock; if it races with another receiver the loser re-parks.
    ipcWakeWaiters(ep)
    return 0
}

/// ipc_recv(fd, &msg) -> byte count: block until a message is in flight, copy up to
/// msg.cap bytes into msg.buf, and — if a handle was transferred — install it as a new
/// fd written to *msg.out_handle_fd (else -1). Errno.pipe.code if every sender closed first
/// (EOF-like). Returns the number of bytes copied to the user buffer.
func vfsIpcRecv(fd: Int, msgVA: UInt) -> Int {
    let proc = currentVFSProcess()
    let borrowed = borrowDescriptionForFD(proc, fd)
    if borrowed.err != 0 { return borrowed.err }
    let entry = borrowed.entry
    let desc = borrowed.desc
    let descIndex = borrowed.descIndex
    defer { releaseBorrowedDescription(descIndex) }
    guard entry.rights.contains(.read) else { return Errno.badFD.code }
    guard desc.kind == .endpoint, desc.pipeEnd == endpointRecvEnd else { return Errno.invalid.code }
    let ep = desc.node

    guard let m = userReadableBuffer(msgVA, ipcRecvMsgSize) else { return Errno.invalid.code }
    let buf = UInt(le64(m, 0))
    let cap = Int(le64(m, 8))
    let outHandleVA = UInt(le64(m, 16))
    // QW4: optional out-badge pointer. 0 = "don't report" (back-compat with the
    // 3-arg ipc_recv wrapper); a non-zero VA is validated before any store.
    let outBadgeVA = UInt(le64(m, 24))
    if cap < 0 { return Errno.invalid.code }
    guard let outHandle = userWritableBuffer(outHandleVA, 4) else { return Errno.invalid.code }
    var outBadge: UnsafeMutablePointer<UInt8>? = nil
    if outBadgeVA != 0 {
        guard let b = userWritableBuffer(outBadgeVA, 4) else { return Errno.invalid.code }
        outBadge = b
    }

    enable_irq()
    // QW2: park/wake loop. The receiver records its process slot under vfsLock
    // and sets pBlocked before unlocking, so ipc_send's ipcWakeWaiters (which
    // also runs under vfsLock) cannot lose the wakeup across CPUs. Spurious
    // wakes are harmless — the loop re-checks hasMsg/sendRefs under lock.
    while true {
        let daif = vfsLock()
        if ep < 0 || ep >= maxEndpoints || !endpoints[ep].inUse {
            vfsUnlock(daif)
            return Errno.invalid.code
        }
        if endpoints[ep].hasMsg {
            let n = min(endpoints[ep].msgLen, cap)
            var newfd: Int32 = -1
            var installed = -1
            if endpoints[ep].hasHandle {
                if !entry.rights.contains(.transfer) {
                    vfsUnlock(daif)
                    return Errno.access.code
                }
                installed = allocFDInProcess(proc, from: 0)
                if installed == -1 {
                    vfsUnlock(daif)
                    return Errno.noSpace.code
                }
            }
            if n > 0 {
                guard let dst = userWritableBuffer(buf, UInt(n)) else {
                    vfsUnlock(daif)
                    return Errno.invalid.code
                }
                let src = UnsafePointer<UInt8>(bitPattern: endpoints[ep].bufPtr)!
                for i in 0..<n { dst[i] = src[i] }
            }
            if endpoints[ep].hasHandle {
                setFDEntry(proc, installed, endpoints[ep].handle)
                newfd = Int32(installed)
            }
            UnsafeMutableRawPointer(outHandle).storeBytes(of: newfd, toByteOffset: 0, as: Int32.self)
            // QW4: report the sending send-capability's badge (0 = unbadged) when
            // the caller supplied a destination, inside the same locked region.
            if let ob = outBadge {
                UnsafeMutableRawPointer(ob).storeBytes(of: endpoints[ep].badge, toByteOffset: 0, as: UInt32.self)
            }

            endpoints[ep].handle = HandleEntry()
            endpoints[ep].hasHandle = false
            endpoints[ep].hasMsg = false
            endpoints[ep].msgLen = 0
            endpoints[ep].badge = 0
            vfsUnlock(daif)
            return n
        }
        if endpoints[ep].sendRefs == 0 {
            vfsUnlock(daif)
            return Errno.pipe.code
        }
        // No message yet and senders are alive: park.
        // Record waiter and set pBlocked under the SAME lock that ipc_send
        // and the close path hold when they call ipcWakeWaiters — this closes
        // the lost-wakeup window on SMP. If the waiter table is full, fall
        // back to the old yield-and-repoll path (correctness preserved).
        let me = Int32(processCurrentSlot())
        if me >= 0 && ipcRecordWaiter(ep, me) {
            // pBlocked must be set while holding vfsLock so the wake side
            // (which also holds vfsLock) sees it consistently.
            if !processPrepareBlockOnFutex() {
                // currentProcessSlot() was invalid — should not happen.
                ipcClearWaiterSlot(ep, me)
                vfsUnlock(daif)
                return Errno.invalid.code
            }
            vfsUnlock(daif)
            processYieldAfterPreparedFutexBlock()
            // Re-enter the loop; re-check hasMsg/sendRefs under lock.
        } else {
            // Waiter slots full — fall back to yield-and-repoll.
            vfsUnlock(daif)
            processYieldForIO()
        }
    }
}

// QW1: synchronous request/reply over a transient reply port. The user-side msg
// structs use fixed little-endian offsets (like ipc_send/ipc_recv); the u64
// fields lead so the trailing i32 needs no struct padding the kernel must skip.
//   CALL  off 0:  buf (u64)        off 8:  len (u64)
//         off 16: reply_buf (u64)  off 24: reply_cap (u64)
//         off 32: out_handle_fd (u64 user VA → i32)   off 40: handle_fd (i32, <0 = none)
//   REPLY_RECV
//         off 0:  reply_port (u64 token, 0 = no reply / first turn)
//         off 8:  reply_buf (u64)  off 16: reply_len (u64)
//         off 24: recv_buf (u64)   off 32: recv_cap (u64)
//         off 40: out_handle_fd (u64 user VA → i32)
//         off 48: out_reply_port (u64 user VA → u64)
//         off 56: reply_handle_fd (i32, <0 = none)
private let ipcCallMsgSize: UInt = 44
private let ipcReplyRecvMsgSize: UInt = 60

/// ipc_call(fd, &msg) -> reply byte count: send up to endpointMsgCap request BYTES
/// (± one moved handle) on an endpoint SEND end, then BLOCK on a freshly minted
/// reply port until the server replies. On wake, copy the reply bytes into
/// reply_buf (≤ reply_cap), install any replied handle as a new fd written to
/// *out_handle_fd (else -1), free the reply port, and return the reply byte count.
/// Errno.again.code if the single-slot channel is busy; Errno.pipe.code if every receiver closes
/// before replying; Errno.noSpace.code if no reply port is free.
func vfsIpcCall(fd: Int, msgVA: UInt) -> Int {
    let proc = currentVFSProcess()
    let me = processCurrentSlot()
    if me < 0 { return Errno.invalid.code }

    guard let m = userReadableBuffer(msgVA, ipcCallMsgSize) else { return Errno.invalid.code }
    let buf = UInt(le64(m, 0))
    let len = Int(le64(m, 8))
    let replyBuf = UInt(le64(m, 16))
    let replyCap = Int(le64(m, 24))
    let outHandleVA = UInt(le64(m, 32))
    let handleFd = Int(Int32(bitPattern: le32(m, 40)))
    if len < 0 || replyCap < 0 { return Errno.invalid.code }
    guard let outHandle = userWritableBuffer(outHandleVA, 4) else { return Errno.invalid.code }

    let portIdx: Int
    let token: UInt64
    do {
        let daif = vfsLock()
        // Validate the send end exactly as ipc_send does.
        guard validFD(proc, fd) else { vfsUnlock(daif); return Errno.badFD.code }
        let sender = fdEntry(proc, fd)
        guard sender.rights.contains(.write) else { vfsUnlock(daif); return Errno.badFD.code }
        guard sender.rights.contains(.transfer) else { vfsUnlock(daif); return Errno.access.code }
        let desc = openDescriptions[sender.object]
        guard desc.kind == .endpoint, desc.pipeEnd == endpointSendEnd else { vfsUnlock(daif); return Errno.invalid.code }
        let ep = desc.node
        guard ep >= 0 && ep < maxEndpoints && endpoints[ep].inUse else { vfsUnlock(daif); return Errno.invalid.code }
        if endpoints[ep].recvRefs == 0 { vfsUnlock(daif); return Errno.pipe.code }
        if endpoints[ep].hasMsg { vfsUnlock(daif); return Errno.again.code }

        // Validate the moved handle (if any) before committing anything.
        if handleFd >= 0 {
            guard validFD(proc, handleFd), handleFd != fd else { vfsUnlock(daif); return Errno.badFD.code }
            let moved = fdEntry(proc, handleFd)
            guard moved.rights.contains(.transfer) else { vfsUnlock(daif); return Errno.access.code }
            guard !handleNamesEndpoint(moved, endpoint: ep) else { vfsUnlock(daif); return Errno.invalid.code }
        }
        // Validate the request payload is readable before minting the port.
        let n = min(len, endpointMsgCap)
        var src: UnsafePointer<UInt8>? = nil
        if n > 0 {
            guard let s = userReadableBuffer(buf, UInt(n)) else { vfsUnlock(daif); return Errno.invalid.code }
            src = s
        }

        // Mint the reply port, then deliver the request (no failure points left).
        let p = allocReplyPort(endpoint: ep, callerSlot: me)
        if p == -1 { vfsUnlock(daif); return Errno.noSpace.code }
        portIdx = p
        token = replyPortToken(p)

        if n > 0, let s = src {
            let dst = UnsafeMutablePointer<UInt8>(bitPattern: endpoints[ep].bufPtr)!
            for i in 0..<n { dst[i] = s[i] }
        }
        endpoints[ep].msgLen = n
        if handleFd >= 0 {
            endpoints[ep].handle = fdEntry(proc, handleFd)
            endpoints[ep].hasHandle = true
            setFDEntry(proc, handleFd, HandleEntry())       // move, no release
        }
        endpoints[ep].replyToken = token
        endpoints[ep].hasMsg = true
        ipcWakeWaiters(ep)                                  // wake a server parked in reply_recv

        // Park on the reply port under the SAME lock the reply side takes, so a
        // reply that races us cannot be lost (mirrors QW2's recv park).
        if !processPrepareBlockOnFutex() {
            // Slot vanished mid-call (should not happen): undo our delivery so the
            // server never sees a request no one is waiting on, then fail.
            if endpoints[ep].hasHandle && endpoints[ep].handle.inUse {
                releaseDescription(endpoints[ep].handle.object)
            }
            endpoints[ep].handle = HandleEntry()
            endpoints[ep].hasHandle = false
            endpoints[ep].hasMsg = false
            endpoints[ep].msgLen = 0
            endpoints[ep].replyToken = 0
            freeReplyPort(portIdx)
            vfsUnlock(daif)
            return Errno.invalid.code
        }
        vfsUnlock(daif)
    }
    processYieldAfterPreparedFutexBlock()

    // Woken: collect the reply, re-validating the port each turn (the caller can
    // be woken spuriously, by a server reply, or by recv-end EOF).
    while true {
        let daif = vfsLock()
        guard portIdx >= 0 && portIdx < maxReplyPorts && replyPorts[portIdx].inUse,
              replyPorts[portIdx].callerSlot == me,
              replyPortToken(portIdx) == token else {
            // Port reclaimed out from under us (e.g. our own teardown raced): gone.
            vfsUnlock(daif)
            return Errno.pipe.code
        }
        let ep = replyPorts[portIdx].endpoint
        if replyPorts[portIdx].hasReply {
            let rn = min(replyPorts[portIdx].replyLen, replyCap)
            var newfd: Int32 = -1
            var installed = -1
            if replyPorts[portIdx].hasHandle {
                installed = allocFDInProcess(proc, from: 0)
                if installed == -1 { vfsUnlock(daif); return Errno.noSpace.code }
            }
            if rn > 0 {
                guard let dst = userWritableBuffer(replyBuf, UInt(rn)) else { vfsUnlock(daif); return Errno.invalid.code }
                let s = UnsafePointer<UInt8>(bitPattern: replyPorts[portIdx].bufPtr)!
                for i in 0..<rn { dst[i] = s[i] }
            }
            if replyPorts[portIdx].hasHandle {
                setFDEntry(proc, installed, replyPorts[portIdx].handle)  // ref moves to the new fd
                newfd = Int32(installed)
            }
            UnsafeMutableRawPointer(outHandle).storeBytes(of: newfd, toByteOffset: 0, as: Int32.self)
            freeReplyPort(portIdx)   // handle (if any) already moved to `installed`
            vfsUnlock(daif)
            return rn
        }
        // No reply yet: if the receiving side is gone, fail; else re-park.
        if ep < 0 || ep >= maxEndpoints || !endpoints[ep].inUse || endpoints[ep].recvRefs == 0 {
            freeReplyPort(portIdx)
            vfsUnlock(daif)
            return Errno.pipe.code
        }
        if !processPrepareBlockOnFutex() { freeReplyPort(portIdx); vfsUnlock(daif); return Errno.invalid.code }
        vfsUnlock(daif)
        processYieldAfterPreparedFutexBlock()
    }
}

/// ipc_reply_recv(fd, &msg) -> request byte count: the server hot loop verb —
/// reply to the previous request (named by msg.reply_port; skipped when it is the
/// 0 sentinel on the first turn), then block for the next request. The reply
/// deposits ≤ endpointMsgCap bytes (± one moved handle) into the named port and
/// wakes its parked caller. The receive phase mirrors ipc_recv (QW2 park/wake) and
/// additionally writes the new request's reply-port token to *out_reply_port so
/// the server can reply to it next turn. A stale/forged token is rejected with
/// Errno.invalid.code; Errno.pipe.code when every sender closes first.
func vfsIpcReplyRecv(fd: Int, msgVA: UInt) -> Int {
    let proc = currentVFSProcess()

    guard let m = userReadableBuffer(msgVA, ipcReplyRecvMsgSize) else { return Errno.invalid.code }
    let replyTokenIn = le64(m, 0)
    let replyBuf = UInt(le64(m, 8))
    let replyLen = Int(le64(m, 16))
    let recvBuf = UInt(le64(m, 24))
    let recvCap = Int(le64(m, 32))
    let outHandleVA = UInt(le64(m, 40))
    let outReplyPortVA = UInt(le64(m, 48))
    let replyHandleFd = Int(Int32(bitPattern: le32(m, 56)))
    if replyLen < 0 || recvCap < 0 { return Errno.invalid.code }
    guard let outHandle = userWritableBuffer(outHandleVA, 4) else { return Errno.invalid.code }
    guard let outReplyPort = userWritableBuffer(outReplyPortVA, 8) else { return Errno.invalid.code }

    // Validate the recv end (server identity) and pin its description for the block.
    let borrowed = borrowDescriptionForFD(proc, fd)
    if borrowed.err != 0 { return borrowed.err }
    let entry = borrowed.entry
    let desc = borrowed.desc
    let descIndex = borrowed.descIndex
    defer { releaseBorrowedDescription(descIndex) }
    guard entry.rights.contains(.read) else { return Errno.badFD.code }
    guard desc.kind == .endpoint, desc.pipeEnd == endpointRecvEnd else { return Errno.invalid.code }
    let ep = desc.node

    // ---- Reply phase: deposit the reply for the previous request, wake caller --
    if replyTokenIn != 0 {
        let daif = vfsLock()
        let pr = decodeReplyPort(replyTokenIn)
        // The port must exist, await a reply, have a live caller, and belong to
        // the endpoint this server actually receives on — so a server cannot
        // reply to another endpoint's caller, and a stale/forged token is refused.
        guard pr >= 0, !replyPorts[pr].hasReply, replyPorts[pr].callerSlot >= 0,
              replyPorts[pr].endpoint == ep else {
            vfsUnlock(daif)
            return Errno.invalid.code
        }
        if replyHandleFd >= 0 {
            guard validFD(proc, replyHandleFd), replyHandleFd != fd else { vfsUnlock(daif); return Errno.badFD.code }
            let moved = fdEntry(proc, replyHandleFd)
            guard moved.rights.contains(.transfer) else { vfsUnlock(daif); return Errno.access.code }
        }
        let rn = min(replyLen, endpointMsgCap)
        if rn > 0 {
            guard let s = userReadableBuffer(replyBuf, UInt(rn)) else { vfsUnlock(daif); return Errno.invalid.code }
            let dst = UnsafeMutablePointer<UInt8>(bitPattern: replyPorts[pr].bufPtr)!
            for i in 0..<rn { dst[i] = s[i] }
        }
        replyPorts[pr].replyLen = rn
        if replyHandleFd >= 0 {
            replyPorts[pr].handle = fdEntry(proc, replyHandleFd)
            replyPorts[pr].hasHandle = true
            setFDEntry(proc, replyHandleFd, HandleEntry())   // move, no release
        }
        replyPorts[pr].hasReply = true
        let waker = replyPorts[pr].callerSlot
        vfsUnlock(daif)
        processWakeFromFutex(waker)
    }

    // ---- Receive phase: block for the next request (mirrors vfsIpcRecv) --------
    enable_irq()
    while true {
        let daif = vfsLock()
        if ep < 0 || ep >= maxEndpoints || !endpoints[ep].inUse {
            vfsUnlock(daif)
            return Errno.invalid.code
        }
        if endpoints[ep].hasMsg {
            let n = min(endpoints[ep].msgLen, recvCap)
            var newfd: Int32 = -1
            var installed = -1
            if endpoints[ep].hasHandle {
                if !entry.rights.contains(.transfer) { vfsUnlock(daif); return Errno.access.code }
                installed = allocFDInProcess(proc, from: 0)
                if installed == -1 { vfsUnlock(daif); return Errno.noSpace.code }
            }
            if n > 0 {
                guard let dst = userWritableBuffer(recvBuf, UInt(n)) else { vfsUnlock(daif); return Errno.invalid.code }
                let s = UnsafePointer<UInt8>(bitPattern: endpoints[ep].bufPtr)!
                for i in 0..<n { dst[i] = s[i] }
            }
            if endpoints[ep].hasHandle {
                setFDEntry(proc, installed, endpoints[ep].handle)
                newfd = Int32(installed)
            }
            UnsafeMutableRawPointer(outHandle).storeBytes(of: newfd, toByteOffset: 0, as: Int32.self)
            // Hand the server this request's reply-port token (0 if it arrived via
            // plain ipc_send, which has no reply port).
            UnsafeMutableRawPointer(outReplyPort).storeBytes(of: endpoints[ep].replyToken, toByteOffset: 0, as: UInt64.self)
            endpoints[ep].handle = HandleEntry()
            endpoints[ep].hasHandle = false
            endpoints[ep].hasMsg = false
            endpoints[ep].msgLen = 0
            endpoints[ep].replyToken = 0
            endpoints[ep].badge = 0   // QW4: don't leak a stale badge to the next recv
            vfsUnlock(daif)
            return n
        }
        if endpoints[ep].sendRefs == 0 {
            vfsUnlock(daif)
            return Errno.pipe.code
        }
        let meSlot = Int32(processCurrentSlot())
        if meSlot >= 0 && ipcRecordWaiter(ep, meSlot) {
            if !processPrepareBlockOnFutex() {
                ipcClearWaiterSlot(ep, meSlot)
                vfsUnlock(daif)
                return Errno.invalid.code
            }
            vfsUnlock(daif)
            processYieldAfterPreparedFutexBlock()
        } else {
            vfsUnlock(daif)
            processYieldForIO()
        }
    }
}

func vfsLseek(fd: Int, offset: Int, whence: Int) -> Int {
    let proc = currentVFSProcess()
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    guard validFD(proc, fd) else { return Errno.badFD.code }
    let entry = fdEntry(proc, fd)
    guard hasRights(entry.rights, .read) || hasRights(entry.rights, .write) else { return Errno.access.code }
    let d = entry.object
    var file = openDescriptions[d]
    guard entry.kind == .file else { return Errno.invalid.code }
    let node = file.node
    var base = 0
    if whence == 1 { base = file.offset }
    else if whence == 2 { base = nodes[node].dataLen }
    else if whence != 0 { return Errno.invalid.code }
    let next = base + offset
    if next < 0 { return Errno.invalid.code }
    file.offset = next
    // Directories track their read position with a separate getdents cursor
    // (file.dirCursor), not the byte offset. Keep it in sync on an absolute
    // seek so rewinddir() (lseek(fd, 0, SEEK_SET)) and seekdir() (lseek to a
    // telldir offset) actually reposition the stream. Without this, a rewind
    // left dirCursor past the end and the next getdents returned nothing — mc's
    // local_opendir() does a probe readdir() then rewinddir(), so it saw every
    // directory as empty (and crashed on "/" once ".." was dropped). Only
    // SEEK_SET is synced: a directory's byte offset isn't advanced by getdents,
    // so SEEK_CUR/SEEK_END would carry a stale base.
    if whence == 0 && nodes[node].isDir { file.dirCursor = next }
    openDescriptions[d] = file
    return next
}

// Kernel stat record (kstat) the newlib/Swift bottom ends translate into their
// own struct stat. 48-byte little-endian layout (grown from 16→24→32→48):
//   off 0  u32 mode    off 4  u32 uid    off 8  u64 size
//   off 16 u32 gid     off 20 u32 nlink  off 24 u64 mtime (Unix seconds)
//   off 32 u64 ino     off 40 u64 dev
// Earlier fields keep their offsets, so older shorter readers stay valid.
//
// `ino`/`dev` MUST be stable identity: SQLite's unix VFS stores st_ino at open
// and later compares it via SQLITE_FCNTL_HAS_MOVED. Uninitialized st_ino made
// that check intermittent (SQLITE_READONLY_DBMOVED → "attempt to write a
// readonly database") between autocommit transactions that re-open the
// rollback journal. See tests/datafs_sqlite_autocommit_test.sh.
private func writeStatMode(_ va: UInt, _ mode: UInt32, _ size: Int,
                           uid: UInt32 = 1, gid: UInt32 = 1, nlink: UInt32 = 1,
                           mtime: UInt64 = 0, ino: UInt64 = 0, dev: UInt64 = 0) -> Int {
    guard let p8 = userWritableBuffer(va, 48) else { return Errno.invalid.code }
    let p = UnsafeMutableRawPointer(p8)
    p.storeBytes(of: mode, toByteOffset: 0, as: UInt32.self)
    p.storeBytes(of: uid, toByteOffset: 4, as: UInt32.self)
    p.storeBytes(of: UInt64(size), toByteOffset: 8, as: UInt64.self)
    p.storeBytes(of: gid, toByteOffset: 16, as: UInt32.self)
    p.storeBytes(of: nlink, toByteOffset: 20, as: UInt32.self)
    p.storeBytes(of: mtime, toByteOffset: 24, as: UInt64.self)
    p.storeBytes(of: ino, toByteOffset: 32, as: UInt64.self)
    p.storeBytes(of: dev, toByteOffset: 40, as: UInt64.self)
    return 0
}

// Files under /bin are programs: report the execute bit so a shell's PATH
// lookup (newlib access(X_OK) → stat) treats them as runnable. Their contents
// are placeholders — execResolve() maps the path to the real baked-in ELF — but
// without an x bit busybox refuses to exec with "Permission denied".
private func nodeIsExecutable(_ node: Int) -> Bool {
    if nodes[node].isDir { return false }
    let parent = nodes[node].parent
    if parent < 0 { return false }
    let bin: StaticString = "bin"
    return bin.withUTF8Buffer { nameEquals(parent, $0.baseAddress!, $0.count) }
}

private func writeStatNode(_ va: UInt, _ node: Int) -> Int {
    // Prefer the node's stored permission bits (disk image / tmpfs); fall back
    // to the heuristic for compiled-in literals, which carry no mode (0).
    let perms: UInt32 = nodes[node].mode != 0
        ? nodes[node].mode
        : (nodes[node].isDir ? 0o755 : (nodeIsExecutable(node) ? 0o755 : 0o644))
    let mode: UInt32 = nodes[node].special != 0
        ? (sIFCHR | perms)
        : ((nodes[node].isDir ? sIFDIR : sIFREG) | perms)
    let owner = nodes[node].owner
    // Stable file identity for SQLite HAS_MOVED / inode-lock tables:
    //   ino = VNode index + 1 (never 0 for a live node)
    //   dev = datafs volume slot + 2, else 1 for base/tmpfs (never 0)
    let ino = UInt64(node) &+ 1
    let dev: UInt64 = nodes[node].dataFs ? UInt64(nodes[node].dfsVolume) &+ 2 : 1
    return writeStatMode(va, mode, nodes[node].dataLen, uid: owner, gid: owner,
                         mtime: nodes[node].mtime, ino: ino, dev: dev)
}

func vfsStat(path pathVA: UInt, statbuf: UInt) -> Int {
    guard let path = userCString(pathVA) else { return Errno.invalid.code }
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    let node = resolve(path)
    if node == -1 { return Errno.noEntry.code }
    if !confinedAllows(node) { return Errno.access.code }
    return writeStatNode(statbuf, node)
}

func vfsFstat(fd: Int, statbuf: UInt) -> Int {
    let proc = currentVFSProcess()
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    guard validFD(proc, fd) else { return Errno.badFD.code }
    let entry = fdEntry(proc, fd)
    guard hasRights(entry.rights, .getattr) else { return Errno.access.code }
    let file = openDescriptions[entry.object]
    let me = processCurrentPrincipal()
    let now = rtcNow()
    if entry.kind == .tty { return writeStatMode(statbuf, sIFCHR | 0o666, 0, uid: me, gid: me, mtime: now) }
    if entry.kind == .ptyMaster || entry.kind == .ptySlave {
        return writeStatMode(statbuf, sIFCHR | 0o666, 0, uid: me, gid: me, mtime: now)
    }
    if entry.kind == .pipe { return writeStatMode(statbuf, sIFIFO | 0o666, 0, uid: me, gid: me, mtime: now) }
    if entry.kind == .event { return writeStatMode(statbuf, sIFIFO | 0o666, 0, uid: me, gid: me, mtime: now) }
    if entry.kind == .file { return writeStatNode(statbuf, file.node) }
    return Errno.badFD.code
}

// dirent: d_ino(8) d_off(8) d_reclen(2) d_type(1) d_name[](NUL-terminated).
func vfsGetdents(fd: Int, buffer: UInt, count: UInt) -> Int {
    if count == 0 { return 0 }
    let proc = currentVFSProcess()
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    guard validFD(proc, fd) else { return Errno.badFD.code }
    let entry = fdEntry(proc, fd)
    guard hasRights(entry.rights, .read) else { return Errno.badFD.code }
    let d = entry.object
    var file = openDescriptions[d]
    guard entry.kind == .file else { return Errno.invalid.code }
    let dir = file.node
    if !nodes[dir].isDir { return Errno.invalid.code }
    guard let b = userWritableBuffer(buffer, count) else { return Errno.invalid.code }
    let buf = UnsafeMutableRawPointer(b)

    var child = nodes[dir].firstChild
    var skip = file.dirCursor
    while skip > 0 && child != -1 { child = nodes[child].nextSibling; skip -= 1 }

    var used = 0
    while child != -1 {
        let nameLen = nodes[child].nameLen
        let reclen = (19 + nameLen + 1 + 7) & ~7
        if used + reclen > Int(count) { break }

        let rec = buf.advanced(by: used)
        rec.storeBytes(of: UInt64(child + 1), toByteOffset: 0, as: UInt64.self)
        rec.storeBytes(of: UInt64(file.dirCursor + 1), toByteOffset: 8, as: UInt64.self)
        rec.storeBytes(of: UInt16(reclen), toByteOffset: 16, as: UInt16.self)
        rec.storeBytes(of: nodes[child].isDir ? dtDir : dtReg, toByteOffset: 18, as: UInt8.self)
        let np = UnsafePointer<UInt8>(bitPattern: nodes[child].namePtr)!
        let nameDst = rec.advanced(by: 19).assumingMemoryBound(to: UInt8.self)
        for i in 0..<nameLen { nameDst[i] = np[i] }
        nameDst[nameLen] = 0

        used += reclen
        file.dirCursor += 1
        child = nodes[child].nextSibling
    }
    openDescriptions[d] = file
    return used
}

func vfsChdir(path pathVA: UInt) -> Int {
    guard let path = userCString(pathVA) else { return Errno.invalid.code }
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    let node = resolve(path)
    if node == -1 { return Errno.noEntry.code }
    if !confinedAllows(node) { return Errno.access.code }
    if !nodes[node].isDir { return Errno.notDir.code }
    setCwdNode(currentVFSProcess(), node)
    return 0
}

// C3: confine this process's filesystem access to a subtree (object-scoped
// authority). Confine-only: the new root must lie within the current confinement,
// so a confined process cannot widen its own reach. Once set, vfsOpen denies any
// path outside the subtree. See docs/CAPABILITIES.md §6 (C3).
func vfsConfine(path pathVA: UInt) -> Int {
    guard let path = userCString(pathVA) else { return Errno.invalid.code }
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    let node = resolve(path)
    if node == -1 { return Errno.noEntry.code }
    if !nodes[node].isDir { return Errno.notDir.code }
    let proc = currentVFSProcess()
    if !isDescendant(node, of: confineNode(proc)) { return Errno.access.code }
    setConfineNode(proc, node)
    if !isDescendant(cwdNode(proc), of: node) { setCwdNode(proc, node) }
    return 0
}

func vfsGetcwd(buffer: UInt, size: UInt) -> Int {
    guard size > 0, let buf = userWritableBuffer(buffer, size) else {
        return Errno.invalid.code
    }

    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    let cwdNode = cwdNodeForCurrentProcess()
    if cwdNode == 0 {
        if size < 2 { return Errno.noSpace.code }
        buf[0] = 0x2F; buf[1] = 0
        return 1
    }

    var chain = [Int](repeating: 0, count: 32)
    var depth = 0
    var n = cwdNode
    while n != 0 && depth < 32 {
        chain[depth] = n
        depth += 1
        n = nodes[n].parent
    }

    var pos = 0
    var d = depth - 1
    while d >= 0 {
        if pos + 1 >= Int(size) { return Errno.noSpace.code }
        buf[pos] = 0x2F; pos += 1
        let node = chain[d]
        let np = UnsafePointer<UInt8>(bitPattern: nodes[node].namePtr)!
        let nl = nodes[node].nameLen
        if pos + nl + 1 >= Int(size) { return Errno.noSpace.code }
        for i in 0..<nl { buf[pos] = np[i]; pos += 1 }
        d -= 1
    }
    buf[pos] = 0
    return pos
}

// M13b: every namespace mutation lands in the tmpfs (the base is read-only), so
// it needs capTmpWrite. open(O_CREAT) is gated in vfsOpen; these path-based
// syscalls are gated here.
private func mayWriteTmp() -> Bool { (processCurrentCaps() & capTmpWrite) != 0 }

func vfsUnlink(path pathVA: UInt) -> Int {
    guard let path = userCString(pathVA) else { return Errno.invalid.code }
    if !mayWriteTmp() { return Errno.access.code }
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    let node = resolve(path)
    if node == -1 { return Errno.noEntry.code }
    if !confinedAllows(node) { return Errno.access.code }
    if nodes[node].isDir { return Errno.isDir.code }
    let parent = nodes[node].parent
    if nodes[parent].readOnly { return Errno.readOnly.code }
    if nodes[node].dataFs { _ = datafsRemove(nodes[node].dfsVolume, nodes[node].dfsInode) }
    _ = unlinkChild(parent, node)
    return 0
}

func vfsMkdir(path pathVA: UInt) -> Int {
    guard let path = userCString(pathVA) else { return Errno.invalid.code }
    if !mayWriteTmp() { return Errno.access.code }
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    // An existing path (including "/") is EEXIST, not ENOENT — `mkdir -p` walks
    // ancestors and expects EEXIST on the ones that already exist.
    if resolve(path) != -1 { return Errno.exists.code }
    var ls = 0, ll = 0
    let parent = resolveParent(path, &ls, &ll)
    if parent == -1 { return Errno.noEntry.code }
    if !confinedAllows(parent) { return Errno.access.code }
    if nodes[parent].readOnly { return Errno.readOnly.code }
    if findChild(parent, path + ls, ll) != -1 { return Errno.exists.code }
    let made = nodes[parent].dataFs
        ? createDataFsNode(parent, path + ls, ll, isDir: true)
        : createTmpNode(parent, path + ls, ll, isDir: true)
    return made == -1 ? Errno.noSpace.code : 0
}

func vfsRmdir(path pathVA: UInt) -> Int {
    guard let path = userCString(pathVA) else { return Errno.invalid.code }
    if !mayWriteTmp() { return Errno.access.code }
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    let node = resolve(path)
    if node <= 0 { return Errno.invalid.code }
    if !confinedAllows(node) { return Errno.access.code }
    if !nodes[node].isDir { return Errno.notDir.code }
    if nodes[node].firstChild != -1 { return Errno.notEmpty.code }
    let parent = nodes[node].parent
    if nodes[parent].readOnly { return Errno.readOnly.code }
    if nodes[node].dataFs { _ = datafsRemove(nodes[node].dfsVolume, nodes[node].dfsInode) }
    _ = unlinkChild(parent, node)
    return 0
}

func vfsRename(old oldVA: UInt, new newVA: UInt) -> Int {
    guard let oldPath = userCString(oldVA), let newPath = userCString(newVA) else {
        return Errno.invalid.code
    }
    if !mayWriteTmp() { return Errno.access.code }
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    let src = resolve(oldPath)
    if src <= 0 { return Errno.noEntry.code }
    if !confinedAllows(src) { return Errno.access.code }

    var nls = 0, nll = 0
    let dstParent = resolveParent(newPath, &nls, &nll)
    if dstParent == -1 { return Errno.noEntry.code }
    if !confinedAllows(dstParent) { return Errno.access.code }
    let srcParent = nodes[src].parent
    if nodes[srcParent].readOnly || nodes[dstParent].readOnly { return Errno.readOnly.code }
    // No cross-filesystem rename (datafs <-> tmpfs, or across datafs volumes,
    // would need a copy).
    if nodes[src].dataFs != nodes[dstParent].dataFs { return Errno.invalid.code }
    if nodes[src].dataFs && nodes[src].dfsVolume != nodes[dstParent].dfsVolume { return Errno.invalid.code }
    if nodes[src].isDir && isDescendant(dstParent, of: src) { return Errno.invalid.code }

    let existing = findChild(dstParent, newPath + nls, nll)
    if existing == src { return 0 }
    if existing != -1 {
        if nodes[existing].isDir != nodes[src].isDir { return Errno.invalid.code }
        if nodes[existing].isDir && nodes[existing].firstChild != -1 { return Errno.notEmpty.code }
        if nodes[existing].dataFs { _ = datafsRemove(nodes[existing].dfsVolume, nodes[existing].dfsInode) }
        _ = unlinkChild(dstParent, existing)
    }

    _ = unlinkChild(srcParent, src)
    if !setNameCopy(src, newPath + nls, nll) { return Errno.noMem.code }
    linkChild(dstParent, src)
    if nodes[src].dataFs {
        _ = datafsSetParentName(nodes[src].dfsVolume, nodes[src].dfsInode, nodes[dstParent].dfsInode, newPath + nls, nll)
    }
    return 0
}

// chmod/chown — change a tmpfs node's permission bits / owning principal. The
// base FS is read-only, so only tmpfs nodes are mutable; like the other
// namespace mutations (M13b) this requires capTmpWrite. Cosmetic for ls -l,
// since tmpfs is ephemeral, but completes the M13c ownership story.
func vfsChmod(path pathVA: UInt, mode: UInt) -> Int {
    guard let path = userCString(pathVA) else { return Errno.invalid.code }
    if !mayWriteTmp() { return Errno.access.code }
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    let node = resolve(path)
    if node == -1 { return Errno.noEntry.code }
    if !confinedAllows(node) { return Errno.access.code }
    if nodes[node].readOnly { return Errno.readOnly.code }
    nodes[node].mode = UInt32(mode & 0o7777)
    return 0
}

func vfsChown(path pathVA: UInt, owner: UInt) -> Int {
    guard let path = userCString(pathVA) else { return Errno.invalid.code }
    if !mayWriteTmp() { return Errno.access.code }
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    let node = resolve(path)
    if node == -1 { return Errno.noEntry.code }
    if !confinedAllows(node) { return Errno.access.code }
    if nodes[node].readOnly { return Errno.readOnly.code }
    nodes[node].owner = UInt32(truncatingIfNeeded: owner)
    return 0
}

private func pollReadyForDescription(_ desc: OpenDescription, kind: HandleKind,
                                     rights: Rights, events: Int16) -> Int16 {
    var revents: Int16 = 0
    if kind == .tty {
        if (events & pollIn) != 0 && rights.contains(.read) && ttyReadable() { revents |= pollIn }
        if (events & pollOut) != 0 && rights.contains(.write) { revents |= pollOut }
        return revents
    }
    if kind == .file {
        if (events & pollIn) != 0 && rights.contains(.read) { revents |= pollIn }
        if (events & pollOut) != 0 && rights.contains(.write) { revents |= pollOut }
        return revents
    }
    if kind == .socket {
        if (events & pollIn) != 0 && rights.contains(.read) && socketPollReadable(desc.node) { revents |= pollIn }
        if (events & pollOut) != 0 && rights.contains(.write) && socketPollWritable(desc.node) { revents |= pollOut }
        return revents
    }
    if kind == .pipe {
        let p = desc.pipe
        let wp = desc.pipeEnd == pipeDuplexEnd ? desc.writePipe : desc.pipe
        if p < 0 || p >= maxPipes || !pipes[p].inUse { return pollNval }
        if wp < 0 || wp >= maxPipes || !pipes[wp].inUse { return pollNval }
        if (events & pollIn) != 0 && rights.contains(.read) {
            if pipeCount(p) > 0 || pipes[p].writeRefs == 0 { revents |= pollIn }
        }
        if (events & pollOut) != 0 && rights.contains(.write) {
            if pipes[wp].readRefs == 0 { revents |= pollErr }
            else if pipeSpace(wp) > 0 { revents |= pollOut }
        }
        if desc.pipeEnd == pipeDuplexEnd {
            if pipes[p].writeRefs == 0 { revents |= pollHup }
            if pipes[wp].readRefs == 0 { revents |= pollErr }
            return revents
        }
        if desc.pipeEnd == pipeReadEnd && pipes[p].writeRefs == 0 { revents |= pollHup }
        if desc.pipeEnd == pipeWriteEnd && pipes[p].readRefs == 0 { revents |= pollErr }
        return revents
    }
    if kind == .ptyMaster {
        let p = desc.pty
        if !ptyValid(p) { return pollNval }
        if (events & pollIn) != 0 && rights.contains(.read) {
            if ptyOutCount(p) > 0 || ptySlaveRefs(p) == 0 { revents |= pollIn }
        }
        if (events & pollOut) != 0 && rights.contains(.write) { revents |= pollOut }
        if ptySlaveRefs(p) == 0 { revents |= pollHup }
        return revents
    }
    if kind == .ptySlave {
        let p = desc.pty
        if !ptyValid(p) { return pollNval }
        if (events & pollIn) != 0 && rights.contains(.read) {
            if ptyCookedCount(p) > 0 || ptyMasterRefs(p) == 0 { revents |= pollIn }
        }
        if (events & pollOut) != 0 && rights.contains(.write) { revents |= pollOut }
        if ptyMasterRefs(p) == 0 { revents |= pollHup }
        return revents
    }
    if kind == .endpoint {
        let ep = desc.node
        if ep < 0 || ep >= maxEndpoints || !endpoints[ep].inUse { return pollNval }
        if desc.pipeEnd == endpointRecvEnd {
            let canReceivePending = rights.contains(.read) &&
                (!endpoints[ep].hasHandle || rights.contains(.transfer))
            if (events & pollIn) != 0 && canReceivePending {
                if endpoints[ep].hasMsg || endpoints[ep].sendRefs == 0 { revents |= pollIn }
            }
            if endpoints[ep].sendRefs == 0 { revents |= pollHup }
        } else {
            if endpoints[ep].recvRefs == 0 {
                revents |= pollErr
            } else if (events & pollOut) != 0 && rights.contains(.write) &&
                        rights.contains(.transfer) && !endpoints[ep].hasMsg {
                revents |= pollOut
            }
        }
        return revents
    }
    if kind == .event {
        let ev = desc.node
        if ev < 0 || ev >= maxEvents || !eventCounters[ev].inUse { return pollNval }
        if (events & pollIn) != 0 && rights.contains(.read) && eventCounters[ev].counter > 0 {
            revents |= pollIn
        }
        if (events & pollOut) != 0 && rights.contains(.write) &&
            eventCounters[ev].counter < eventMaxCounter {
            revents |= pollOut
        }
        return revents
    }
    return pollNval
}

private func pollScan(_ base: UnsafeMutableRawPointer, _ nfds: Int) -> Int {
    let proc = currentVFSProcess()
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    var ready = 0
    for i in 0..<nfds {
        let rec = base.advanced(by: i * pollfdSize)
        let fd = Int(rec.load(fromByteOffset: 0, as: Int32.self))
        let events = rec.load(fromByteOffset: 4, as: Int16.self)
        var revents: Int16 = 0
        if fd < 0 {
            revents = 0
        } else if !validFD(proc, fd) {
            revents = pollNval
        } else {
            let e = fdEntry(proc, fd)
            revents = pollReadyForDescription(openDescriptions[e.object], kind: e.kind,
                                              rights: e.rights, events: events)
        }
        rec.storeBytes(of: revents, toByteOffset: 6, as: Int16.self)
        if revents != 0 { ready += 1 }
    }
    return ready
}

func vfsPoll(fds fdsVA: UInt, nfds: UInt, timeout: Int) -> Int {
    if nfds == 0 { return 0 }
    if nfds > UInt(maxFDs) { return Errno.invalid.code }
    guard let buf = userWritableBuffer(fdsVA, nfds * UInt(pollfdSize)) else { return Errno.invalid.code }
    let base = UnsafeMutableRawPointer(buf)
    let count = Int(nfds)
    let startTicks = systemTicks
    let timeoutTicks: UInt64 = timeout <= 0 ? 0 : UInt64((timeout + 9) / 10)

    // How we wait when no fd is ready yet:
    //   - tty/vnode fds become ready via the UART RX IRQ (or the timer for the
    //     timeout), so we block with `wfi()` exactly like ttyRead — no scheduler
    //     yield, so a single foreground reader does not busy-spin.
    //   - a pipe or endpoint only becomes ready when *another* process writes,
    //     sends, receives, or closes its peer, so we must yield the CPU
    //     (processYieldForIO) to let that peer run. That cooperative-yield-from-
    //     a-blocking-syscall path is now preemption-safe (yieldToScheduler masks
    //     IRQs across the switch — see process.swift).
    let proc = currentVFSProcess()
    var hasPeerDriven = false
    var hasSocket = false
    let daif = vfsLock()
    for i in 0..<count {
        let fd = Int(base.advanced(by: i * pollfdSize).load(fromByteOffset: 0, as: Int32.self))
        if fd >= 0 && validFD(proc, fd) {
            let kind = fdEntry(proc, fd).kind
            if kind == .pipe || kind == .endpoint || kind == .event { hasPeerDriven = true }
            if kind == .socket { hasSocket = true }
        }
    }
    vfsUnlock(daif)

    enable_irq()
    while true {
        if hasSocket { netPump() }   // a socket only becomes ready when the NIC is drained
        let ready = pollScan(base, count)
        if ready > 0 || timeout == 0 { return ready }
        if timeout > 0 && systemTicks - startTicks >= timeoutTicks { return 0 }
        if hasPeerDriven { processYieldForIO() } else { wfi() }
    }
}

// ---- UDP sockets (net-b) --------------------------------------------------
//
// Sockets are ordinary fds (HandleKind .socket) whose OpenDescription.node
// indexes the kernel socket table (kernel/net/socket.swift). socket() is gated on capNet;
// sendto/recvfrom pass their extra arguments in a small user struct (the 3-arg
// syscall ABI), copied/validated through user_access.

// Recvfrom blocks until a datagram arrives, bounded so a test can never hang.
private let socketRecvTimeoutMs = 12000

// Layout of the user `swiftos_udp_msg` struct (little-endian, native):
//   off 0: buf (u64 user VA)   off 8: len (u32)   off 12: ip (u32, host order)
//   off 16: port (u16)
// For AF_INET6 sockets we use an extended layout (detected by socket family):
//   off 0: buf (u64)  off 8: len (u32)  off 12: ip6[16]  off 28: port (u16)  off 30: scope_id (u32)
// Total 34 bytes for the v6 form. v4 sockets continue to use the 18-byte form.
private let udpMsgSize: UInt = 18
private let udpMsgSizeV6: UInt = 34

// Socket type (matches the userland constants): SOCK_STREAM = TCP, else UDP.
private let sockTypeStream = 1

func vfsSocket(domain: Int, type: Int, proto: Int) -> Int {
    if (processCurrentCaps() & capNet) == 0 { return Errno.access.code }
    let isV6 = (domain == AF_INET6)
    let s = type == sockTypeStream
        ? (isV6 ? socketCreateTCPIPv6(owner: processCurrentPrincipal())
                : socketCreateTCP(owner: processCurrentPrincipal()))
        : (isV6 ? socketCreateIPv6(owner: processCurrentPrincipal())
                : socketCreate(owner: processCurrentPrincipal()))
    if s < 0 { return s }
    return installSocketFD(s)
}

/// Bind an allocated socket index to a fresh fd backed by a socket description.
private func installSocketFD(_ s: Int, flags: Int = 0) -> Int {
    let proc = currentVFSProcess()
    let daif = vfsLock()
    let fd = allocUserFD(proc, from: 3)   // C7b: cell handle cap (EMFILE for socket/accept)
    if fd < 0 {
        vfsUnlock(daif)
        socketClose(s)
        return fd
    }
    let d = allocDescription()
    if d < 0 {
        vfsUnlock(daif)
        socketClose(s)
        return Errno.noSpace.code
    }
    openDescriptions[d].kind = .socket
    openDescriptions[d].node = s
    openDescriptions[d].flags = flags
    installDescription(proc, fd, d, rights: posixRights(read: true, write: true))
    vfsUnlock(daif)
    return fd
}

// Stream accept/recv block until ready, bounded so a test can never hang.
private let socketAcceptTimeoutMs = 15000

func vfsListen(fd: Int, backlog: Int) -> Int {
    let borrowed = borrowSocketForFD(currentVFSProcess(), fd, required: .write)
    if borrowed.err != 0 { return Errno.badFD.code }
    defer { releaseBorrowedDescription(borrowed.descIndex) }
    return tcpListen(borrowed.socket, backlog: backlog)
}

func vfsAccept(fd: Int) -> Int {
    let proc = currentVFSProcess()
    let borrowed = borrowSocketForFD(proc, fd, required: .read)
    if borrowed.err != 0 { return Errno.badFD.code }
    defer { releaseBorrowedDescription(borrowed.descIndex) }
    let s = borrowed.socket
    guard socketIsTCP(s) && socketIsListener(s) else { return Errno.invalid.code }
    let childFlags = borrowed.flags & mutableStatusFlags
    if (borrowed.flags & oNonblock) != 0 {
        netPump()
        if !socketPollReadable(s) { return Errno.again.code }
    }
    let c = tcpAccept(s, timeoutMs: socketAcceptTimeoutMs)
    if c < 0 { return c }
    return installSocketFD(c, flags: childFlags)
}

func vfsConnect(fd: Int, ip: UInt, port: Int) -> Int {
    let borrowed = borrowSocketForFD(currentVFSProcess(), fd, required: .write)
    if borrowed.err != 0 { return Errno.badFD.code }
    defer { releaseBorrowedDescription(borrowed.descIndex) }
    let s = borrowed.socket
    if port <= 0 || port > 65535 { return Errno.invalid.code }
    // For IPv6 sockets the simple u32 'ip' path is not used (userland must use a v6-aware connect).
    // We still support the old path for AF_INET sockets.
    if socketFamilyOf(s) == AF_INET6 {
        // v6 connect is done via a different path in practice (extended user struct or dedicated helper).
        // For now fall back to the IPv4 engine (will be rejected by socket layer if family mismatch).
    }
    return socketConnect(s, dstIP: UInt32(truncatingIfNeeded: ip), dstPort: UInt16(port),
                         timeoutMs: socketAcceptTimeoutMs)
}

// Recursive DNS resolve. Returns the IPv4 (host order) as the syscall value,
// or 0 on failure (a value return, not an errno). Gated on capNet.
private let socketResolveTimeoutMs = 5000

func vfsResolve(nameVA: UInt, serverIP: UInt, serverPort: Int) -> Int {
    if (processCurrentCaps() & capNet) == 0 { return 0 }
    guard let name = userCString(nameVA) else { return 0 }
    var n = 0
    while name[n] != 0 { n += 1 }
    if n == 0 || n > 255 { return 0 }
    let port = (serverPort > 0 && serverPort <= 65535) ? UInt16(serverPort) : UInt16(0)
    let ip = dnsResolve(name: UnsafeRawPointer(name), nameLen: n,
                        serverIP: UInt32(truncatingIfNeeded: serverIP), serverPort: port,
                        timeoutMs: socketResolveTimeoutMs)
    return Int(ip)
}

func vfsSocketBind(fd: Int, port: Int) -> Int {
    let borrowed = borrowSocketForFD(currentVFSProcess(), fd, required: .write)
    if borrowed.err != 0 { return Errno.badFD.code }
    defer { releaseBorrowedDescription(borrowed.descIndex) }
    let s = borrowed.socket
    if port < 0 || port > 65535 { return Errno.invalid.code }
    return socketBind(s, port: UInt16(port))
}

func vfsSendto(fd: Int, msgVA: UInt) -> Int {
    let borrowed = borrowSocketForFD(currentVFSProcess(), fd, required: .write)
    if borrowed.err != 0 { return Errno.badFD.code }
    defer { releaseBorrowedDescription(borrowed.descIndex) }
    let s = borrowed.socket
    let isV6 = (socketFamilyOf(s) == AF_INET6)
    let need = isV6 ? udpMsgSizeV6 : udpMsgSize
    guard let m = userReadableBuffer(msgVA, need) else { return Errno.invalid.code }

    if isV6 {
        let buf = UInt(le64(m, 0))
        let len = Int(le32(m, 8))
        if len < 0 || len > 65507 { return Errno.invalid.code }
        var ip6b: [UInt8] = []
        var k = 0
        while k < 16 { ip6b.append(m[12 + k]); k += 1 }
        let dst6 = IPv6(ip6b)
        let port = UInt16(m[28]) | (UInt16(m[29]) << 8)
        if len == 0 {
            return socketSendv6(s, dstIPv6: dst6, dstPort: port, src: UnsafeRawPointer(m), len: 0)
        }
        guard let payload = userReadableBuffer(buf, UInt(len)) else { return Errno.invalid.code }
        return socketSendv6(s, dstIPv6: dst6, dstPort: port, src: UnsafeRawPointer(payload), len: len)
    }

    // IPv4 classic path
    let buf = UInt(le64(m, 0))
    let len = Int(le32(m, 8))
    let ip = le32(m, 12)
    let port = UInt16(m[16]) | (UInt16(m[17]) << 8)
    if len < 0 || len > 65507 { return Errno.invalid.code }
    if len == 0 {
        return socketSend(s, dstIP: ip, dstPort: port, src: UnsafeRawPointer(m), len: 0)
    }
    guard let payload = userReadableBuffer(buf, UInt(len)) else { return Errno.invalid.code }
    return socketSend(s, dstIP: ip, dstPort: port, src: UnsafeRawPointer(payload), len: len)
}

func vfsRecvfrom(fd: Int, msgVA: UInt) -> Int {
    let borrowed = borrowSocketForFD(currentVFSProcess(), fd, required: .read)
    if borrowed.err != 0 { return Errno.badFD.code }
    defer { releaseBorrowedDescription(borrowed.descIndex) }
    let s = borrowed.socket
    let isV6 = (socketFamilyOf(s) == AF_INET6)
    let need = isV6 ? udpMsgSizeV6 : udpMsgSize
    guard let m = userWritableBuffer(msgVA, need) else { return Errno.invalid.code }
    let buf = UInt(le64(m, 0))
    let cap = Int(le32(m, 8))
    if cap < 0 || cap > 65507 { return Errno.invalid.code }
    guard let dst = userWritableBuffer(buf, UInt(cap)) else { return Errno.invalid.code }

    if isV6 {
        var srcIP6 = IPv6()
        var srcPort: UInt16 = 0
        let n = socketRecvV6(s, dst: UnsafeMutableRawPointer(dst), cap: cap,
                             srcIPv6: &srcIP6, srcPort: &srcPort, timeoutMs: socketRecvTimeoutMs)
        if n < 0 { return n }
        let un = UInt32(n)
        m[8]  = UInt8(un & 0xFF); m[9] = UInt8((un >> 8) & 0xFF)
        m[10] = UInt8((un >> 16) & 0xFF); m[11] = UInt8((un >> 24) & 0xFF)
        // 16-byte IPv6
        let bytes: [UInt8] = [srcIP6.b0, srcIP6.b1, srcIP6.b2, srcIP6.b3,
                              srcIP6.b4, srcIP6.b5, srcIP6.b6, srcIP6.b7,
                              srcIP6.b8, srcIP6.b9, srcIP6.b10, srcIP6.b11,
                              srcIP6.b12, srcIP6.b13, srcIP6.b14, srcIP6.b15]
        var k = 0
        while k < 16 { m[12 + k] = bytes[k]; k += 1 }
        m[28] = UInt8(srcPort & 0xFF); m[29] = UInt8((srcPort >> 8) & 0xFF)
        m[30] = 0; m[31] = 0; m[32] = 0; m[33] = 0
        return n
    }

    var srcIP: IPv4 = 0
    var srcPort: UInt16 = 0
    let n = socketRecv(s, dst: UnsafeMutableRawPointer(dst), cap: cap,
                       srcIP: &srcIP, srcPort: &srcPort, timeoutMs: socketRecvTimeoutMs)
    if n < 0 { return n }
    let un = UInt32(n)
    m[8]  = UInt8(un & 0xFF);        m[9]  = UInt8((un >> 8) & 0xFF)
    m[10] = UInt8((un >> 16) & 0xFF); m[11] = UInt8((un >> 24) & 0xFF)
    m[12] = UInt8(srcIP & 0xFF);      m[13] = UInt8((srcIP >> 8) & 0xFF)
    m[14] = UInt8((srcIP >> 16) & 0xFF); m[15] = UInt8((srcIP >> 24) & 0xFF)
    m[16] = UInt8(srcPort & 0xFF);    m[17] = UInt8((srcPort >> 8) & 0xFF)
    return n
}

// ---- executable lookup (M11d) ---------------------------------------------

/// Resolve an absolute kernel path to an executable disk-backed file's extent.
/// Returns (found, image, diskByteOffset, length); found is false for a missing
/// path, directory, RAM-backed node, or non-executable file. Lets the ELF loader
/// pull a program straight off the packed base/package images instead of an
/// embedded blob.
func vfsDiskImageExtent(_ path: UnsafePointer<UInt8>)
    -> (found: Bool, image: Int, offset: Int, len: Int, setuid: Bool, owner: UInt32) {
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    let node = resolve(path)
    if node < 0 { return (false, 0, 0, 0, false, 0) }
    if !confinedAllows(node) { return (false, 0, 0, 0, false, 0) }
    if nodes[node].isDir || !nodes[node].onDisk { return (false, 0, 0, 0, false, 0) }
    if (nodes[node].mode & 0o111) == 0 { return (false, 0, 0, 0, false, 0) }
    // I8: an executable from a signed image must match its content hash before load.
    if !vfsVerifyNodeContent(node) { return (false, 0, 0, 0, false, 0) }
    // setuid-on-exec is honored only for read-only base-image files (the signed
    // trust root); a setuid bit on a tmpfs file is meaningless and ignored.
    let setuid = nodes[node].readOnly && (nodes[node].mode & modeSetuid) != 0
    return (true, nodes[node].diskImage, nodes[node].diskOffset, nodes[node].dataLen,
            setuid, nodes[node].owner)
}

/// Read a small kernel-owned config file from the mounted VFS namespace.
/// This bypasses user capability checks and is intended only for boot-time
/// kernel configuration after `vfsInit()` has mounted the signed base image.
func vfsReadStaticFile(_ path: StaticString,
                       into dst: UnsafeMutableRawPointer?,
                       cap: Int) -> Int {
    if cap < 0 { return Errno.invalid.code }
    var name = [UInt8](repeating: 0, count: path.utf8CodeUnitCount + 1)
    path.withUTF8Buffer { b in
        for i in 0..<b.count { name[i] = b[i] }
    }

    return name.withUnsafeBufferPointer { bp -> Int in
        let daif = vfsLock()
        let node = resolve(bp.baseAddress!)
        if node < 0 {
            vfsUnlock(daif)
            return Errno.noEntry.code
        }
        if nodes[node].isDir {
            vfsUnlock(daif)
            return Errno.isDir.code
        }
        let len = nodes[node].dataLen
        if len > cap {
            vfsUnlock(daif)
            return Errno.noSpace.code
        }
        guard let out = dst else {
            vfsUnlock(daif)
            return len == 0 ? 0 : Errno.invalid.code
        }
        if nodes[node].onDisk {
            if !vfsVerifyNodeContent(node) {
                vfsUnlock(daif)
                return Errno.access.code
            }
            let image = nodes[node].diskImage
            let off = nodes[node].diskOffset
            vfsUnlock(daif)
            return vfsImageReadRange(image, UInt64(off), out, UInt32(len)) == 0 ? len : Errno.invalid.code
        }
        let src = UnsafePointer<UInt8>(bitPattern: nodes[node].dataPtr)
        var i = 0
        while i < len {
            out.storeBytes(of: src![i], toByteOffset: i, as: UInt8.self)
            i += 1
        }
        vfsUnlock(daif)
        return len
    }
}

/// I2a: on-disk extent of a disk-backed, readable regular file open on `fd`, for
/// file-backed mmap. Returns (ok, diskByteOffset, dataLen); ok is false unless
/// `fd` is a readable, disk-backed (read-only base image) regular file. Authority
/// was already checked at open time, so no re-confinement check here.
func vfsFileExtent(fd: Int) -> (Bool, Int, Int, Int) {
    let proc = currentVFSProcess()
    let daif = vfsLock()
    defer { vfsUnlock(daif) }
    guard validFD(proc, fd) else { return (false, 0, 0, 0) }
    let entry = fdEntry(proc, fd)
    guard entry.kind == .file, entry.rights.contains(.read) else { return (false, 0, 0, 0) }
    let node = openDescriptions[entry.object].node
    guard node >= 0, !nodes[node].isDir, nodes[node].onDisk else { return (false, 0, 0, 0) }
    // I8: mmap'd content must match its signed hash too (cached after open).
    if !vfsVerifyNodeContent(node) { return (false, 0, 0, 0) }
    return (true, nodes[node].diskImage, nodes[node].diskOffset, nodes[node].dataLen)
}
