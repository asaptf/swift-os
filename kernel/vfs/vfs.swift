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

// Open flags (our ABI; userland lib/fs.h must match).
let oWrOnly = 1
let oRdWr = 2
let oCreat = 0x40

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
    var parent = -1
    var firstChild = -1
    var nextSibling = -1
}

private let maxNodes = 96
private var nodes: UnsafeMutablePointer<VNode>! = nil
private var nodeCount = 0

// ---- open files, fd table, pipes -----------------------------------------

private let fdKindNone = 0
private let fdKindTTY = 1
private let fdKindVNode = 2
private let fdKindPipe = 3

private let pipeReadEnd = 0
private let pipeWriteEnd = 1

private struct FDEntry {
    var inUse = false
    var file = -1
}

private struct OpenDescription {
    var inUse = false
    var refCount = 0
    var kind = fdKindNone
    var readable = false
    var writable = false
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

private let maxFDs = 32
private let maxOpenDescriptions = 96
private let maxPipes = 16
private let pipeCap = 1024
private let maxVFSProcesses = 16

private var fds = [FDEntry](repeating: FDEntry(), count: maxFDs * maxVFSProcesses)
private var openDescriptions = [OpenDescription](repeating: OpenDescription(), count: maxOpenDescriptions)
private var pipes = [Pipe](repeating: Pipe(), count: maxPipes)
private var cwdNodes = [Int](repeating: 0, count: maxVFSProcesses)

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

private func addDiskDir(_ parent: Int, _ namePtr: UInt, _ nameLen: Int) -> Int {
    let n = allocNode()
    if n < 0 { return -1 }
    nodes[n].namePtr = namePtr
    nodes[n].nameLen = nameLen
    nodes[n].isDir = true
    nodes[n].readOnly = true
    linkChild(parent, n)
    return n
}

private func addDiskFile(_ parent: Int, _ namePtr: UInt, _ nameLen: Int,
                         _ diskOffset: Int, _ dataLen: Int) {
    let n = allocNode()
    if n < 0 { return }
    nodes[n].namePtr = namePtr
    nodes[n].nameLen = nameLen
    nodes[n].readOnly = true
    nodes[n].onDisk = true
    nodes[n].diskOffset = diskOffset
    nodes[n].dataLen = dataLen
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
    if virtio_blk_available() == 0 { return false }

    var hdr = [UInt8](repeating: 0, count: 64)
    let hok = hdr.withUnsafeMutableBytes { raw -> Bool in
        virtio_blk_read_range(0, raw.baseAddress, 64) == 0
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
        if le32(h, 8) != 1 { return false }   // version
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
        if virtio_blk_read_range(entriesOffset, metaRaw, UInt32(metaLen)) != 0 { return false }

        let stringsBase = Int(stringsOffset - entriesOffset)
        for k in 0..<entryCount {
            let e = meta + k * 40
            let pathOff = Int(le32(e, 0))
            let pathLen = Int(le32(e, 4))
            let kind = le32(e, 8)
            let dOff = Int(le64(e, 16))
            let dLen = Int(le64(e, 24))
            if pathLen <= 0 || stringsBase + pathOff + pathLen > metaLen { continue }
            let pathPtr = meta + stringsBase + pathOff
            let (parent, leafPtr, leafLen) = resolveBuildParent(root, pathPtr, pathLen)
            if parent < 0 || leafLen <= 0 { continue }
            if kind == 1 {
                _ = addDiskDir(parent, leafPtr, leafLen)
            } else if kind == 2 {
                addDiskFile(parent, leafPtr, leafLen, Int(dataOffset) + dOff, dLen)
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
        uartPuts("M11c: read-only base mounted from disk\n")
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

    for p in 0..<maxVFSProcesses {
        cwdNodes[p] = root
        for fd in 0..<maxFDs { fds[fdIndex(p, fd)] = FDEntry() }
    }
    for i in 0..<maxOpenDescriptions { openDescriptions[i] = OpenDescription() }
    for i in 0..<maxPipes { pipes[i] = Pipe() }
}

func vfsProcessInit(slot: Int, parent: Int) {
    if slot < 0 || slot >= maxVFSProcesses { return }
    if parent >= 0 && parent < maxVFSProcesses {
        cwdNodes[slot] = cwdNodes[parent]
        for fd in 0..<maxFDs {
            let e = fds[fdIndex(parent, fd)]
            fds[fdIndex(slot, fd)] = e
            if e.inUse { retainDescription(e.file) }
        }
        return
    }

    cwdNodes[slot] = 0
    for fd in 0..<maxFDs { fds[fdIndex(slot, fd)] = FDEntry() }
    _ = installTTY(slot: slot, fd: 0, readable: true, writable: true)
    _ = installTTY(slot: slot, fd: 1, readable: true, writable: true)
    _ = installTTY(slot: slot, fd: 2, readable: true, writable: true)
}

func vfsProcessCloseAll(slot: Int) {
    if slot < 0 || slot >= maxVFSProcesses { return }
    for fd in 0..<maxFDs {
        let idx = fdIndex(slot, fd)
        if fds[idx].inUse {
            releaseDescription(fds[idx].file)
            fds[idx] = FDEntry()
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

private func fdEntry(_ proc: Int, _ fd: Int) -> FDEntry {
    fds[fdIndex(proc, fd)]
}

private func setFDEntry(_ proc: Int, _ fd: Int, _ value: FDEntry) {
    fds[fdIndex(proc, fd)] = value
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
    if desc.kind == fdKindPipe && desc.pipe >= 0 && desc.pipe < maxPipes && pipes[desc.pipe].inUse {
        if desc.pipeEnd == pipeReadEnd {
            if pipes[desc.pipe].readRefs > 0 { pipes[desc.pipe].readRefs -= 1 }
        } else {
            if pipes[desc.pipe].writeRefs > 0 { pipes[desc.pipe].writeRefs -= 1 }
        }
        if pipes[desc.pipe].readRefs == 0 && pipes[desc.pipe].writeRefs == 0 {
            pipes[desc.pipe] = Pipe()
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
    openDescriptions[d].kind = fdKindTTY
    openDescriptions[d].readable = readable
    openDescriptions[d].writable = writable
    setFDEntry(slot, fd, FDEntry(inUse: true, file: d))
    return fd
}

private func installDescription(_ proc: Int, _ fd: Int, _ desc: Int) {
    setFDEntry(proc, fd, FDEntry(inUse: true, file: desc))
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

    if node == -1 {
        if (f & oCreat) != 0 {
            var ls = 0, ll = 0
            let parent = resolveParent(path, &ls, &ll)
            if parent == -1 { return errNoEntry }
            if nodes[parent].readOnly { return errReadOnly }
            if findChild(parent, path + ls, ll) != -1 { return errExists }
            node = createTmpNode(parent, path + ls, ll, isDir: false)
            if node == -1 { return errNoSpace }
        } else {
            return errNoEntry
        }
    }

    let proc = currentVFSProcess()
    let fd = allocFDInProcess(proc)
    if fd == -1 { return errNoSpace }
    let d = allocDescription()
    if d == -1 { return errNoSpace }

    openDescriptions[d].kind = fdKindVNode
    openDescriptions[d].node = node
    openDescriptions[d].offset = 0
    openDescriptions[d].dirCursor = 0
    openDescriptions[d].flags = f
    openDescriptions[d].readable = (f & oWrOnly) == 0 || (f & oRdWr) != 0
    openDescriptions[d].writable = (f & oWrOnly) != 0 || (f & oRdWr) != 0
    installDescription(proc, fd, d)
    return fd
}

func vfsRead(fd: Int, buffer: UInt, count: UInt) -> Int {
    if count == 0 { return 0 }
    let proc = currentVFSProcess()
    guard validFD(proc, fd) else { return errBadFD }
    let d = fdEntry(proc, fd).file
    var file = openDescriptions[d]
    guard file.readable else { return errBadFD }

    if file.kind == fdKindTTY {
        return ttyRead(buffer: buffer, count: count)
    }
    guard let dst = userWritableBuffer(buffer, count) else { return errInvalid }

    if file.kind == fdKindPipe {
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

    guard file.kind == fdKindVNode else { return errBadFD }
    let node = file.node
    if nodes[node].isDir { return errIsDir }

    // Disk-backed read-only file (M11c): pull the requested span off the disk.
    if nodes[node].onDisk {
        let avail = nodes[node].dataLen - file.offset
        if avail <= 0 { return 0 }
        let want = min(Int(count), avail)
        let off = UInt64(nodes[node].diskOffset + file.offset)
        let rc = virtio_blk_read_range(off, UnsafeMutableRawPointer(dst), UInt32(want))
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
    let d = fdEntry(proc, fd).file
    var file = openDescriptions[d]
    guard file.writable else { return errBadFD }
    guard let src = userReadableBuffer(buffer, count) else { return errInvalid }

    if file.kind == fdKindTTY {
        var w = 0
        while w < Int(count) { uartPutc(src[w]); w += 1 }
        return Int(count)
    }

    if file.kind == fdKindPipe {
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

    guard file.kind == fdKindVNode else { return errBadFD }
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
    let d = fdEntry(proc, fd).file
    let file = openDescriptions[d]
    guard file.writable else { return errBadFD }
    guard file.kind == fdKindVNode else { return errInvalid }
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
    return 0
}

func vfsClose(fd: Int) -> Int {
    let proc = currentVFSProcess()
    guard fd >= 0 && fd < maxFDs && fdEntry(proc, fd).inUse else { return errBadFD }
    releaseDescription(fdEntry(proc, fd).file)
    setFDEntry(proc, fd, FDEntry())
    return 0
}

func vfsDup(fd: Int) -> Int {
    let proc = currentVFSProcess()
    guard validFD(proc, fd) else { return errBadFD }
    let newfd = allocFDInProcess(proc, from: 0)
    if newfd == -1 { return errNoSpace }
    let d = fdEntry(proc, fd).file
    retainDescription(d)
    installDescription(proc, newfd, d)
    return newfd
}

func vfsDup2(oldfd: Int, newfd: Int) -> Int {
    let proc = currentVFSProcess()
    guard validFD(proc, oldfd) else { return errBadFD }
    if newfd < 0 || newfd >= maxFDs { return errBadFD }
    if oldfd == newfd { return newfd }
    if fdEntry(proc, newfd).inUse {
        releaseDescription(fdEntry(proc, newfd).file)
        setFDEntry(proc, newfd, FDEntry())
    }
    let d = fdEntry(proc, oldfd).file
    retainDescription(d)
    installDescription(proc, newfd, d)
    return newfd
}

func vfsPipe(fdsVA: UInt) -> Int {
    guard let out = userWritableBuffer(fdsVA, 8) else { return errInvalid }
    let proc = currentVFSProcess()
    let rfd = allocFDInProcess(proc, from: 0)
    if rfd == -1 { return errNoSpace }
    setFDEntry(proc, rfd, FDEntry(inUse: true, file: -1)) // reserve
    let wfd = allocFDInProcess(proc, from: 0)
    setFDEntry(proc, rfd, FDEntry())
    if wfd == -1 { return errNoSpace }

    let p = allocPipe()
    if p == -1 { return errNoMem }
    let rd = allocDescription()
    let wr = allocDescription()
    if rd == -1 || wr == -1 { return errNoSpace }

    openDescriptions[rd].kind = fdKindPipe
    openDescriptions[rd].readable = true
    openDescriptions[rd].writable = false
    openDescriptions[rd].pipe = p
    openDescriptions[rd].pipeEnd = pipeReadEnd

    openDescriptions[wr].kind = fdKindPipe
    openDescriptions[wr].readable = false
    openDescriptions[wr].writable = true
    openDescriptions[wr].pipe = p
    openDescriptions[wr].pipeEnd = pipeWriteEnd

    installDescription(proc, rfd, rd)
    installDescription(proc, wfd, wr)
    let raw = UnsafeMutableRawPointer(out)
    raw.storeBytes(of: Int32(rfd), toByteOffset: 0, as: Int32.self)
    raw.storeBytes(of: Int32(wfd), toByteOffset: 4, as: Int32.self)
    return 0
}

func vfsLseek(fd: Int, offset: Int, whence: Int) -> Int {
    let proc = currentVFSProcess()
    guard validFD(proc, fd) else { return errBadFD }
    let d = fdEntry(proc, fd).file
    var file = openDescriptions[d]
    guard file.kind == fdKindVNode else { return errInvalid }
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

private func writeStatMode(_ va: UInt, _ mode: UInt32, _ size: Int) -> Int {
    guard let p8 = userWritableBuffer(va, 16) else { return errInvalid }
    let p = UnsafeMutableRawPointer(p8)
    p.storeBytes(of: mode, toByteOffset: 0, as: UInt32.self)
    p.storeBytes(of: UInt32(0), toByteOffset: 4, as: UInt32.self)
    p.storeBytes(of: UInt64(size), toByteOffset: 8, as: UInt64.self)
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
    let perms: UInt32 = nodes[node].isDir ? 0o755 : (nodeIsExecutable(node) ? 0o755 : 0o644)
    let mode: UInt32 = (nodes[node].isDir ? sIFDIR : sIFREG) | perms
    return writeStatMode(va, mode, nodes[node].dataLen)
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
    let file = openDescriptions[fdEntry(proc, fd).file]
    if file.kind == fdKindTTY { return writeStatMode(statbuf, sIFCHR | 0o666, 0) }
    if file.kind == fdKindPipe { return writeStatMode(statbuf, sIFIFO | 0o666, 0) }
    if file.kind == fdKindVNode { return writeStatNode(statbuf, file.node) }
    return errBadFD
}

// dirent: d_ino(8) d_off(8) d_reclen(2) d_type(1) d_name[](NUL-terminated).
func vfsGetdents(fd: Int, buffer: UInt, count: UInt) -> Int {
    if count == 0 { return 0 }
    let proc = currentVFSProcess()
    guard validFD(proc, fd) else { return errBadFD }
    let d = fdEntry(proc, fd).file
    var file = openDescriptions[d]
    guard file.kind == fdKindVNode else { return errInvalid }
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

func vfsUnlink(path pathVA: UInt) -> Int {
    guard let path = userCString(pathVA) else { return errInvalid }
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
    var ls = 0, ll = 0
    let parent = resolveParent(path, &ls, &ll)
    if parent == -1 { return errNoEntry }
    if nodes[parent].readOnly { return errReadOnly }
    if findChild(parent, path + ls, ll) != -1 { return errExists }
    return createTmpNode(parent, path + ls, ll, isDir: true) == -1 ? errNoSpace : 0
}

func vfsRmdir(path pathVA: UInt) -> Int {
    guard let path = userCString(pathVA) else { return errInvalid }
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

private func pollReadyForDescription(_ desc: OpenDescription, events: Int16) -> Int16 {
    var revents: Int16 = 0
    if desc.kind == fdKindTTY {
        if (events & pollIn) != 0 && desc.readable && ttyReadable() { revents |= pollIn }
        if (events & pollOut) != 0 && desc.writable { revents |= pollOut }
        return revents
    }
    if desc.kind == fdKindVNode {
        if (events & pollIn) != 0 && desc.readable { revents |= pollIn }
        if (events & pollOut) != 0 && desc.writable { revents |= pollOut }
        return revents
    }
    if desc.kind == fdKindPipe {
        let p = desc.pipe
        if (events & pollIn) != 0 && desc.readable {
            if pipeCount(p) > 0 || pipes[p].writeRefs == 0 { revents |= pollIn }
        }
        if (events & pollOut) != 0 && desc.writable {
            if pipes[p].readRefs == 0 { revents |= pollErr }
            else if pipeSpace(p) > 0 { revents |= pollOut }
        }
        if desc.pipeEnd == pipeReadEnd && pipes[p].writeRefs == 0 { revents |= pollHup }
        if desc.pipeEnd == pipeWriteEnd && pipes[p].readRefs == 0 { revents |= pollErr }
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
            revents = pollReadyForDescription(openDescriptions[fdEntry(proc, fd).file], events: events)
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
    //   - a pipe only becomes ready when *another* process writes to it, so we
    //     must yield the CPU (processYieldForIO) to let the writer run. That
    //     cooperative-yield-from-a-blocking-syscall path is now preemption-safe
    //     (yieldToScheduler masks IRQs across the switch — see process.swift).
    let proc = currentVFSProcess()
    var hasPipe = false
    for i in 0..<count {
        let fd = Int(base.advanced(by: i * pollfdSize).load(fromByteOffset: 0, as: Int32.self))
        if fd >= 0 && validFD(proc, fd)
            && openDescriptions[fdEntry(proc, fd).file].kind == fdKindPipe { hasPipe = true }
    }

    enable_irq()
    while true {
        let ready = pollScan(base, count)
        if ready > 0 || timeout == 0 { return ready }
        if timeout > 0 && systemTicks - startTicks >= timeoutTicks { return 0 }
        if hasPipe { processYieldForIO() } else { wfi() }
    }
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
