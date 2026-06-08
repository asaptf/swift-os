// SPDX-License-Identifier: Apache-2.0
// vfs.swift — a small in-memory VFS: read-only base tree + writable tmpfs.
//
// The filesystem is a fixed vnode table linked as parent/child/sibling. The
// read-only base is built at init; /tmp is RAM tmpfs. File descriptors point at
// shared open-file descriptions, so dup/fork share offsets and pipe state.
//
// Implements: open, read, write, close, lseek, stat, fstat, getdents, chdir,
// getcwd, dup, dup2, pipe, poll, unlink, rename, mkdir, rmdir.

// errno-ish returns (negative).
private let errNoEntry = -2
private let errBadFD = -9
private let errAccess = -13
private let errAgain = -11
private let errNoMem = -12
private let errExists = -17
private let errNotDir = -20
private let errIsDir = -21
private let errInvalid = -22
private let errNoSpace = -28
private let errReadOnly = -30
private let errPipe = -32
private let errNotEmpty = -39

// Open flags (our ABI; userland lib/fs.h must match). The newlib bottom end
// (userland/lib/newlib_syscalls.c) translates newlib's BSD-style O_* values
// into these before the SYS_OPEN trap.
let oWrOnly = 1
let oRdWr = 2
let oCreat = 0x40
let oTrunc = 0x80
let oAppend = 0x100
let oCloexec = 0x200

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
    var diskOffset = 0      // byte offset of contents within the disk image
    var owner: UInt32 = 1   // owning principal (M13c); 1 = root/boot principal
    var mode: UInt32 = 0    // permission bits (M13c); 0 = unset → use heuristic
    var mtime: UInt64 = 0   // modification time, Unix seconds (0 = unknown)
    var parent = -1
    var firstChild = -1
    var nextSibling = -1
}

private let maxNodes = 96
private var nodes: UnsafeMutablePointer<VNode>! = nil
private var nodeCount = 0

// ---- open files, fd table, pipes -----------------------------------------

// Handle kinds live in handle.swift (HandleKind): .none/.tty/.file/.pipe/.socket,
// 1:1 with the former fdKind* constants (fdKindVNode → .file). net-b: a .socket
// description's `node` field indexes the socket table.

private let pipeReadEnd = 0
private let pipeWriteEnd = 1

private struct OpenDescription {
    var inUse = false
    var refCount = 0
    var kind: HandleKind = .none
    var node = -1
    var offset = 0
    var dirCursor = 0
    var flags = 0
    var pipe = -1
    var pipeEnd = pipeReadEnd
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

// C4a/C4b: an IPC endpoint — a channel carrying a single in-flight message that
// pairs BYTES (C4b) with an optionally transferred Handle (C4a, the capability).
// Modeled on Pipe: a heap message buffer plus a one-slot handle, with
// sendRefs/recvRefs tracking open ends. See docs/CAPABILITIES.md §4.
private struct Endpoint {
    var inUse = false
    var hasMsg = false      // a message (bytes ± a handle) is pending in the slot
    var bufPtr: UInt = 0    // heap byte buffer (endpointMsgCap), like Pipe.bufPtr
    var msgLen = 0          // valid bytes in bufPtr for the pending message
    var hasHandle = false
    var handle = HandleEntry()
    var sendRefs = 0
    var recvRefs = 0
}
private let endpointMsgCap = 256

private let maxFDs = 32
private let maxOpenDescriptions = 96
private let maxPipes = 16
private let pipeCap = 1024
private let maxVFSProcesses = 16

private var handles = [HandleEntry](repeating: HandleEntry(), count: maxFDs * maxVFSProcesses)
private var openDescriptions = [OpenDescription](repeating: OpenDescription(), count: maxOpenDescriptions)
private var pipes = [Pipe](repeating: Pipe(), count: maxPipes)
private let maxEndpoints = 16
private var endpoints = [Endpoint](repeating: Endpoint(), count: maxEndpoints)
private let endpointSendEnd = pipeWriteEnd  // ipc_send transfers a handle from here
private let endpointRecvEnd = pipeReadEnd   // ipc_recv receives it here
private var cwdNodes = [Int](repeating: 0, count: maxVFSProcesses)
// C3: the subtree a process is confined to — object-scoped fs authority. 0 means
// unconfined (the whole namespace, the compatibility default). isDescendant(_, of: 0)
// is always true, so the confinement guard is a no-op for unconfined processes.
private var confineNodes = [Int](repeating: 0, count: maxVFSProcesses)

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
                         _ diskOffset: Int, _ dataLen: Int,
                         _ owner: UInt32, _ mode: UInt32) {
    let n = allocNode()
    if n < 0 { return }
    nodes[n].namePtr = namePtr
    nodes[n].nameLen = nameLen
    nodes[n].readOnly = true
    nodes[n].onDisk = true
    nodes[n].diskOffset = diskOffset
    nodes[n].dataLen = dataLen
    nodes[n].owner = owner
    nodes[n].mode = mode
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

/// Build the read-only base tree from a packed SWOSBASE image on the virtio-blk
/// disk. Returns false (leaving the tree untouched) if there is no disk, the
/// magic does not match, or the image is malformed, so the caller can fall back
/// to the compiled-in literals. The metadata buffer (entries + string table) is
/// kept permanently: vnode names point straight into it.
private func buildBaseFromDisk(_ root: Int) -> Bool {
    if !virtioBlkAvailable() { return false }

    var hdr = [UInt8](repeating: 0, count: 64)
    let hok = hdr.withUnsafeMutableBytes { raw -> Bool in
        virtioBlkReadRange(0, raw.baseAddress, 64) == 0
    }
    if !hok { return false }

    return hdr.withUnsafeBufferPointer { hp -> Bool in
        let h = hp.baseAddress!
        let magic: StaticString = "SWOSBASE"
        var magicOk = true
        magic.withUTF8Buffer { m in
            for i in 0..<m.count where h[i] != m[i] { magicOk = false }
        }
        if !magicOk { return false }
        if le32(h, 8) != 2 { return false }   // version (M13c: v2 adds mode+owner)
        if le32(h, 16) != 40 { return false } // entry size

        let entryCount = Int(le32(h, 20))
        let entriesOffset = le64(h, 24)
        let stringsOffset = le64(h, 32)
        let stringsSize = le64(h, 40)
        let dataOffset = le64(h, 48)

        if entryCount <= 0 || entryCount > maxNodes { return false }
        if stringsOffset < entriesOffset { return false }
        let metaLen = Int((stringsOffset - entriesOffset) + stringsSize)
        if metaLen <= 0 || metaLen > 1 << 20 { return false } // 1 MiB ceiling

        guard let metaRaw = swiftos_kernel_alloc(UInt(metaLen), 16) else { return false }
        let meta = metaRaw.bindMemory(to: UInt8.self, capacity: metaLen)
        if virtioBlkReadRange(entriesOffset, metaRaw, UInt32(metaLen)) != 0 { return false }

        let stringsBase = Int(stringsOffset - entriesOffset)
        for k in 0..<entryCount {
            let e = meta + k * 40
            let pathOff = Int(le32(e, 0))
            let pathLen = Int(le32(e, 4))
            let kind = le32(e, 8)
            let dOff = Int(le64(e, 16))
            let dLen = Int(le64(e, 24))
            let mode = le32(e, 32)
            let owner = le32(e, 36)
            if pathLen <= 0 || stringsBase + pathOff + pathLen > metaLen { continue }
            let pathPtr = meta + stringsBase + pathOff
            let (parent, leafPtr, leafLen) = resolveBuildParent(root, pathPtr, pathLen)
            if parent < 0 || leafLen <= 0 { continue }
            if kind == 1 {
                _ = addDiskDir(parent, leafPtr, leafLen, owner, mode)
            } else if kind == 2 {
                addDiskFile(parent, leafPtr, leafLen, Int(dataOffset) + dOff, dLen, owner, mode)
            }
        }
        return true
    }
}

func vfsInit() {
    guard let raw = swiftos_kernel_alloc(UInt(MemoryLayout<VNode>.stride * maxNodes), 16) else {
        uartPuts("panic: vfs node table allocation failed\n")
        while true {}
    }
    nodes = raw.bindMemory(to: VNode.self, capacity: maxNodes)
    nodeCount = 0

    let root = allocNode()
    setName(root, "/")
    nodes[root].isDir = true
    nodes[root].parent = root

    // M11c: serve the read-only base from the packed disk image when one is
    // attached; otherwise fall back to the compiled-in literals (the -kernel
    // test paths and UEFI GPT boot, where the disk is not a SWOSBASE image).
    if buildBaseFromDisk(root) {
        klog(.info, "vfs", "M11c: read-only base mounted from disk")
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

    // Stamp the base/literal tree (and /tmp) with the boot time, so ls -l shows
    // a real date for read-only files instead of the 1970 epoch. tmpfs nodes
    // created later get their own creation time in createTmpNode.
    let bootTime = rtcNow()
    for i in 0..<nodeCount { nodes[i].mtime = bootTime }

    for p in 0..<maxVFSProcesses {
        cwdNodes[p] = root
        for fd in 0..<maxFDs { handles[fdIndex(p, fd)] = HandleEntry() }
    }
    for i in 0..<maxOpenDescriptions { openDescriptions[i] = OpenDescription() }
    for i in 0..<maxPipes { pipes[i] = Pipe() }
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
    if parent < 0 || parent >= maxVFSProcesses { return errInvalid }
    if specCount > UInt(maxFDs) { return errInvalid }
    if specCount == 0 { return 0 }
    guard let specs = userReadableBuffer(specsVA, specCount * UInt(handleSpecSize)) else {
        return errInvalid
    }

    var targetMask: UInt64 = 0
    for i in 0..<Int(specCount) {
        let spec = readHandleSpec(specs, i)
        let src = Int(spec.sourceFD)
        let dst = Int(spec.targetFD)
        if src < 0 || src >= maxFDs || dst < 0 || dst >= maxFDs { return errBadFD }
        if !fdEntry(parent, src).inUse { return errBadFD }
        if (spec.flags & ~handleSpecFlagCloexec) != 0 { return errInvalid }
        let bit = UInt64(1) << UInt64(dst)
        if (targetMask & bit) != 0 { return errInvalid }
        targetMask |= bit
    }
    return 0
}

private func seedExplicitHandles(slot: Int, parent: Int, specsVA: UInt, specCount: UInt) {
    if specCount == 0 { return }
    guard let specs = userReadableBuffer(specsVA, specCount * UInt(handleSpecSize)) else { return }
    for i in 0..<Int(specCount) {
        let spec = readHandleSpec(specs, i)
        let src = Int(spec.sourceFD)
        let dst = Int(spec.targetFD)
        let parentEntry = fdEntry(parent, src)
        var childEntry = parentEntry
        childEntry.rights = attenuate(parentEntry.rights, to: Rights(rawValue: spec.rightsMask))
        childEntry.cloexec = (spec.flags & handleSpecFlagCloexec) != 0
        handles[fdIndex(slot, dst)] = childEntry
        retainDescription(childEntry.object)
    }
}

func vfsProcessInit(slot: Int, parent: Int, inherit: HandleInheritance = .all,
                    specsVA: UInt = 0, specCount: UInt = 0) {
    if slot < 0 || slot >= maxVFSProcesses { return }
    if parent >= 0 && parent < maxVFSProcesses {
        // cwd is always inherited; the handle set depends on the mode. `.all` is
        // the fork/thread case, `.stdioOnly` is legacy spawn compatibility, and
        // `.explicit` starts empty and installs only named handle specs (C2).
        cwdNodes[slot] = cwdNodes[parent]
        confineNodes[slot] = confineNodes[parent] // a confined parent's child stays confined
        for fd in 0..<maxFDs {
            let e = handleInheritanceCopiesFD(inherit, fd: fd)
                ? handles[fdIndex(parent, fd)]
                : HandleEntry()
            handles[fdIndex(slot, fd)] = e
            if e.inUse { retainDescription(e.object) }
        }
        if inherit == .explicit {
            seedExplicitHandles(slot: slot, parent: parent, specsVA: specsVA, specCount: specCount)
        }
        return
    }

    cwdNodes[slot] = 0
    confineNodes[slot] = 0
    for fd in 0..<maxFDs { handles[fdIndex(slot, fd)] = HandleEntry() }
    _ = installTTY(slot: slot, fd: 0, readable: true, writable: true)
    _ = installTTY(slot: slot, fd: 1, readable: true, writable: true)
    _ = installTTY(slot: slot, fd: 2, readable: true, writable: true)
}

func vfsProcessCloseAll(slot: Int) {
    if slot < 0 || slot >= maxVFSProcesses { return }
    for fd in 0..<maxFDs {
        let idx = fdIndex(slot, fd)
        if handles[idx].inUse {
            releaseDescription(handles[idx].object)
            handles[idx] = HandleEntry()
        }
    }
}

/// Close the slot's close-on-exec descriptors. Called from execve: POSIX closes
/// FD_CLOEXEC fds across exec, so the shell's relocated/redirect-saved fds (ash
/// duplicates them above 10 with F_DUPFD_CLOEXEC) do not leak into the new image.
func vfsCloseCloexec(slot: Int) {
    if slot < 0 || slot >= maxVFSProcesses { return }
    for fd in 0..<maxFDs {
        let idx = fdIndex(slot, fd)
        if handles[idx].inUse && handles[idx].cloexec {
            releaseDescription(handles[idx].object)
            handles[idx] = HandleEntry()
        }
    }
}

// ---- name / path helpers --------------------------------------------------

private func currentVFSProcess() -> Int {
    let slot = processCurrentSlot()
    return (slot >= 0 && slot < maxVFSProcesses) ? slot : 0
}

private func fdIndex(_ proc: Int, _ fd: Int) -> Int {
    proc * maxFDs + fd
}

private func cwdNodeForCurrentProcess() -> Int {
    cwdNodes[currentVFSProcess()]
}

private func confineRootForCurrentProcess() -> Int {
    confineNodes[currentVFSProcess()]
}

private func fdEntry(_ proc: Int, _ fd: Int) -> HandleEntry {
    handles[fdIndex(proc, fd)]
}

private func setFDEntry(_ proc: Int, _ fd: Int, _ value: HandleEntry) {
    handles[fdIndex(proc, fd)] = value
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

// ---- fd/open-description helpers -----------------------------------------

private func allocFDInProcess(_ proc: Int, from start: Int = 3) -> Int {
    if start < 0 || start >= maxFDs { return -1 }
    for i in start..<maxFDs where !fdEntry(proc, i).inUse { return i }
    return -1
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
    if desc.kind == .pipe && desc.pipe >= 0 && desc.pipe < maxPipes && pipes[desc.pipe].inUse {
        if desc.pipeEnd == pipeReadEnd {
            if pipes[desc.pipe].readRefs > 0 { pipes[desc.pipe].readRefs -= 1 }
        } else {
            if pipes[desc.pipe].writeRefs > 0 { pipes[desc.pipe].writeRefs -= 1 }
        }
        if pipes[desc.pipe].readRefs == 0 && pipes[desc.pipe].writeRefs == 0 {
            pipes[desc.pipe] = Pipe()
        }
    }
    if desc.kind == .endpoint && desc.node >= 0 && desc.node < maxEndpoints && endpoints[desc.node].inUse {
        let ep = desc.node
        if desc.pipeEnd == endpointSendEnd {
            if endpoints[ep].sendRefs > 0 { endpoints[ep].sendRefs -= 1 }
        } else {
            if endpoints[ep].recvRefs > 0 { endpoints[ep].recvRefs -= 1 }
        }
        if endpoints[ep].sendRefs == 0 && endpoints[ep].recvRefs == 0 {
            // Balance an in-flight handle that was never received before teardown.
            if endpoints[ep].hasHandle && endpoints[ep].handle.inUse {
                releaseDescription(endpoints[ep].handle.object)
            }
            // Drop the message buffer, mirroring the .pipe block: the kernel heap is
            // a bump allocator (runtime/heap.c free() is a no-op), so resetting the
            // struct is exactly how a freed pipe relinquishes its bufPtr.
            endpoints[ep] = Endpoint()
        }
    }
    openDescriptions[d] = OpenDescription()
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
    return r
}

// ---- kernel-internal handle API (C1) --------------------------------------
//
// The handle-generic operations from docs/CAPABILITIES.md §2. These are not yet
// wired to syscalls (the POSIX dup/dup2/fcntl/close paths above still do that);
// later milestones (C2+) call these to manipulate handles directly, with
// per-handle rights and attenuation.

/// The rights the holder has on the handle at `(proc, fd)`, or empty if invalid.
func handleRights(_ proc: Int, _ fd: Int) -> Rights {
    validFD(proc, fd) ? fdEntry(proc, fd).rights : Rights()
}

/// Duplicate a handle into the lowest free slot, sharing the same underlying
/// description/offset, with rights attenuated to (at most) `mask`. The new
/// handle can never hold more authority than the source. Returns the new fd or
/// a negative error.
func handleDuplicate(_ proc: Int, _ fd: Int, mask: Rights) -> Int {
    guard validFD(proc, fd) else { return errBadFD }
    let newfd = allocFDInProcess(proc, from: 0)
    if newfd == -1 { return errNoSpace }
    let d = fdEntry(proc, fd).object
    retainDescription(d)
    installDescription(proc, newfd, d, rights: attenuate(fdEntry(proc, fd).rights, to: mask))
    return newfd
}

/// Close the handle at `(proc, fd)`, dropping its reference to the underlying
/// object. vfsClose is the current-process view of this.
func handleClose(_ proc: Int, _ fd: Int) -> Int {
    guard fd >= 0 && fd < maxFDs && fdEntry(proc, fd).inUse else { return errBadFD }
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

private func allocPipe() -> Int {
    for i in 0..<maxPipes where !pipes[i].inUse {
        guard let buf = swiftos_kernel_alloc(UInt(pipeCap), 16) else { return -1 }
        pipes[i] = Pipe(inUse: true, bufPtr: UInt(bitPattern: buf), cap: pipeCap,
                        head: 0, tail: 0, readRefs: 1, writeRefs: 1)
        return i
    }
    return -1
}

// ---- syscalls -------------------------------------------------------------

func vfsOpen(path pathVA: UInt, flags: UInt) -> Int {
    guard let path = userCString(pathVA) else { return errInvalid }

    var node = resolve(path)
    let f = Int(bitPattern: flags)

    // M13: capability enforcement. Reading the filesystem needs capFsRead;
    // writing/creating (only the tmpfs is writable) needs capTmpWrite.
    let caps = processCurrentCaps()
    let wantWrite = (f & oWrOnly) != 0 || (f & oRdWr) != 0 || (f & oCreat) != 0
    let wantRead = (f & oWrOnly) == 0 // O_RDONLY or O_RDWR
    if wantRead && (caps & capFsRead) == 0 { return errAccess }
    if wantWrite && (caps & capTmpWrite) == 0 { return errAccess }

    // C3: object-scoped confinement. A confined process (confineNodes != 0) may only
    // reach paths inside its subtree; isDescendant(_, of: 0) is always true, so this is
    // a no-op for the unconfined default. See docs/CAPABILITIES.md §6 (C3).
    let confineRoot = confineRootForCurrentProcess()
    if node != -1 && !isDescendant(node, of: confineRoot) { return errAccess }

    if node == -1 {
        if (f & oCreat) != 0 {
            var ls = 0, ll = 0
            let parent = resolveParent(path, &ls, &ll)
            if parent == -1 { return errNoEntry }
            if !isDescendant(parent, of: confineRoot) { return errAccess } // C3 confinement
            if nodes[parent].readOnly { return errReadOnly }
            if findChild(parent, path + ls, ll) != -1 { return errExists }
            node = createTmpNode(parent, path + ls, ll, isDir: false)
            if node == -1 { return errNoSpace }
        } else {
            return errNoEntry
        }
    }

    // O_TRUNC on a writable tmpfs file resets it to empty (shell `>` redirects).
    // Base/disk files are read-only, so truncation never applies to them.
    if (f & oTrunc) != 0 && !nodes[node].isDir && !nodes[node].readOnly {
        nodes[node].dataLen = 0
    }

    let proc = currentVFSProcess()
    let fd = allocFDInProcess(proc)
    if fd == -1 { return errNoSpace }
    let d = allocDescription()
    if d == -1 { return errNoSpace }

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
    if (f & oCloexec) != 0 { handles[fdIndex(proc, fd)].cloexec = true }
    return fd
}

func vfsRead(fd: Int, buffer: UInt, count: UInt) -> Int {
    if count == 0 { return 0 }
    let proc = currentVFSProcess()
    guard validFD(proc, fd) else { return errBadFD }
    let entry = fdEntry(proc, fd)
    let d = entry.object
    var file = openDescriptions[d]
    guard entry.rights.contains(.read) else { return errBadFD }

    if entry.kind == .tty {
        return ttyRead(buffer: buffer, count: count)
    }
    guard let dst = userWritableBuffer(buffer, count) else { return errInvalid }

    if entry.kind == .socket {
        if socketIsTCP(file.node) {
            return tcpRecv(file.node, dst: UnsafeMutableRawPointer(dst), cap: Int(count),
                           timeoutMs: socketRecvTimeoutMs)
        }
        return errInvalid   // UDP: use recvfrom
    }

    if entry.kind == .pipe {
        let p = file.pipe
        var copied = 0
        enable_irq()
        while copied == 0 {
            while copied < Int(count) && pipeCount(p) > 0 {
                dst[copied] = pipePop(p)
                copied += 1
            }
            if copied > 0 || pipes[p].writeRefs == 0 { break }
            processYieldForIO()
        }
        return copied
    }

    guard entry.kind == .file else { return errBadFD }
    let node = file.node
    if nodes[node].isDir { return errIsDir }

    // Disk-backed read-only file (M11c): pull the requested span off the disk.
    if nodes[node].onDisk {
        let avail = nodes[node].dataLen - file.offset
        if avail <= 0 { return 0 }
        let want = min(Int(count), avail)
        let off = UInt64(nodes[node].diskOffset + file.offset)
        let rc = virtioBlkReadRange(off, UnsafeMutableRawPointer(dst), UInt32(want))
        if rc != 0 { return errInvalid }
        file.offset += want
        openDescriptions[d] = file
        return want
    }

    let src = UnsafePointer<UInt8>(bitPattern: nodes[node].dataPtr)!
    var copied = 0
    while copied < Int(count) && file.offset < nodes[node].dataLen {
        dst[copied] = src[file.offset]
        copied += 1
        file.offset += 1
    }
    openDescriptions[d] = file
    return copied
}

func vfsWrite(fd: Int, buffer: UInt, count: UInt) -> Int {
    if count == 0 { return 0 }
    let proc = currentVFSProcess()
    guard validFD(proc, fd) else { return errBadFD }
    let entry = fdEntry(proc, fd)
    let d = entry.object
    var file = openDescriptions[d]
    guard entry.rights.contains(.write) else { return errBadFD }
    guard let src = userReadableBuffer(buffer, count) else { return errInvalid }

    if entry.kind == .tty {
        var w = 0
        while w < Int(count) { uartPutc(src[w]); w += 1 }
        return Int(count)
    }

    if entry.kind == .socket {
        if socketIsTCP(file.node) {
            return tcpSend(file.node, src: UnsafeRawPointer(src), len: Int(count))
        }
        return errInvalid   // UDP: use sendto
    }

    if entry.kind == .pipe {
        let p = file.pipe
        var written = 0
        enable_irq()
        while written < Int(count) {
            if pipes[p].readRefs == 0 { return written > 0 ? written : errPipe }
            while written < Int(count) && pipeSpace(p) > 0 {
                pipePush(p, src[written])
                written += 1
            }
            if written < Int(count) { processYieldForIO() }
        }
        return written
    }

    guard entry.kind == .file else { return errBadFD }
    let node = file.node
    if nodes[node].isDir { return errIsDir }
    if nodes[node].readOnly { return errReadOnly }

    let dst = UnsafeMutablePointer<UInt8>(bitPattern: nodes[node].dataPtr)!
    var w = 0
    while w < Int(count) && file.offset < nodes[node].dataCap {
        dst[file.offset] = src[w]
        file.offset += 1
        if file.offset > nodes[node].dataLen { nodes[node].dataLen = file.offset }
        w += 1
    }
    if w > 0 { nodes[node].mtime = rtcNow() }
    openDescriptions[d] = file
    return w
}

/// ftruncate(fd, length): resize a writable tmpfs file. Used by busybox vi,
/// which writes the buffer with O_CREAT (no O_TRUNC) and then ftruncate()s to
/// the exact length — so without this an overwrite that shrinks a file would
/// leave a stale tail. Growth zero-fills up to the node's capacity.
func vfsFtruncate(fd: Int, length: Int) -> Int {
    if length < 0 { return errInvalid }
    let proc = currentVFSProcess()
    guard validFD(proc, fd) else { return errBadFD }
    let entry = fdEntry(proc, fd)
    let d = entry.object
    let file = openDescriptions[d]
    guard entry.rights.contains(.write) else { return errBadFD }
    guard entry.kind == .file else { return errInvalid }
    let node = file.node
    if nodes[node].isDir { return errIsDir }
    if nodes[node].readOnly { return errReadOnly }
    if length > nodes[node].dataCap { return errNoSpace }
    if length > nodes[node].dataLen {
        let base = UnsafeMutablePointer<UInt8>(bitPattern: nodes[node].dataPtr)!
        var i = nodes[node].dataLen
        while i < length { base[i] = 0; i += 1 }
    }
    nodes[node].dataLen = length
    nodes[node].mtime = rtcNow()
    return 0
}

func vfsClose(fd: Int) -> Int {
    return handleClose(currentVFSProcess(), fd)
}

func vfsDup(fd: Int) -> Int {
    let proc = currentVFSProcess()
    guard validFD(proc, fd) else { return errBadFD }
    let newfd = allocFDInProcess(proc, from: 0)
    if newfd == -1 { return errNoSpace }
    let d = fdEntry(proc, fd).object
    retainDescription(d)
    // The dup carries the source handle's rights (today: identical access via
    // the shared description).
    installDescription(proc, newfd, d, rights: fdEntry(proc, fd).rights)
    return newfd
}

func vfsDup2(oldfd: Int, newfd: Int) -> Int {
    let proc = currentVFSProcess()
    guard validFD(proc, oldfd) else { return errBadFD }
    if newfd < 0 || newfd >= maxFDs { return errBadFD }
    if oldfd == newfd { return newfd }
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
private let fdCloexecFlag = 1

func vfsFcntl(fd: Int, cmd: Int, arg: Int) -> Int {
    let proc = currentVFSProcess()
    guard validFD(proc, fd) else { return errBadFD }
    switch cmd {
    case fDupFD, fDupFDCloexec:
        // Duplicate to the lowest free descriptor >= arg (shares the open
        // description, like dup). F_DUPFD_CLOEXEC additionally marks the new fd
        // close-on-exec.
        let start = arg < 0 ? 0 : arg
        let newfd = allocFDInProcess(proc, from: start)
        if newfd == -1 { return errNoSpace }
        let d = fdEntry(proc, fd).object
        retainDescription(d)
        installDescription(proc, newfd, d, rights: fdEntry(proc, fd).rights)
        if cmd == fDupFDCloexec { handles[fdIndex(proc, newfd)].cloexec = true }
        return newfd
    case fGetFD:
        return fdEntry(proc, fd).cloexec ? fdCloexecFlag : 0
    case fSetFD:
        handles[fdIndex(proc, fd)].cloexec = (arg & fdCloexecFlag) != 0
        return 0
    case fGetFL:
        return openDescriptions[fdEntry(proc, fd).object].flags
    case fSetFL:
        return 0
    default:
        return errInvalid
    }
}

func vfsPipe(fdsVA: UInt) -> Int {
    guard let out = userWritableBuffer(fdsVA, 8) else { return errInvalid }
    let proc = currentVFSProcess()
    let rfd = allocFDInProcess(proc, from: 0)
    if rfd == -1 { return errNoSpace }
    setFDEntry(proc, rfd, HandleEntry(inUse: true, object: -1)) // reserve
    let wfd = allocFDInProcess(proc, from: 0)
    setFDEntry(proc, rfd, HandleEntry())
    if wfd == -1 { return errNoSpace }

    let p = allocPipe()
    if p == -1 { return errNoMem }
    let rd = allocDescription()
    let wr = allocDescription()
    if rd == -1 || wr == -1 { return errNoSpace }

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

// ---- C4a: handle-passing IPC endpoints ------------------------------------
//
// A minimal capability-passing primitive (docs/CAPABILITIES.md §4): endpoint_create
// returns a (send, recv) fd pair; ipc_send copies BYTES (C4b) and MOVES an optional
// handle into the channel; ipc_recv blocks until a message arrives, copies the bytes
// out and installs any transferred handle as a new fd in the receiver. This is the
// keystone for restartable services and cells (request/reply rides the bytes); a
// bidirectional channel, VMOs and async rings are later sub-milestones. Like a pipe,
// each endpoint owns a heap message buffer (off the bump heap — see allocPipe).

private func allocEndpoint() -> Int {
    for i in 0..<maxEndpoints where !endpoints[i].inUse {
        guard let buf = swiftos_kernel_alloc(UInt(endpointMsgCap), 16) else { return -1 }
        endpoints[i] = Endpoint(inUse: true, hasMsg: false, bufPtr: UInt(bitPattern: buf),
                                msgLen: 0, hasHandle: false, handle: HandleEntry(),
                                sendRefs: 1, recvRefs: 1)
        return i
    }
    return -1
}

/// endpoint_create(int ends[2]) -> 0; ends[0] = send end, ends[1] = recv end.
func vfsEndpointCreate(endsVA: UInt) -> Int {
    guard let out = userWritableBuffer(endsVA, 8) else { return errInvalid }
    let proc = currentVFSProcess()
    let sfd = allocFDInProcess(proc, from: 0)
    if sfd == -1 { return errNoSpace }
    setFDEntry(proc, sfd, HandleEntry(inUse: true, object: -1)) // reserve
    let rfd = allocFDInProcess(proc, from: 0)
    setFDEntry(proc, sfd, HandleEntry())
    if rfd == -1 { return errNoSpace }

    let ep = allocEndpoint()
    if ep == -1 { return errNoMem }
    let sd = allocDescription()
    let rd = allocDescription()
    if sd == -1 || rd == -1 { return errNoSpace }

    openDescriptions[sd].kind = .endpoint
    openDescriptions[sd].node = ep
    openDescriptions[sd].pipeEnd = endpointSendEnd
    openDescriptions[rd].kind = .endpoint
    openDescriptions[rd].node = ep
    openDescriptions[rd].pipeEnd = endpointRecvEnd

    installDescription(proc, sfd, sd, rights: [.write, .transfer])
    installDescription(proc, rfd, rd, rights: [.read, .transfer])
    let raw = UnsafeMutableRawPointer(out)
    raw.storeBytes(of: Int32(sfd), toByteOffset: 0, as: Int32.self)
    raw.storeBytes(of: Int32(rfd), toByteOffset: 4, as: Int32.self)
    return 0
}

// The user-side msg structs (fixed little-endian offsets, like sendto's udp_msg —
// the 3-arg syscall ABI carries only (fd, &msg)):
//   SEND  off 0: buf (u64 user VA)  off 8: len (u64)  off 16: handle_fd (i32, <0 = none)
//   RECV  off 0: buf (u64 user VA)  off 8: cap (u64)  off 16: out_handle_fd (u64 user VA → int)
private let ipcSendMsgSize: UInt = 20  // buf(8) + len(8) + handle_fd(4)
private let ipcRecvMsgSize: UInt = 24  // buf(8) + cap(8) + out_handle_fd(8)

/// ipc_send(fd, &msg): copy up to endpointMsgCap message BYTES into the endpoint and,
/// if msg.handle_fd >= 0, MOVE that handle to the peer. The handle's source fd is
/// cleared WITHOUT releasing the underlying object — ownership (and its refcount)
/// transfers with the handle. errAgain if a message is already in flight (single-slot
/// channel). A message may carry bytes with no handle, so the slot is gated on hasMsg.
func vfsIpcSend(fd: Int, msgVA: UInt) -> Int {
    let proc = currentVFSProcess()
    guard validFD(proc, fd) else { return errBadFD }
    let sender = fdEntry(proc, fd)
    guard sender.rights.contains(.write) else { return errBadFD }
    guard sender.rights.contains(.transfer) else { return errAccess }
    let desc = openDescriptions[sender.object]
    guard desc.kind == .endpoint, desc.pipeEnd == endpointSendEnd else { return errInvalid }
    let ep = desc.node
    guard ep >= 0 && ep < maxEndpoints && endpoints[ep].inUse else { return errInvalid }
    if endpoints[ep].recvRefs == 0 { return errPipe }
    if endpoints[ep].hasMsg { return errAgain }

    guard let m = userReadableBuffer(msgVA, ipcSendMsgSize) else { return errInvalid }
    let buf = UInt(le64(m, 0))
    let len = Int(le64(m, 8))
    let handleFd = Int(Int32(bitPattern: le32(m, 16)))
    if len < 0 { return errInvalid }

    // The handle (if any) must be a distinct, valid fd before we commit the message.
    if handleFd >= 0 {
        guard validFD(proc, handleFd), handleFd != fd else { return errBadFD }
        guard fdEntry(proc, handleFd).rights.contains(.transfer) else { return errAccess }
    }

    let n = min(len, endpointMsgCap)
    if n > 0 {
        guard let src = userReadableBuffer(buf, UInt(n)) else { return errInvalid }
        let dst = UnsafeMutablePointer<UInt8>(bitPattern: endpoints[ep].bufPtr)!
        for i in 0..<n { dst[i] = src[i] }
    }
    endpoints[ep].msgLen = n

    if handleFd >= 0 {
        endpoints[ep].handle = fdEntry(proc, handleFd) // copy the entry...
        endpoints[ep].hasHandle = true
        setFDEntry(proc, handleFd, HandleEntry())       // ...then clear the source (move, no release)
    }
    endpoints[ep].hasMsg = true
    return 0
}

/// ipc_recv(fd, &msg) -> byte count: block until a message is in flight, copy up to
/// msg.cap bytes into msg.buf, and — if a handle was transferred — install it as a new
/// fd written to *msg.out_handle_fd (else -1). errPipe if every sender closed first
/// (EOF-like). Returns the number of bytes copied to the user buffer.
func vfsIpcRecv(fd: Int, msgVA: UInt) -> Int {
    let proc = currentVFSProcess()
    guard validFD(proc, fd) else { return errBadFD }
    let desc = openDescriptions[fdEntry(proc, fd).object]
    guard desc.kind == .endpoint, desc.pipeEnd == endpointRecvEnd else { return errInvalid }
    let ep = desc.node
    guard ep >= 0 && ep < maxEndpoints && endpoints[ep].inUse else { return errInvalid }

    guard let m = userReadableBuffer(msgVA, ipcRecvMsgSize) else { return errInvalid }
    let buf = UInt(le64(m, 0))
    let cap = Int(le64(m, 8))
    let outHandleVA = UInt(le64(m, 16))
    if cap < 0 { return errInvalid }
    guard let outHandle = userWritableBuffer(outHandleVA, 4) else { return errInvalid }

    enable_irq()
    while !endpoints[ep].hasMsg {
        if endpoints[ep].sendRefs == 0 { return errPipe }
        processYieldForIO()
    }

    let n = min(endpoints[ep].msgLen, cap)
    if n > 0 {
        guard let dst = userWritableBuffer(buf, UInt(n)) else { return errInvalid }
        let src = UnsafePointer<UInt8>(bitPattern: endpoints[ep].bufPtr)!
        for i in 0..<n { dst[i] = src[i] }
    }

    var newfd: Int32 = -1
    if endpoints[ep].hasHandle {
        let installed = allocFDInProcess(proc, from: 0)
        if installed == -1 { return errNoSpace }
        setFDEntry(proc, installed, endpoints[ep].handle)
        newfd = Int32(installed)
    }
    UnsafeMutableRawPointer(outHandle).storeBytes(of: newfd, toByteOffset: 0, as: Int32.self)

    endpoints[ep].handle = HandleEntry()
    endpoints[ep].hasHandle = false
    endpoints[ep].hasMsg = false
    endpoints[ep].msgLen = 0
    return n
}

func vfsLseek(fd: Int, offset: Int, whence: Int) -> Int {
    let proc = currentVFSProcess()
    guard validFD(proc, fd) else { return errBadFD }
    let entry = fdEntry(proc, fd)
    let d = entry.object
    var file = openDescriptions[d]
    guard entry.kind == .file else { return errInvalid }
    let node = file.node
    var base = 0
    if whence == 1 { base = file.offset }
    else if whence == 2 { base = nodes[node].dataLen }
    else if whence != 0 { return errInvalid }
    let next = base + offset
    if next < 0 { return errInvalid }
    file.offset = next
    openDescriptions[d] = file
    return next
}

// Kernel stat record (kstat) the newlib/Swift bottom ends translate into their
// own struct stat. 32-byte little-endian layout (grown from 16→24→32):
//   off 0  u32 mode    off 4  u32 uid    off 8  u64 size
//   off 16 u32 gid     off 20 u32 nlink  off 24 u64 mtime (Unix seconds)
// Earlier fields keep their offsets, so older shorter readers stay valid.
private func writeStatMode(_ va: UInt, _ mode: UInt32, _ size: Int,
                           uid: UInt32 = 1, gid: UInt32 = 1, nlink: UInt32 = 1,
                           mtime: UInt64 = 0) -> Int {
    guard let p8 = userWritableBuffer(va, 32) else { return errInvalid }
    let p = UnsafeMutableRawPointer(p8)
    p.storeBytes(of: mode, toByteOffset: 0, as: UInt32.self)
    p.storeBytes(of: uid, toByteOffset: 4, as: UInt32.self)
    p.storeBytes(of: UInt64(size), toByteOffset: 8, as: UInt64.self)
    p.storeBytes(of: gid, toByteOffset: 16, as: UInt32.self)
    p.storeBytes(of: nlink, toByteOffset: 20, as: UInt32.self)
    p.storeBytes(of: mtime, toByteOffset: 24, as: UInt64.self)
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
    let mode: UInt32 = (nodes[node].isDir ? sIFDIR : sIFREG) | perms
    let owner = nodes[node].owner
    return writeStatMode(va, mode, nodes[node].dataLen, uid: owner, gid: owner,
                         mtime: nodes[node].mtime)
}

func vfsStat(path pathVA: UInt, statbuf: UInt) -> Int {
    guard let path = userCString(pathVA) else { return errInvalid }
    let node = resolve(path)
    if node == -1 { return errNoEntry }
    return writeStatNode(statbuf, node)
}

func vfsFstat(fd: Int, statbuf: UInt) -> Int {
    let proc = currentVFSProcess()
    guard validFD(proc, fd) else { return errBadFD }
    let entry = fdEntry(proc, fd)
    let file = openDescriptions[entry.object]
    let me = processCurrentPrincipal()
    let now = rtcNow()
    if entry.kind == .tty { return writeStatMode(statbuf, sIFCHR | 0o666, 0, uid: me, gid: me, mtime: now) }
    if entry.kind == .pipe { return writeStatMode(statbuf, sIFIFO | 0o666, 0, uid: me, gid: me, mtime: now) }
    if entry.kind == .file { return writeStatNode(statbuf, file.node) }
    return errBadFD
}

// dirent: d_ino(8) d_off(8) d_reclen(2) d_type(1) d_name[](NUL-terminated).
func vfsGetdents(fd: Int, buffer: UInt, count: UInt) -> Int {
    if count == 0 { return 0 }
    let proc = currentVFSProcess()
    guard validFD(proc, fd) else { return errBadFD }
    let entry = fdEntry(proc, fd)
    let d = entry.object
    var file = openDescriptions[d]
    guard entry.kind == .file else { return errInvalid }
    let dir = file.node
    if !nodes[dir].isDir { return errInvalid }
    guard let b = userWritableBuffer(buffer, count) else { return errInvalid }
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
    guard let path = userCString(pathVA) else { return errInvalid }
    let node = resolve(path)
    if node == -1 { return errNoEntry }
    if !nodes[node].isDir { return errNotDir }
    cwdNodes[currentVFSProcess()] = node
    return 0
}

// C3: confine this process's filesystem access to a subtree (object-scoped
// authority). Confine-only: the new root must lie within the current confinement,
// so a confined process cannot widen its own reach. Once set, vfsOpen denies any
// path outside the subtree. See docs/CAPABILITIES.md §6 (C3).
func vfsConfine(path pathVA: UInt) -> Int {
    guard let path = userCString(pathVA) else { return errInvalid }
    let node = resolve(path)
    if node == -1 { return errNoEntry }
    if !nodes[node].isDir { return errNotDir }
    let proc = currentVFSProcess()
    if !isDescendant(node, of: confineNodes[proc]) { return errAccess }
    confineNodes[proc] = node
    return 0
}

func vfsGetcwd(buffer: UInt, size: UInt) -> Int {
    guard size > 0, let buf = userWritableBuffer(buffer, size) else {
        return errInvalid
    }

    let cwdNode = cwdNodeForCurrentProcess()
    if cwdNode == 0 {
        if size < 2 { return errNoSpace }
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
        if pos + 1 >= Int(size) { return errNoSpace }
        buf[pos] = 0x2F; pos += 1
        let node = chain[d]
        let np = UnsafePointer<UInt8>(bitPattern: nodes[node].namePtr)!
        let nl = nodes[node].nameLen
        if pos + nl + 1 >= Int(size) { return errNoSpace }
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
    guard let path = userCString(pathVA) else { return errInvalid }
    if !mayWriteTmp() { return errAccess }
    let node = resolve(path)
    if node == -1 { return errNoEntry }
    if nodes[node].isDir { return errIsDir }
    let parent = nodes[node].parent
    if nodes[parent].readOnly { return errReadOnly }
    _ = unlinkChild(parent, node)
    return 0
}

func vfsMkdir(path pathVA: UInt) -> Int {
    guard let path = userCString(pathVA) else { return errInvalid }
    if !mayWriteTmp() { return errAccess }
    var ls = 0, ll = 0
    let parent = resolveParent(path, &ls, &ll)
    if parent == -1 { return errNoEntry }
    if nodes[parent].readOnly { return errReadOnly }
    if findChild(parent, path + ls, ll) != -1 { return errExists }
    return createTmpNode(parent, path + ls, ll, isDir: true) == -1 ? errNoSpace : 0
}

func vfsRmdir(path pathVA: UInt) -> Int {
    guard let path = userCString(pathVA) else { return errInvalid }
    if !mayWriteTmp() { return errAccess }
    let node = resolve(path)
    if node <= 0 { return errInvalid }
    if !nodes[node].isDir { return errNotDir }
    if nodes[node].firstChild != -1 { return errNotEmpty }
    let parent = nodes[node].parent
    if nodes[parent].readOnly { return errReadOnly }
    _ = unlinkChild(parent, node)
    return 0
}

func vfsRename(old oldVA: UInt, new newVA: UInt) -> Int {
    guard let oldPath = userCString(oldVA), let newPath = userCString(newVA) else {
        return errInvalid
    }
    if !mayWriteTmp() { return errAccess }
    let src = resolve(oldPath)
    if src <= 0 { return errNoEntry }

    var nls = 0, nll = 0
    let dstParent = resolveParent(newPath, &nls, &nll)
    if dstParent == -1 { return errNoEntry }
    let srcParent = nodes[src].parent
    if nodes[srcParent].readOnly || nodes[dstParent].readOnly { return errReadOnly }
    if nodes[src].isDir && isDescendant(dstParent, of: src) { return errInvalid }

    let existing = findChild(dstParent, newPath + nls, nll)
    if existing == src { return 0 }
    if existing != -1 {
        if nodes[existing].isDir != nodes[src].isDir { return errInvalid }
        if nodes[existing].isDir && nodes[existing].firstChild != -1 { return errNotEmpty }
        _ = unlinkChild(dstParent, existing)
    }

    _ = unlinkChild(srcParent, src)
    if !setNameCopy(src, newPath + nls, nll) { return errNoMem }
    linkChild(dstParent, src)
    return 0
}

// chmod/chown — change a tmpfs node's permission bits / owning principal. The
// base FS is read-only, so only tmpfs nodes are mutable; like the other
// namespace mutations (M13b) this requires capTmpWrite. Cosmetic for ls -l,
// since tmpfs is ephemeral, but completes the M13c ownership story.
func vfsChmod(path pathVA: UInt, mode: UInt) -> Int {
    guard let path = userCString(pathVA) else { return errInvalid }
    if !mayWriteTmp() { return errAccess }
    let node = resolve(path)
    if node == -1 { return errNoEntry }
    if nodes[node].readOnly { return errReadOnly }
    nodes[node].mode = UInt32(mode & 0o7777)
    return 0
}

func vfsChown(path pathVA: UInt, owner: UInt) -> Int {
    guard let path = userCString(pathVA) else { return errInvalid }
    if !mayWriteTmp() { return errAccess }
    let node = resolve(path)
    if node == -1 { return errNoEntry }
    if nodes[node].readOnly { return errReadOnly }
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
        if (events & pollIn) != 0 && socketPollReadable(desc.node) { revents |= pollIn }
        if (events & pollOut) != 0 { revents |= pollOut }   // always writable
        return revents
    }
    if kind == .pipe {
        let p = desc.pipe
        if (events & pollIn) != 0 && rights.contains(.read) {
            if pipeCount(p) > 0 || pipes[p].writeRefs == 0 { revents |= pollIn }
        }
        if (events & pollOut) != 0 && rights.contains(.write) {
            if pipes[p].readRefs == 0 { revents |= pollErr }
            else if pipeSpace(p) > 0 { revents |= pollOut }
        }
        if desc.pipeEnd == pipeReadEnd && pipes[p].writeRefs == 0 { revents |= pollHup }
        if desc.pipeEnd == pipeWriteEnd && pipes[p].readRefs == 0 { revents |= pollErr }
        return revents
    }
    if kind == .endpoint {
        let ep = desc.node
        if ep < 0 || ep >= maxEndpoints || !endpoints[ep].inUse { return pollNval }
        if desc.pipeEnd == endpointRecvEnd {
            if (events & pollIn) != 0 && rights.contains(.read) {
                if endpoints[ep].hasMsg || endpoints[ep].sendRefs == 0 { revents |= pollIn }
            }
            if endpoints[ep].sendRefs == 0 { revents |= pollHup }
        } else {
            if endpoints[ep].recvRefs == 0 {
                revents |= pollErr
            } else if (events & pollOut) != 0 && rights.contains(.write) && !endpoints[ep].hasMsg {
                revents |= pollOut
            }
        }
        return revents
    }
    return pollNval
}

private func pollScan(_ base: UnsafeMutableRawPointer, _ nfds: Int) -> Int {
    let proc = currentVFSProcess()
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
    if nfds > UInt(maxFDs) { return errInvalid }
    guard let buf = userWritableBuffer(fdsVA, nfds * UInt(pollfdSize)) else { return errInvalid }
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
    for i in 0..<count {
        let fd = Int(base.advanced(by: i * pollfdSize).load(fromByteOffset: 0, as: Int32.self))
        if fd >= 0 && validFD(proc, fd) {
            let kind = fdEntry(proc, fd).kind
            if kind == .pipe || kind == .endpoint { hasPeerDriven = true }
            if kind == .socket { hasSocket = true }
        }
    }

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
    if (processCurrentCaps() & capNet) == 0 { return errAccess }
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
private func installSocketFD(_ s: Int) -> Int {
    let proc = currentVFSProcess()
    let fd = allocFDInProcess(proc, from: 3)
    if fd < 0 { socketClose(s); return errNoSpace }
    let d = allocDescription()
    if d < 0 { socketClose(s); return errNoSpace }
    openDescriptions[d].kind = .socket
    openDescriptions[d].node = s
    installDescription(proc, fd, d, rights: posixRights(read: true, write: true))
    return fd
}

// Stream accept/recv block until ready, bounded so a test can never hang.
private let socketAcceptTimeoutMs = 15000

func vfsListen(fd: Int, backlog: Int) -> Int {
    let s = socketIndexForFD(currentVFSProcess(), fd)
    if s < 0 { return errBadFD }
    return tcpListen(s, backlog: backlog)
}

func vfsAccept(fd: Int) -> Int {
    let s = socketIndexForFD(currentVFSProcess(), fd)
    if s < 0 { return errBadFD }
    let c = tcpAccept(s, timeoutMs: socketAcceptTimeoutMs)
    if c < 0 { return c }
    return installSocketFD(c)
}

func vfsConnect(fd: Int, ip: UInt, port: Int) -> Int {
    let s = socketIndexForFD(currentVFSProcess(), fd)
    if s < 0 { return errBadFD }
    if port <= 0 || port > 65535 { return errInvalid }
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

private func socketIndexForFD(_ proc: Int, _ fd: Int) -> Int {
    guard validFD(proc, fd) else { return -1 }
    let entry = fdEntry(proc, fd)
    guard entry.kind == .socket else { return -1 }
    let d = entry.object
    return openDescriptions[d].node
}

func vfsSocketBind(fd: Int, port: Int) -> Int {
    let s = socketIndexForFD(currentVFSProcess(), fd)
    if s < 0 { return errBadFD }
    if port < 0 || port > 65535 { return errInvalid }
    return socketBind(s, port: UInt16(port))
}

func vfsSendto(fd: Int, msgVA: UInt) -> Int {
    let s = socketIndexForFD(currentVFSProcess(), fd)
    if s < 0 { return errBadFD }
    let isV6 = (socketFamilyOf(s) == AF_INET6)
    let need = isV6 ? udpMsgSizeV6 : udpMsgSize
    guard let m = userReadableBuffer(msgVA, need) else { return errInvalid }

    if isV6 {
        let buf = UInt(le64(m, 0))
        let len = Int(le32(m, 8))
        if len < 0 || len > 65507 { return errInvalid }
        var ip6b: [UInt8] = []
        var k = 0
        while k < 16 { ip6b.append(m[12 + k]); k += 1 }
        let dst6 = IPv6(ip6b)
        let port = UInt16(m[28]) | (UInt16(m[29]) << 8)
        if len == 0 {
            return socketSendv6(s, dstIPv6: dst6, dstPort: port, src: UnsafeRawPointer(m), len: 0)
        }
        guard let payload = userReadableBuffer(buf, UInt(len)) else { return errInvalid }
        return socketSendv6(s, dstIPv6: dst6, dstPort: port, src: UnsafeRawPointer(payload), len: len)
    }

    // IPv4 classic path
    let buf = UInt(le64(m, 0))
    let len = Int(le32(m, 8))
    let ip = le32(m, 12)
    let port = UInt16(m[16]) | (UInt16(m[17]) << 8)
    if len < 0 || len > 65507 { return errInvalid }
    if len == 0 {
        return socketSend(s, dstIP: ip, dstPort: port, src: UnsafeRawPointer(m), len: 0)
    }
    guard let payload = userReadableBuffer(buf, UInt(len)) else { return errInvalid }
    return socketSend(s, dstIP: ip, dstPort: port, src: UnsafeRawPointer(payload), len: len)
}

func vfsRecvfrom(fd: Int, msgVA: UInt) -> Int {
    let s = socketIndexForFD(currentVFSProcess(), fd)
    if s < 0 { return errBadFD }
    let isV6 = (socketFamilyOf(s) == AF_INET6)
    let need = isV6 ? udpMsgSizeV6 : udpMsgSize
    guard let m = userWritableBuffer(msgVA, need) else { return errInvalid }
    let buf = UInt(le64(m, 0))
    let cap = Int(le32(m, 8))
    if cap < 0 || cap > 65507 { return errInvalid }
    guard let dst = userWritableBuffer(buf, UInt(cap)) else { return errInvalid }

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

/// Resolve an absolute kernel path to a disk-backed file's extent. Returns
/// (found, diskByteOffset, length); found is false for a missing path, a
/// directory, or a RAM-backed (non-disk) node. Lets the ELF loader pull a
/// program straight off the packed base image instead of an embedded blob.
func vfsDiskImageExtent(_ path: UnsafePointer<UInt8>) -> (Bool, Int, Int) {
    let node = resolve(path)
    if node < 0 { return (false, 0, 0) }
    if nodes[node].isDir || !nodes[node].onDisk { return (false, 0, 0) }
    return (true, nodes[node].diskOffset, nodes[node].dataLen)
}
