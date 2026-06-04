// vfs.swift — a small in-memory VFS: read-only base tree + writable tmpfs.
//
// The filesystem is a fixed table of vnodes linked as parent/child/sibling
// (a tiny inode table), avoiding ARC and dynamic containers on the hot path.
// The read-only base is built at init from static data; the /tmp subtree is
// tmpfs — files there are created and grown from heap buffers (lost on reboot,
// by design). fd 0/1/2 are the tty/UART; fd >= 3 are open vnodes.
//
// Implements: open, read, write, close, lseek, stat, fstat, getdents, chdir,
// getcwd — enough for ls/cat/echo and busybox bring-up.

// errno-ish returns (negative).
private let errNoEntry = -2
private let errBadFD = -9
private let errInvalid = -22
private let errIsDir = -21
private let errNoSpace = -28
private let errReadOnly = -30

// Open flags (our ABI; userland lib/fs.h must match).
let oWrOnly = 1
let oRdWr = 2
let oCreat = 0x40

// stat st_mode type bits.
private let sIFREG: UInt32 = 0x8000
private let sIFDIR: UInt32 = 0x4000

// dirent d_type.
private let dtDir: UInt8 = 4
private let dtReg: UInt8 = 8

// ---- vnode table ----------------------------------------------------------

private struct VNode {
    var inUse = false
    var isDir = false
    var readOnly = true
    var namePtr: UInt = 0   // bytes of the name (not NUL-terminated)
    var nameLen = 0
    var dataPtr: UInt = 0   // file contents
    var dataLen = 0
    var dataCap = 0         // tmpfs growth capacity
    var parent = -1
    var firstChild = -1
    var nextSibling = -1
}

private let maxNodes = 64
private var nodes: UnsafeMutablePointer<VNode>! = nil
private var nodeCount = 0

// ---- file descriptor table ------------------------------------------------

private struct OpenFile {
    var inUse = false
    var node = -1
    var offset = 0
    var dirCursor = 0 // getdents enumeration position
    var flags = 0
}

private let maxFDs = 32
private let maxVFSProcesses = 16
private var fds = [OpenFile](repeating: OpenFile(), count: maxFDs * maxVFSProcesses)
private var cwdNodes = [Int](repeating: 0, count: maxVFSProcesses)

// ---- construction ---------------------------------------------------------

private func allocNode() -> Int {
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

private func linkChild(_ parent: Int, _ child: Int) {
    nodes[child].parent = parent
    nodes[child].nextSibling = nodes[parent].firstChild
    nodes[parent].firstChild = child
}

private func addDir(_ parent: Int, _ name: StaticString, readOnly: Bool = true) -> Int {
    let n = allocNode()
    setName(n, name)
    nodes[n].isDir = true
    nodes[n].readOnly = readOnly
    linkChild(parent, n)
    return n
}

private func addFile(_ parent: Int, _ name: StaticString, _ content: StaticString) {
    let n = allocNode()
    setName(n, name)
    nodes[n].dataPtr = UInt(bitPattern: content.utf8Start)
    nodes[n].dataLen = content.utf8CodeUnitCount
    nodes[n].readOnly = true
    linkChild(parent, n)
}

func vfsInit() {
    guard let raw = swiftos_kernel_alloc(UInt(MemoryLayout<VNode>.stride * maxNodes), 16) else {
        uartPuts("panic: vfs node table allocation failed\n")
        while true {}
    }
    nodes = raw.bindMemory(to: VNode.self, capacity: maxNodes)
    nodeCount = 0

    // Root.
    let root = allocNode()
    setName(root, "/")
    nodes[root].isDir = true
    nodes[root].parent = root

    // Read-only base.
    _ = addDir(root, "bin")
    let etc = addDir(root, "etc")
    addFile(etc, "motd", "Welcome to swift-os.\n")
    addFile(etc, "hostname", "swiftos\n")
    addFile(root, "readme.txt", "swift-os read-only base fs\n")
    addFile(root, "hello.txt", "M5 file: hello from VFS read()\n")

    // tmpfs (writable).
    _ = addDir(root, "tmp", readOnly: false)

    for p in 0..<maxVFSProcesses {
        cwdNodes[p] = root
        for fd in 0..<maxFDs { fds[fdIndex(p, fd)] = OpenFile() }
    }
}

func vfsProcessInit(slot: Int, parent: Int) {
    if slot < 0 || slot >= maxVFSProcesses { return }
    if parent >= 0 && parent < maxVFSProcesses {
        cwdNodes[slot] = cwdNodes[parent]
        for fd in 0..<maxFDs {
            fds[fdIndex(slot, fd)] = fds[fdIndex(parent, fd)]
        }
        return
    }
    cwdNodes[slot] = 0
    for fd in 0..<maxFDs { fds[fdIndex(slot, fd)] = OpenFile() }
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

private func openFile(_ proc: Int, _ fd: Int) -> OpenFile {
    fds[fdIndex(proc, fd)]
}

private func setOpenFile(_ proc: Int, _ fd: Int, _ value: OpenFile) {
    fds[fdIndex(proc, fd)] = value
}

private func nameEquals(_ node: Int, _ ptr: UnsafePointer<UInt8>, _ len: Int) -> Bool {
    if nodes[node].nameLen != len { return false }
    let np = UnsafePointer<UInt8>(bitPattern: nodes[node].namePtr)!
    for i in 0..<len { if np[i] != ptr[i] { return false } }
    return true
}

private func findChild(_ dir: Int, _ ptr: UnsafePointer<UInt8>, _ len: Int) -> Int {
    if len == 1 && ptr[0] == 0x2E { return dir }              // "."
    if len == 2 && ptr[0] == 0x2E && ptr[1] == 0x2E {         // ".."
        return nodes[dir].parent
    }
    var c = nodes[dir].firstChild
    while c != -1 {
        if nameEquals(c, ptr, len) { return c }
        c = nodes[c].nextSibling
    }
    return -1
}

// Resolve a NUL-terminated path (kernel pointer). Returns vnode index or -1.
private func resolve(_ path: UnsafePointer<UInt8>) -> Int {
    var i = 0
    var cur = path[0] == 0x2F ? 0 : cwdNodeForCurrentProcess()   // leading '/' → root
    while path[i] == 0x2F { i += 1 }          // skip leading slashes

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

// Resolve the parent dir + leaf name of a path (for create). Returns parent idx
// and sets leafStart/leafLen to the final component. -1 on error.
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

// ---- fd helpers -----------------------------------------------------------

private func allocFD() -> Int {
    let proc = currentVFSProcess()
    for i in 3..<maxFDs where !openFile(proc, i).inUse { return i }
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
            if parent == -1 || nodes[parent].readOnly { return errNoEntry }
            node = createTmpFile(parent, path + ls, ll)
            if node == -1 { return errNoSpace }
        } else {
            return errNoEntry
        }
    }

    let proc = currentVFSProcess()
    let fd = allocFD()
    if fd == -1 { return errNoSpace }
    setOpenFile(proc, fd, OpenFile(inUse: true, node: node, offset: 0, dirCursor: 0, flags: f))
    return fd
}

private func createTmpFile(_ parent: Int, _ namePtr: UnsafePointer<UInt8>, _ nameLen: Int) -> Int {
    if nodeCount >= maxNodes { return -1 }
    let cap = 4096
    guard let nameBuf = swiftos_kernel_alloc(UInt(nameLen), 1),
          let dataBuf = swiftos_kernel_alloc(UInt(cap), 16) else { return -1 }
    let nb = nameBuf.bindMemory(to: UInt8.self, capacity: nameLen)
    for i in 0..<nameLen { nb[i] = namePtr[i] }

    let n = allocNode()
    nodes[n].namePtr = UInt(bitPattern: nameBuf)
    nodes[n].nameLen = nameLen
    nodes[n].dataPtr = UInt(bitPattern: dataBuf)
    nodes[n].dataLen = 0
    nodes[n].dataCap = cap
    nodes[n].readOnly = false
    linkChild(parent, n)
    return n
}

func vfsRead(fd: Int, buffer: UInt, count: UInt) -> Int {
    if count == 0 { return 0 }
    let proc = currentVFSProcess()
    guard fd >= 3 && fd < maxFDs else { return errBadFD }
    var file = openFile(proc, fd)
    guard file.inUse else { return errBadFD }
    guard let dst = userWritableBuffer(buffer, count) else { return errInvalid }
    let node = file.node
    if nodes[node].isDir { return errIsDir }

    let src = UnsafePointer<UInt8>(bitPattern: nodes[node].dataPtr)!
    var copied = 0
    while copied < Int(count) && file.offset < nodes[node].dataLen {
        dst[copied] = src[file.offset]
        copied += 1
        file.offset += 1
    }
    setOpenFile(proc, fd, file)
    return copied
}

func vfsWrite(fd: Int, buffer: UInt, count: UInt) -> Int {
    if count == 0 { return 0 }
    // stdout / stderr go to the console.
    if fd == 1 || fd == 2 {
        guard let src = userReadableBuffer(buffer, count) else { return errInvalid }
        var w = 0
        while w < Int(count) { uartPutc(src[w]); w += 1 }
        return Int(count)
    }

    let proc = currentVFSProcess()
    guard fd >= 3 && fd < maxFDs else { return errBadFD }
    var file = openFile(proc, fd)
    guard file.inUse else { return errBadFD }
    let node = file.node
    if nodes[node].isDir { return errIsDir }
    if nodes[node].readOnly { return errReadOnly }
    guard let src = userReadableBuffer(buffer, count) else { return errInvalid }

    let dst = UnsafeMutablePointer<UInt8>(bitPattern: nodes[node].dataPtr)!
    var w = 0
    while w < Int(count) && file.offset < nodes[node].dataCap {
        dst[file.offset] = src[w]
        file.offset += 1
        if file.offset > nodes[node].dataLen { nodes[node].dataLen = file.offset }
        w += 1
    }
    setOpenFile(proc, fd, file)
    return w
}

func vfsClose(fd: Int) -> Int {
    let proc = currentVFSProcess()
    guard fd >= 3 && fd < maxFDs && openFile(proc, fd).inUse else { return errBadFD }
    setOpenFile(proc, fd, OpenFile())
    return 0
}

func vfsLseek(fd: Int, offset: Int, whence: Int) -> Int {
    let proc = currentVFSProcess()
    guard fd >= 3 && fd < maxFDs else { return errBadFD }
    var file = openFile(proc, fd)
    guard file.inUse else { return errBadFD }
    let node = file.node
    var base = 0
    if whence == 1 { base = file.offset }
    else if whence == 2 { base = nodes[node].dataLen }
    let next = base + offset
    if next < 0 { return errInvalid }
    file.offset = next
    setOpenFile(proc, fd, file)
    return next
}

private func writeStat(_ va: UInt, _ node: Int) -> Int {
    guard let p8 = userWritableBuffer(va, 16) else { return errInvalid }
    let p = UnsafeMutableRawPointer(mutating: p8)
    let mode: UInt32 = nodes[node].isDir ? (sIFDIR | 0o755) : (sIFREG | 0o644)
    p.storeBytes(of: mode, toByteOffset: 0, as: UInt32.self)
    p.storeBytes(of: UInt32(0), toByteOffset: 4, as: UInt32.self)
    p.storeBytes(of: UInt64(nodes[node].dataLen), toByteOffset: 8, as: UInt64.self)
    return 0
}

func vfsStat(path pathVA: UInt, statbuf: UInt) -> Int {
    guard let path = userCString(pathVA) else { return errInvalid }
    let node = resolve(path)
    if node == -1 { return errNoEntry }
    return writeStat(statbuf, node)
}

func vfsFstat(fd: Int, statbuf: UInt) -> Int {
    let proc = currentVFSProcess()
    guard fd >= 3 && fd < maxFDs else { return errBadFD }
    let file = openFile(proc, fd)
    guard file.inUse else { return errBadFD }
    return writeStat(statbuf, file.node)
}

// dirent: d_ino(8) d_off(8) d_reclen(2) d_type(1) d_name[](NUL-terminated).
func vfsGetdents(fd: Int, buffer: UInt, count: UInt) -> Int {
    if count == 0 { return 0 }
    let proc = currentVFSProcess()
    guard fd >= 3 && fd < maxFDs else { return errBadFD }
    var file = openFile(proc, fd)
    guard file.inUse else { return errBadFD }
    let dir = file.node
    if !nodes[dir].isDir { return errInvalid }
    guard let b = userWritableBuffer(buffer, count) else { return errInvalid }
    let buf = UnsafeMutableRawPointer(mutating: b)

    // Walk to the child at dirCursor.
    var child = nodes[dir].firstChild
    var skip = file.dirCursor
    while skip > 0 && child != -1 { child = nodes[child].nextSibling; skip -= 1 }

    var used = 0
    while child != -1 {
        let nameLen = nodes[child].nameLen
        let reclen = (19 + nameLen + 1 + 7) & ~7 // align to 8
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
    setOpenFile(proc, fd, file)
    return used
}

func vfsChdir(path pathVA: UInt) -> Int {
    guard let path = userCString(pathVA) else { return errInvalid }
    let node = resolve(path)
    if node == -1 { return errNoEntry }
    if !nodes[node].isDir { return errInvalid }
    cwdNodes[currentVFSProcess()] = node
    return 0
}

// Build the absolute path of cwd into the user buffer. Returns length, or error.
func vfsGetcwd(buffer: UInt, size: UInt) -> Int {
    guard size > 0, let buf = userWritableBuffer(buffer, size) else {
        return errInvalid
    }

    let cwdNode = cwdNodeForCurrentProcess()
    if cwdNode == 0 { // root
        if size < 2 { return errNoSpace }
        buf[0] = 0x2F; buf[1] = 0
        return 1
    }

    // Collect ancestor indices from cwd up to (not including) root.
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
